import Foundation
import Combine
import os

private let realtimeLog = Logger(subsystem: "com.calshot.voice", category: "realtime")
/// Public log fields must look like protocol identifiers (e.g. `unknown_parameter`, `session.tools[0].strict`); anything else is redacted.
private func loggable(_ value: Any?) -> String {
    guard let text = value as? String, !text.isEmpty else { return "" }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.[]-")
    return text.count <= 80 && text.unicodeScalars.allSatisfy(allowed.contains) && !text.hasPrefix("sk-") ? text : "<redacted>"
}

/// All transport operations and callbacks are isolated to the main actor. No credentials are logged.
@MainActor
protocol RealtimeTransport: AnyObject {
    func connect(url: URL, headers: [String: String]) async throws
    func send(text: String) async throws
    func receive() -> AsyncThrowingStream<String, Error>
    func close()
}

enum RealtimeConnectionError: Error, Equatable, CustomStringConvertible {
    case authentication, quota, unavailable, invalidFrame, notReady
    var description: String {
        switch self {
        case .authentication: return "Voice needs a valid OpenAI API key. Check AI service in Settings."
        case .quota: return "OpenAI voice quota is exhausted. Check API billing before retrying."
        case .unavailable: return "Voice connection interrupted. Start a new voice session to continue."
        case .invalidFrame: return "Voice received an invalid message. Start a new voice session."
        case .notReady: return "Voice is still connecting. Try again when ready."
        }
    }
}

@MainActor
final class URLSessionRealtimeTransport: RealtimeTransport {
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    func connect(url: URL, headers: [String: String]) async throws {
        close()
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
    }
    func send(text: String) async throws {
        guard let socket else { throw RealtimeConnectionError.unavailable }
        do { try await socket.send(.string(text)) } catch { throw classify(socket) }
    }
    func receive() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            guard let socket else { continuation.finish(throwing: RealtimeConnectionError.unavailable); return }
            reader = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        switch message {
                        case .string(let text): continuation.yield(text)
                        case .data(let data):
                            guard let text = String(data: data, encoding: .utf8) else { throw RealtimeConnectionError.invalidFrame }
                            continuation.yield(text)
                        @unknown default: throw RealtimeConnectionError.invalidFrame
                        }
                    }
                } catch { continuation.finish(throwing: self?.classify(socket) ?? RealtimeConnectionError.unavailable) }
            }
        }
    }
    private func classify(_ socket: URLSessionWebSocketTask) -> RealtimeConnectionError {
        let status = (socket.response as? HTTPURLResponse)?.statusCode
        if status == 401 || status == 403 { return .authentication }
        if status == 429 { return .quota } // Conservative: do not retry billing/rate-limit handshake failures.
        return .unavailable
    }
    func close() {
        reader?.cancel(); reader = nil
        continuation?.finish(); continuation = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }
}

/// The only table of wire event names (client and server).
/// Verified 2026-10-29 against:
/// https://developers.openai.com/api/reference/resources/realtime/client-events
/// https://developers.openai.com/api/reference/resources/realtime/server-events
/// Uses GA audio.* configuration and response.output_audio.* events, not the beta schema.
enum RealtimeWire: String, CaseIterable {
    case sessionUpdate = "session.update", sessionCreated = "session.created", sessionUpdated = "session.updated"
    case append = "input_audio_buffer.append", commit = "input_audio_buffer.commit", clear = "input_audio_buffer.clear"
    case itemCreate = "conversation.item.create", truncate = "conversation.item.truncate"
    case responseCreate = "response.create", cancel = "response.cancel", responseCreated = "response.created"
    case speechStarted = "input_audio_buffer.speech_started", speechStopped = "input_audio_buffer.speech_stopped"
    case userDelta = "conversation.item.input_audio_transcription.delta"
    case userFinal = "conversation.item.input_audio_transcription.completed"
    case transcriptionFailed = "conversation.item.input_audio_transcription.failed"
    case audioDelta = "response.output_audio.delta", audioDone = "response.output_audio.done"
    case assistantDelta = "response.output_audio_transcript.delta", assistantDone = "response.output_audio_transcript.done"
    case functionDone = "response.function_call_arguments.done", responseDone = "response.done"
    case rateLimits = "rate_limits.updated", error = "error"
}

struct RealtimeTokenUsage: Equatable {
    var input = 0, output = 0, audioInput = 0, audioOutput = 0, imageInput = 0
    var cachedText = 0, cachedAudio = 0, cachedImage = 0
    init(_ json: [String: Any] = [:]) {
        input = json["input_tokens"] as? Int ?? 0; output = json["output_tokens"] as? Int ?? 0
        let i = json["input_token_details"] as? [String: Any] ?? [:]
        let o = json["output_token_details"] as? [String: Any] ?? [:]
        audioInput = i["audio_tokens"] as? Int ?? 0; imageInput = i["image_tokens"] as? Int ?? 0
        audioOutput = o["audio_tokens"] as? Int ?? 0
        let c = i["cached_tokens_details"] as? [String: Any] ?? [:]
        cachedText = c["text_tokens"] as? Int ?? 0; cachedAudio = c["audio_tokens"] as? Int ?? 0
        cachedImage = c["image_tokens"] as? Int ?? 0
    }
    mutating func add(_ u: Self) {
        input += u.input; output += u.output; audioInput += u.audioInput; audioOutput += u.audioOutput
        imageInput += u.imageInput; cachedText += u.cachedText; cachedAudio += u.cachedAudio; cachedImage += u.cachedImage
    }
}

/// USD per million tokens; estimate excludes separate transcription charges and taxes.
/// Defaults: https://developers.openai.com/api/docs/models/gpt-realtime-2.1 (2026-10-29).
struct RealtimePrices {
    var textInput = 4.0, textOutput = 24.0, audioInput = 32.0, audioOutput = 64.0, imageInput = 5.0
    var cachedText = 0.4, cachedAudio = 0.4, cachedImage = 0.5
    func estimate(_ u: RealtimeTokenUsage) -> Double {
        (Double(max(0, u.input - u.audioInput - u.imageInput - u.cachedText)) * textInput
         + Double(max(0, u.output - u.audioOutput)) * textOutput
         + Double(max(0, u.audioInput - u.cachedAudio)) * audioInput + Double(u.audioOutput) * audioOutput
         + Double(max(0, u.imageInput - u.cachedImage)) * imageInput
         + Double(u.cachedText) * cachedText + Double(u.cachedAudio) * cachedAudio + Double(u.cachedImage) * cachedImage) / 1_000_000
    }
}

enum RealtimeVoiceEvent: Equatable {
    case sessionCreated, sessionUpdated, responseCreated, speechStarted, speechStopped, audioDone
    case userTranscript(itemID: String, text: String, final: Bool)
    case audio(itemID: String, contentIndex: Int, data: Data)
    case assistantTranscript(itemID: String, text: String, final: Bool)
    case functionCall(callID: String, name: String, argumentsJSON: String)
    case responseDone(id: String, status: String, usage: RealtimeTokenUsage)
    case rateLimits(JSONValue)
    case error(code: String, message: String)
    case unknown(String)

    static func decode(_ text: String) throws -> Self {
        guard let data = text.data(using: .utf8), let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = j["type"] as? String else { throw RealtimeConnectionError.invalidFrame }
        func s(_ key: String) -> String { j[key] as? String ?? "" }
        switch RealtimeWire(rawValue: type) {
        case .sessionCreated: return .sessionCreated
        case .sessionUpdated: return .sessionUpdated
        case .responseCreated: return .responseCreated
        case .speechStarted: return .speechStarted
        case .speechStopped: return .speechStopped
        case .audioDone: return .audioDone
        case .userDelta, .userFinal:
            let final = RealtimeWire(rawValue: type) == .userFinal
            return .userTranscript(itemID: s("item_id"), text: s(final ? "transcript" : "delta"), final: final)
        case .audioDelta:
            guard let audio = Data(base64Encoded: s("delta")) else { throw RealtimeConnectionError.invalidFrame }
            return .audio(itemID: s("item_id"), contentIndex: j["content_index"] as? Int ?? 0, data: audio)
        case .assistantDelta, .assistantDone:
            let final = RealtimeWire(rawValue: type) == .assistantDone
            return .assistantTranscript(itemID: s("item_id"), text: s(final ? "transcript" : "delta"), final: final)
        case .functionDone: return .functionCall(callID: s("call_id"), name: s("name"), argumentsJSON: s("arguments"))
        case .responseDone:
            let r = j["response"] as? [String: Any] ?? [:]
            return .responseDone(id: r["id"] as? String ?? "", status: r["status"] as? String ?? "", usage: .init(r["usage"] as? [String: Any] ?? [:]))
        case .rateLimits:
            return .rateLimits(try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: j["rate_limits"] ?? [])))
        case .transcriptionFailed:
            // A failed caption must not end the session; the audio turn itself still reaches the model.
            let e = j["error"] as? [String: Any] ?? [:]
            realtimeLog.error("Transcription failed: code=\(loggable(e["code"]), privacy: .public) message=\(e["message"] as? String ?? "", privacy: .private)")
            return .unknown(type)
        case .error:
            let e = j["error"] as? [String: Any] ?? [:]
            // Never expose arbitrary server text in the UI: it may echo credentials or request bodies.
            // Code, type and param are diagnostic only; the message stays private in the local log.
            realtimeLog.error("Realtime error: type=\(loggable(e["type"]), privacy: .public) code=\(loggable(e["code"]), privacy: .public) param=\(loggable(e["param"]), privacy: .public) message=\(e["message"] as? String ?? "", privacy: .private)")
            let raw = e["code"] as? String ?? ""
            let code = ["invalid_api_key", "insufficient_quota", "rate_limit_exceeded", "invalid_request_error", "conversation_already_has_active_response", "response_cancel_not_active", "input_audio_buffer_commit_empty"].contains(raw) ? raw : "service_error"
            return .error(code: code, message: code == "invalid_api_key" ? RealtimeConnectionError.authentication.description : code == "insufficient_quota" ? RealtimeConnectionError.quota.description : "Voice could not complete the request. Try again.")
        default: return .unknown(type)
        }
    }
}

/// Main-actor observable client. Step D owns tool execution, permissions, session limits and playback.
/// Reconnect opens a NEW server session: emits onReconnect, discards in-flight work, never replays writes.
@MainActor
final class RealtimeVoiceClient: ObservableObject {
    // Verified model: https://developers.openai.com/api/docs/models/gpt-realtime-2.1, 2026-10-29.
    nonisolated static let defaultModel = "gpt-realtime-2.1"
    struct Configuration {
        var model = RealtimeVoiceClient.defaultModel
        var instructions: String
        var voice = "marin"
        var transcriptionModel = "gpt-4o-mini-transcribe"
        var tools: [JSONValue] = []
        var automaticResponse = true
        /// Push-to-talk: no server voice detection; the caller commits each held turn.
        var pushToTalk = false
    }
    enum State: Equatable { case disconnected, connecting, ready, responding, failed(String) }
    @Published private(set) var state: State = .disconnected
    @Published private(set) var reconnectAttempt = 0
    @Published private(set) var audioInputSeconds = 0.0
    @Published private(set) var audioOutputSeconds = 0.0
    @Published private(set) var tokens = RealtimeTokenUsage()
    var estimatedCost: Double { prices.estimate(tokens) }
    var onEvent: ((RealtimeVoiceEvent) -> Void)?
    var onReconnect: (() -> Void)?
    /// Wire to the audio engine. flush returns played milliseconds for the current item.
    var isAudioPlaying: () -> Bool = { false }
    var flushAudio: () -> Int = { 0 }
    private let key: () throws -> String
    private let factory: @MainActor () -> RealtimeTransport
    private let sleep: (Double) async throws -> Void
    private let prices: RealtimePrices
    private var transport: RealtimeTransport?
    private var run: Task<Void, Never>?
    private var generation = UUID()
    private var currentAudio: (String, Int)?
    private var seenResponses = Set<String>()
    private var outstandingTools = Set<String>()
    private var responseInFlight = false
    private var responsePending = false
    private var suppressAudio = false
    private var pendingCalls: [RealtimeVoiceEvent] = []
    init(apiKey: @escaping () throws -> String, prices: RealtimePrices = .init(),
         transportFactory: @escaping @MainActor () -> RealtimeTransport = { URLSessionRealtimeTransport() },
         sleep: @escaping (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        key = apiKey; self.prices = prices; factory = transportFactory; self.sleep = sleep
    }
    func connect(configuration: Configuration) {
        disconnect(); audioInputSeconds = 0; audioOutputSeconds = 0; tokens = .init(); seenResponses = []
        state = .connecting; reconnectAttempt = 0
        let id = generation
        run = Task { [weak self] in
            guard let self else { return }
            while self.generation == id && !Task.isCancelled {
                do {
                    let credential: String
                    do { credential = try self.key() } catch { throw RealtimeConnectionError.authentication }
                    guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RealtimeConnectionError.authentication }
                    var url = URLComponents(string: "wss://api.openai.com/v1/realtime")!
                    url.queryItems = [.init(name: "model", value: configuration.model)]
                    let t = self.factory(); self.transport = t
                    try await t.connect(url: url.url!, headers: ["Authorization": "Bearer \(credential)"])
                    guard self.generation == id else { t.close(); return }
                    try await self.send(.sessionUpdate, ["session": self.session(configuration)])
                    guard self.generation == id, !Task.isCancelled else { t.close(); return }
                    for try await text in t.receive() {
                        guard self.generation == id, !Task.isCancelled else { return }
                        let event = try RealtimeVoiceEvent.decode(text)
                        try await self.handle(event)
                    }
                    throw RealtimeConnectionError.unavailable
                } catch {
                    guard self.generation == id, !Task.isCancelled else { return }
                    self.transport?.close(); self.transport = nil
                    _ = self.flushAudio(); self.currentAudio = nil; self.pendingCalls = []; self.outstandingTools = []; self.responseInFlight = false; self.responsePending = false
                    if case .failed = self.state { return }
                    let failure = error as? RealtimeConnectionError ?? .unavailable
                    if failure == .authentication || failure == .quota || self.reconnectAttempt == 3 {
                        self.state = .failed(failure.description); return
                    }
                    self.reconnectAttempt += 1; self.state = .connecting
                    self.onReconnect?()
                    do { try await self.sleep(pow(2, Double(self.reconnectAttempt - 1))) } catch { return }
                }
            }
        }
    }
    func disconnect() {
        generation = UUID(); run?.cancel(); run = nil; transport?.close(); transport = nil
        _ = flushAudio(); currentAudio = nil; pendingCalls = []; outstandingTools = []; responseInFlight = false; responsePending = false; suppressAudio = false; state = .disconnected
    }
    private func session(_ c: Configuration) -> [String: Any] {
        let turnDetection: Any = c.pushToTalk ? NSNull() : ["type": "server_vad", "create_response": c.automaticResponse, "interrupt_response": false] as [String: Any]
        return ["type": "realtime", "model": c.model, "instructions": c.instructions, "output_modalities": ["audio"],
         "audio": ["input": ["format": ["type": "audio/pcm", "rate": 24000], "transcription": ["model": c.transcriptionModel],
                               "turn_detection": turnDetection] as [String: Any],
                   "output": ["format": ["type": "audio/pcm", "rate": 24000], "voice": c.voice]],
         "tools": c.tools.compactMap(Self.realtimeTool), "tool_choice": "auto"]
    }
    /// Realtime function tools accept only type, name, description and parameters; text-agent fields such as `strict` are rejected.
    nonisolated static func realtimeTool(_ tool: JSONValue) -> [String: Any]? {
        guard let object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(tool))) as? [String: Any] else { return nil }
        return object.filter { ["type", "name", "description", "parameters"].contains($0.key) }
    }
    private func send(_ type: RealtimeWire, _ fields: [String: Any] = [:]) async throws {
        guard let transport else { throw RealtimeConnectionError.notReady }
        var j = fields; j["type"] = type.rawValue
        let data = try JSONSerialization.data(withJSONObject: j)
        try await transport.send(text: String(decoding: data, as: UTF8.self))
    }
    private func requireReady() throws {
        guard state == .ready || state == .responding else { throw RealtimeConnectionError.notReady }
    }
    func appendAudio(_ pcm16: Data) async throws {
        try requireReady(); guard pcm16.count % 2 == 0 else { throw RealtimeConnectionError.invalidFrame }
        try await send(.append, ["audio": pcm16.base64EncodedString()]); audioInputSeconds += Double(pcm16.count) / 48000
    }
    func commitInputBuffer() async throws { try requireReady(); try await send(.commit) }
    func clearInputBuffer() async throws { try requireReady(); try await send(.clear) }
    func sendImage(jpeg: Data, caption: String) async throws {
        try requireReady()
        try await send(.itemCreate, ["item": ["type": "message", "role": "user", "content": [
            ["type": "input_text", "text": caption], ["type": "input_image", "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]]]])
    }
    func sendText(_ text: String) async throws {
        try requireReady()
        try await send(.itemCreate, ["item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]])
        try await requestResponse()
    }
    /// Native clock/routing guidance only. Never pass screen, history or model text here.
    /// Creating context is separate from response.create, so it cannot produce an unsolicited reply.
    func sendContext(_ text: String) async throws {
        try requireReady()
        try await send(.itemCreate, ["item": ["type": "message", "role": "system", "content": [["type": "input_text", "text": text]]]])
    }
    func sendToolResult(callID: String, outputJSON: String) async throws {
        try requireReady()
        guard let data = outputJSON.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else { throw RealtimeConnectionError.invalidFrame }
        try await send(.itemCreate, ["item": ["type": "function_call_output", "call_id": callID, "output": outputJSON]])
        outstandingTools.remove(callID)
        if outstandingTools.isEmpty { responsePending = false; try await requestResponse() }
    }
    func requestResponse() async throws {
        try requireReady()
        if responseInFlight { responsePending = true; return }
        responseInFlight = true
        do { try await send(.responseCreate) } catch { responseInFlight = false; throw error }
    }
    func cancelResponse() async throws { try requireReady(); try await send(.cancel) }
    /// User barge-in: stop playback now, cancel the in-flight response and truncate what was not heard.
    func interrupt() async throws {
        guard state == .ready || state == .responding else { return }
        let played = flushAudio()
        guard responseInFlight || currentAudio != nil else { return }
        suppressAudio = true; pendingCalls = []
        if responseInFlight { try await send(.cancel) }
        if let (item, index) = currentAudio { try await send(.truncate, ["item_id": item, "content_index": index, "audio_end_ms": max(0, played)]) }
        currentAudio = nil
    }
    private func handle(_ event: RealtimeVoiceEvent) async throws {
        switch event {
        case .sessionUpdated: state = .ready
        case .responseCreated: responseInFlight = true; state = .responding; suppressAudio = false; pendingCalls = []
        case .functionCall:
            // Arguments-done also arrives for cancelled responses. Deliver tools only after
            // the response is completed, never from an interrupted partial call.
            if !suppressAudio { pendingCalls.append(event) }
            return
        case .audio(let item, let index, let data):
            guard !suppressAudio else { return }
            currentAudio = (item, index); audioOutputSeconds += Double(data.count) / 48000
        case .speechStarted where isAudioPlaying():
            let played = flushAudio(); suppressAudio = true; pendingCalls = []
            try await send(.cancel)
            if let (item, index) = currentAudio {
                try await send(.truncate, ["item_id": item, "content_index": index, "audio_end_ms": max(0, played)])
            }
            currentAudio = nil
        case .responseDone(let id, let status, let usage):
            let fresh = id.isEmpty || seenResponses.insert(id).inserted
            guard fresh else { return }
            tokens.add(usage)
            responseInFlight = false
            state = .ready
            let calls = pendingCalls; pendingCalls = []
            if fresh && status == "completed" && !suppressAudio { calls.forEach { if case .functionCall(let id, _, _) = $0 { outstandingTools.insert(id) } }; calls.forEach { onEvent?($0) } }
            if responsePending && outstandingTools.isEmpty && status != "failed" { responsePending = false; try await requestResponse() }
            if status == "failed" {
                state = .failed("Voice could not complete the response. Check AI service in Settings and try again.")
                _ = flushAudio(); transport?.close()
            }
        case .error(let code, let message):
            if code == "conversation_already_has_active_response" { responseInFlight = true; responsePending = true; return }
            // Push-to-talk races: the response already finished, or the held turn had no audio. Neither ends the session.
            if code == "response_cancel_not_active" { responseInFlight = false; return }
            if code == "input_audio_buffer_commit_empty" { return }
            if code == "invalid_api_key" { throw RealtimeConnectionError.authentication }
            if code == "insufficient_quota" { throw RealtimeConnectionError.quota }
            state = .failed(message); _ = flushAudio(); transport?.close()
        default: break
        }
        onEvent?(event)
    }
}
