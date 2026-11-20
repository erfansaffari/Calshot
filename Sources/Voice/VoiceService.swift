import Foundation
import os

/// Durations only: never request content.
private let serviceLog = Logger(subsystem: "com.calshot.voice", category: "service")

/// Calshot's voice server (Server/): listening tokens and spoken sentences, which Calshot provides for every verified
/// account. Requests carry only the Calshot session; Google credentials never reach the Mac.
@MainActor protocol VoiceServicing: AnyObject {
    /// A one-use, ten-minute token for the transcription WebSocket, biased toward these calendar words.
    func listeningGrant(vocabulary: [String]) async throws -> VoiceListeningGrant
    /// Raw 24 kHz mono PCM16 of one sentence, streamed as it is generated.
    func speech(_ text: String, voice: String) -> AsyncThrowingStream<Data, Error>
    /// Opens the connections the first sentence needs, when voice starts. Speaks and counts nothing.
    func warm()
}
extension VoiceServicing { func warm() {} }

struct VoiceListeningGrant: Equatable, Sendable {
    var token: String
    var url: URL
    var model: String
}

enum VoiceServiceError: LocalizedError, Equatable {
    case signIn, verify, limit, unavailable
    var errorDescription: String? {
        switch self {
        case .signIn: "Sign in to Calshot again to use voice."
        case .verify: "Verify your Calshot account to use voice."
        case .limit: "You’ve reached today’s voice limit. Typed requests still work, and voice is available again tomorrow."
        case .unavailable: "Calshot voice is unavailable right now. Check your connection and try again."
        }
    }
    static func from(status: Int) -> VoiceServiceError {
        switch status { case 401: .signIn; case 403: .verify; case 429: .limit; default: .unavailable }
    }
}

@MainActor final class CalshotVoiceService: VoiceServicing {
    static let baseURL = URL(string: "https://calshot-voice.vercel.app")!
    private let session: () async throws -> String
    private let base: URL
    init(base: URL = CalshotVoiceService.baseURL, session: @escaping () async throws -> String) { self.base = base; self.session = session }

    private func request(_ path: String, body: [String: Any]) async throws -> URLRequest {
        try await request(path, data: JSONSerialization.data(withJSONObject: body))
    }
    func request(_ path: String, data: Data, timeout: TimeInterval = 20) async throws -> URLRequest {
        let token: String
        do { token = try await session() } catch { throw VoiceServiceError.signIn }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = timeout
        return request
    }

    func listeningGrant(vocabulary: [String]) async throws -> VoiceListeningGrant {
        let request = try await request("api/voice/ears-token", body: ["vocabulary": vocabulary])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw VoiceServiceError.from(status: status) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty,
              let raw = object["url"] as? String, let url = URL(string: raw), url.scheme == "wss",
              url.host == "generativelanguage.googleapis.com",
              let model = object["model"] as? String else { throw VoiceServiceError.unavailable }
        return .init(token: token, url: url, model: model)
    }

    func warm() {
        Task { @MainActor in
            let started = Date()
            guard let request = try? await self.request("api/voice/speak", body: ["warm": true]) else { return }
            do { for try await _ in StreamingDownloads.shared.chunks(request) {} } catch { return }
            serviceLog.info("server warm: \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
        }
    }

    func speech(_ text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let request = try await self.request("api/voice/speak", body: ["text": text, "voice": voice])
                    for try await chunk in StreamingDownloads.shared.chunks(request) { try Task.checkCancellation(); continuation.yield(chunk) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The voice agent's model requests, run by Calshot's voice server on GPT-6.1 Sol with the Ultrafast tier, the way
/// HeyClicky runs its voice. The Mac sends the session's conversation and function tools; the server fixes the model,
/// tier, effort and limits and relays OpenAI's Responses stream, which is read exactly like the typed agent's.
@MainActor final class CalshotBrainClient: CalendarAgentModelClient {
    private let service: CalshotVoiceService
    init(service: CalshotVoiceService) { self.service = service }

    func turn(conversation: [AgentMessage], imageDataURL: String?, instructions: String, tools: [JSONValue],
              onText: @escaping @MainActor (String) -> Void) async throws -> AgentModelResponse {
        try await turn(conversation: conversation, imageDataURL: imageDataURL, instructions: instructions, tools: tools, options: .init(), onText: onText)
    }
    func turn(conversation: [AgentMessage], imageDataURL: String?, instructions: String, tools: [JSONValue],
              options: AgentRequestOptions, onText: @escaping @MainActor (String) -> Void) async throws -> AgentModelResponse {
        let body = Self.body(conversation: conversation, instructions: instructions, tools: tools, cacheKey: options.cacheKey)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let request = try await service.request("api/voice/brain", data: encoder.encode(body), timeout: 60)
        var parser = CalendarAgentStreamParser(), pending = Data()
        func handle(_ line: String) throws -> AgentModelResponse? {
            guard let event = try parser.consume(line: line)?.objectValue else { return nil }
            if event["type"]?.stringValue == "response.output_text.delta", let delta = event["delta"]?.stringValue { onText(delta) }
            // A finished text item ("Checking your calendar.") is spoken before the tool call after it streams.
            if event["type"]?.stringValue == "response.output_text.done" { onText("\n") }
            guard let completed = parser.completed else { return nil }
            let response = completed.objectValue, usage = AgentUsage(responses: response?["usage"])
            serviceLog.info("brain \(response?["model"]?.stringValue ?? "?", privacy: .public) tier \(response?["service_tier"]?.stringValue ?? "none", privacy: .public), input \(usage?.input ?? 0, privacy: .public) cached \(usage?.cachedInput ?? 0, privacy: .public)")
            return try ResponsesCalendarAgentClient.decodeResponse(completed)
        }
        for try await chunk in StreamingDownloads.shared.chunks(request) {
            try Task.checkCancellation()
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                pending.removeSubrange(pending.startIndex...newline)
                if let response = try handle(line) { return response }
            }
            if pending.count > 4_000_000 { throw VoiceServiceError.unavailable }
        }
        if let response = try handle(String(decoding: pending, as: UTF8.self)) { return response }
        throw VoiceServiceError.unavailable
    }
    /// The conversation as the server accepts it: conversation items, function tools and the session's cache key.
    nonisolated static func body(conversation: [AgentMessage], instructions: String, tools: [JSONValue], cacheKey: String?) -> JSONValue {
        var input = conversation.map(\.value)
        if !instructions.isEmpty { input.insert(.object(["role": .string("developer"), "content": .string(instructions)]), at: 0) }
        return .object(["input": .array(input), "tools": .array(tools),
                        "cache_key": .string(cacheKey ?? "calshot-voice-" + UUID().uuidString.lowercased())])
    }
}

/// Delivers response bodies in the chunks URLSession receives them, instead of byte by byte. One shared session keeps
/// the connection to the voice server warm, so each sentence skips the TLS handshake.
final class StreamingDownloads: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = StreamingDownloads()
    private let lock = NSLock()
    private var streams: [Int: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    func chunks(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            lock.withLock { streams[task.taskIdentifier] = continuation }
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }
    private func stream(_ task: URLSessionTask, remove: Bool = false) -> AsyncThrowingStream<Data, Error>.Continuation? {
        lock.withLock { remove ? streams.removeValue(forKey: task.taskIdentifier) : streams[task.taskIdentifier] }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let timing = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Server-Timing") {
            serviceLog.info("server timing: \(String(timing.prefix(120)), privacy: .public)")
        }
        // 204 answers a warm-up, which has no body.
        guard status == 200 || status == 204 else {
            stream(dataTask, remove: true)?.finish(throwing: VoiceServiceError.from(status: status)); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { stream(dataTask)?.yield(data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = stream(task, remove: true) else { return }
        if let error, (error as? URLError)?.code != .cancelled { continuation.finish(throwing: VoiceServiceError.unavailable) }
        else { continuation.finish() }
    }
}
