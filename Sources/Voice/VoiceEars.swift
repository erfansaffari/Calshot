import Foundation
import os

/// Connection state only: never audio, transcripts or tokens.
private let earsLog = Logger(subsystem: "com.calshot.voice", category: "ears")

/// Push-to-talk speech recognition. The connection is opened before the user talks, audio streams while the key is
/// held, and the final words are ready a fraction of a second after release.
@MainActor protocol VoiceListening: AnyObject {
    /// Words recognized so far in the current hold, for the live caption.
    var onInterim: ((String) -> Void)? { get set }
    /// Opens (or keeps) the connection so the next hold is heard at once.
    func warm(vocabulary: [String])
    /// A new hold. Audio sent before the connection is ready is buffered and sent once it is.
    func begin()
    func append(_ pcm: Data)
    /// The hold ended: returns everything recognized in it ("" when nothing was said).
    func finish() async throws -> String
    /// The hold is dropped (a tap or a turn that was too short); its words are never returned.
    func discard()
    func close()
}

enum VoiceListeningError: LocalizedError, Equatable {
    case unavailable
    var errorDescription: String? { "Calshot couldn’t hear that. Hold the key and try again." }
}

/// Google's live transcription model (`gemini-3.5-transcribe-live`) through Calshot's one-use listening tokens.
/// Manual activity detection: the user's key marks the start and end of speech. Verified 2026-11-19 against the live
/// service: `bidiGenerateContentSetup` in the token locks the setup, the final text arrives as
/// `serverContent.inputTranscription` (appended per segment in verbatim mode) and `generationComplete` ends the hold.
@MainActor final class GeminiEars: VoiceListening {
    var onInterim: ((String) -> Void)?
    /// How long a released hold may wait for its final words.
    var finalTimeout: Duration = .seconds(4)
    private let service: any VoiceServicing
    private let makeSocket: @MainActor () -> VoiceSocket
    private var socket: VoiceSocket?
    private var connection: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var ready = false
    private var connectedAt = Date.distantPast
    private var vocabulary: [String] = []
    /// Messages waiting for the connection, in order.
    private var outgoing: [String] = []
    private var sending = false
    /// Holds in order. Recognized text and `generationComplete` always belong to the oldest unfinished one.
    private final class Hold { var text = ""; var interim = ""; var ended = false; var discarded = false; var waiter: CheckedContinuation<String, Error>? }
    private var holds: [Hold] = []
    private var generation = UUID()

    init(service: any VoiceServicing, makeSocket: @escaping @MainActor () -> VoiceSocket = { URLSessionVoiceSocket() }) {
        self.service = service; self.makeSocket = makeSocket
    }

    func warm(vocabulary: [String]) {
        self.vocabulary = Array(vocabulary.prefix(100))
        // A listening session lasts ten minutes; renew a little early so a hold never lands on an expiring one.
        if connection != nil, Date().timeIntervalSince(connectedAt) < 540 || !holds.isEmpty { return }
        connect()
    }
    private func connect() {
        teardown()
        let id = UUID(); generation = id; connectedAt = Date()
        connection = Task { [weak self] in
            guard let self else { return }
            do {
                let grant = try await self.service.listeningGrant(vocabulary: self.vocabulary)
                guard self.generation == id else { return }
                let socket = self.makeSocket(); self.socket = socket
                try await socket.connect(url: grant.url, headers: ["Authorization": "Token " + grant.token])
                let messages = socket.receive()
                try await socket.send(text: Self.json(["setup": ["model": grant.model]]))
                self.reader = Task { [weak self] in
                    do { for try await text in messages { self?.handle(text, generation: id) } ; self?.lost(id) }
                    catch { self?.lost(id) }
                }
            } catch {
                guard self.generation == id else { return }
                earsLog.error("listening could not connect: \(String(describing: error), privacy: .public)")
                self.lost(id, error: error)
            }
        }
    }
    func begin() {
        if connection == nil { connect() }
        holds.append(Hold())
        queue(Self.json(["realtimeInput": ["activityStart": [String: String]()]]))
    }
    func append(_ pcm: Data) {
        guard let hold = holds.last, !hold.ended, !pcm.isEmpty else { return }
        queue(Self.json(["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=24000"]]]))
    }
    func finish() async throws -> String {
        guard let hold = holds.last, !hold.ended else { return "" }
        hold.ended = true
        queue(Self.json(["realtimeInput": ["activityEnd": [String: String]()]]))
        let id = generation, timeout = finalTimeout
        return try await withCheckedThrowingContinuation { continuation in
            hold.waiter = continuation
            Task { [weak self, weak hold] in
                try? await Task.sleep(for: timeout)
                guard let self, let hold, let waiter = hold.waiter, self.generation == id else { return }
                // No completion in time: what was recognized is the request (often everything already arrived).
                hold.waiter = nil
                if let index = self.holds.firstIndex(where: { $0 === hold }) { self.holds.remove(at: index) }
                hold.text.isEmpty ? waiter.resume(throwing: VoiceListeningError.unavailable) : waiter.resume(returning: hold.text)
            }
        }
    }
    func discard() {
        guard let hold = holds.last, !hold.discarded else { return }
        hold.discarded = true
        if !hold.ended { hold.ended = true; queue(Self.json(["realtimeInput": ["activityEnd": [String: String]()]])) }
        hold.waiter?.resume(returning: ""); hold.waiter = nil
        // A hold with no speech may never get a completion; it must not keep later words.
        let id = generation
        Task { [weak self, weak hold] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, let hold, self.generation == id else { return }
            self.holds.removeAll { $0 === hold }
        }
    }
    func close() { teardown(); generation = UUID() }

    private func teardown() {
        connection?.cancel(); connection = nil; reader?.cancel(); reader = nil
        socket?.close(); socket = nil; ready = false; outgoing = []; sending = false
        for hold in holds { hold.waiter?.resume(throwing: VoiceListeningError.unavailable); hold.waiter = nil }
        holds = []
    }
    private func lost(_ id: UUID, error: Error? = nil) {
        guard generation == id else { return }
        let failed = holds
        socket?.close(); socket = nil; connection = nil; reader = nil; ready = false; outgoing = []; sending = false; holds = []
        for hold in failed { hold.waiter?.resume(throwing: error as? VoiceServiceError ?? VoiceListeningError.unavailable); hold.waiter = nil }
    }
    private func queue(_ message: String) {
        outgoing.append(message)
        // Bounded: about thirty seconds of held audio while connecting.
        if outgoing.count > 400 { outgoing.removeFirst(outgoing.count - 400) }
        flush()
    }
    private func flush() {
        guard ready, !sending, let socket, !outgoing.isEmpty else { return }
        sending = true
        let id = generation
        Task { [weak self] in
            while let self, self.generation == id, self.ready, !self.outgoing.isEmpty {
                let next = self.outgoing.removeFirst()
                do { try await socket.send(text: next) } catch { self.lost(id); return }
            }
            if let self, self.generation == id { self.sending = false }
        }
    }
    private func handle(_ text: String, generation id: UUID) {
        guard generation == id, let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if message["setupComplete"] != nil { ready = true; flush(); return }
        if message["goAway"] != nil { connectedAt = .distantPast; return }
        guard let content = message["serverContent"] as? [String: Any] else { return }
        let hold = holds.first
        if let interim = (content["interimInputTranscription"] as? [String: Any])?["text"] as? String, let hold, !hold.discarded {
            hold.interim = interim; onInterim?(hold.text + interim)
        }
        if let final = (content["inputTranscription"] as? [String: Any])?["text"] as? String, let hold {
            hold.text += final; hold.interim = ""
            if !hold.discarded { onInterim?(hold.text) }
        }
        if content["generationComplete"] as? Bool == true || content["turnComplete"] as? Bool == true, let hold, hold.ended {
            holds.removeAll { $0 === hold }
            hold.waiter?.resume(returning: hold.discarded ? "" : hold.text.trimmingCharacters(in: .whitespacesAndNewlines)); hold.waiter = nil
        }
    }
    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
