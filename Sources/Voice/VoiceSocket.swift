import Foundation

/// A text WebSocket. All operations and callbacks are isolated to the main actor. No credentials are logged.
@MainActor
protocol VoiceSocket: AnyObject {
    func connect(url: URL, headers: [String: String]) async throws
    func send(text: String) async throws
    func receive() -> AsyncThrowingStream<String, Error>
    func close()
}

enum VoiceSocketError: Error, Equatable {
    case unauthorized, unavailable, invalidFrame
}

@MainActor
final class URLSessionVoiceSocket: VoiceSocket {
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    func connect(url: URL, headers: [String: String]) async throws {
        close()
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1024 * 1024
        socket = task
        task.resume()
    }
    func send(text: String) async throws {
        guard let socket else { throw VoiceSocketError.unavailable }
        do { try await socket.send(.string(text)) } catch { throw classify(socket) }
    }
    func receive() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            guard let socket else { continuation.finish(throwing: VoiceSocketError.unavailable); return }
            reader = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        switch try await socket.receive() {
                        case .string(let text): continuation.yield(text)
                        case .data(let data):
                            guard let text = String(data: data, encoding: .utf8) else { throw VoiceSocketError.invalidFrame }
                            continuation.yield(text)
                        @unknown default: throw VoiceSocketError.invalidFrame
                        }
                    }
                } catch { continuation.finish(throwing: self?.classify(socket) ?? VoiceSocketError.unavailable) }
            }
        }
    }
    private func classify(_ socket: URLSessionWebSocketTask) -> VoiceSocketError {
        let status = (socket.response as? HTTPURLResponse)?.statusCode
        return status == 401 || status == 403 ? .unauthorized : .unavailable
    }
    func close() {
        reader?.cancel(); reader = nil
        continuation?.finish(); continuation = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }
}
