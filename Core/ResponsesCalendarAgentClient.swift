import Foundation
import CoreGraphics
import ImageIO

@MainActor
final class ResponsesCalendarAgentClient: CalendarAgentModelClient {
    enum ClientError: LocalizedError {
        case missingCredentials, invalidResponse, request(String), imageEncoding
        case http(Int, String, Double?)
        var errorDescription: String? {
            switch self {
            case .missingCredentials: return "Connect ChatGPT or add an OpenAI API key to use the calendar agent."
            case .invalidResponse: return "The calendar agent returned an incomplete response."
            case .request(let message): return message
            case .http(_, let message, _): return message
            case .imageEncoding: return "Could not prepare the screenshot."
            }
        }
    }
    var onRetry: ((String) -> Void)?
    var prefersAPIKey: () -> Bool = { false }

    /// Retries only failed HTTP handshakes, before any successful stream or tool executes.
    static func withRetry<T>(operation: () async throws -> T,
                             onRetry: (String) -> Void = { _ in },
                             sleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws -> T {
        for attempt in 0...2 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                let delay: Double
                if case ClientError.http(let status, _, let retryAfter) = error,
                   status == 408 || status == 409 || status >= 500 {
                    delay = retryAfter ?? Double(1 << attempt)
                } else if let network = error as? URLError,
                          [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(network.code) {
                    delay = Double(1 << attempt)
                } else { throw error }
                guard attempt < 2, delay <= 30 else { throw error }
                onRetry("Connection interrupted · Retrying (\(attempt + 1)/2)")
                try await sleep(max(delay, 0))
            }
        }
        throw ClientError.invalidResponse
    }

    func turn(conversation: [AgentMessage], imageDataURL: String?, instructions: String,
              tools: [JSONValue], onText: @escaping @MainActor (String) -> Void) async throws -> AgentModelResponse {
        let token: String
        let model: String
        if !prefersAPIKey() {
            let access = try await ChatGPTConnection.shared.access()
            token = access.token; model = access.model
        } else {
            guard let key = try? OpenAIAPIKeyStore.load(), !key.isEmpty else { throw ClientError.missingCredentials }
            token = key; model = OpenAIEventAnalyzer.modelName
        }
        var input = conversation.map(\.value)
        if let imageDataURL, let last = input.indices.last,
           input[last].objectValue?["content"]?.arrayValue == nil {
            let object = input[last].objectValue ?? [:]
            let text = object["content"]?.stringValue ?? "Read this screenshot and propose calendar actions."
            input[last] = .object(["role": .string("user"), "content": .array([
                .object(["type": .string("input_text"), "text": .string(text)]),
                .object(["type": .string("input_image"), "image_url": .string(imageDataURL), "detail": .string("high")])
            ])])
        }
        let payload = JSONValue.object(["model": .string(model), "store": .bool(false), "stream": .bool(true),
            "instructions": .string(instructions), "input": .array(input), "tools": .array(Self.requestTools(tools, usesChatGPTPlan: !prefersAPIKey())), "parallel_tool_calls": .bool(false),
            "include": .array([.string("reasoning.encrypted_content")])])
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 90
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let bytes = try await Self.withRetry(operation: {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                var body = ""
                for try await line in bytes.lines { body += line; if body.count > 8000 { break } }
                throw ClientError.http(http.statusCode, Self.failureMessage(http: http, data: Data(body.utf8)),
                    http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
            }
            return bytes
        }, onRetry: { [weak self] in self?.onRetry?($0) })
        var parser = CalendarAgentStreamParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let event = try parser.consume(line: line) {
                if let delta = event.objectValue?["delta"]?.stringValue,
                   event.objectValue?["type"]?.stringValue == "response.output_text.delta" { onText(delta) }
                if let completed = parser.completed { return try Self.decodeResponse(completed) }
            }
        }
        throw ClientError.invalidResponse
    }
    nonisolated static func requestTools(_ tools: [JSONValue], usesChatGPTPlan: Bool) -> [JSONValue] {
        guard usesChatGPTPlan, !tools.isEmpty else { return tools }
        return [.object(["type": .string("namespace"), "name": .string("calendar"),
            "description": .string("Calshot calendar tools. Calendar writes require user approval."), "tools": .array(tools)])]
    }
    nonisolated static func failureMessage(http: HTTPURLResponse, data: Data) -> String {
        let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
        let error = object?["error"]?.objectValue
        let detail = error?["message"]?.stringValue ?? object?["error_description"]?.stringValue ?? object?["detail"]?.stringValue
            ?? object?["message"]?.stringValue
            ?? (http.statusCode >= 500 ? "The service did not complete the request. Try again shortly." : "Check your AI connection in Settings.")
        let code = (error?["code"]?.stringValue ?? object?["error"]?.stringValue).map { " Code: \($0)." } ?? ""
        let parameter = error?["param"]?.stringValue.map { " Parameter: \($0)." } ?? ""
        let identifier = http.value(forHTTPHeaderField: "x-request-id") ?? http.value(forHTTPHeaderField: "cf-ray")
        let requestID = identifier.map { " Request ID: \($0)." } ?? ""
        return "OpenAI request failed (HTTP \(http.statusCode)): " + String(detail.prefix(2000)) + code + parameter + requestID
    }

    nonisolated static func streamFailureMessage(_ event: JSONValue) -> String {
        let object = event.objectValue ?? [:]
        let response = object["response"]?.objectValue ?? [:]
        let error = response["error"]?.objectValue ?? object["error"]?.objectValue ?? object
        let reason = response["incomplete_details"]?.objectValue?["reason"]?.stringValue
        let detail = error["message"]?.stringValue ?? response["error"]?.stringValue
            ?? (reason == "max_output_tokens" ? "The model reached its output limit before finishing." : "OpenAI stopped the calendar response before completion.")
        var message = String(detail.prefix(2000))
        if let code = error["code"]?.stringValue { message += " Code: \(code)." }
        if let parameter = error["param"]?.stringValue { message += " Parameter: \(parameter)." }
        if let reason { message += " Reason: \(reason)." }
        if let id = response["id"]?.stringValue { message += " Response ID: \(id)." }
        return message
    }

    static func decodeResponse(_ response: JSONValue) throws -> AgentModelResponse {
        guard let outputs = response.objectValue?["output"]?.arrayValue else { throw ClientError.invalidResponse }
        var calls: [AgentFunctionCall] = []
        var text: [String] = []
        for output in outputs {
            guard let item = output.objectValue else { throw ClientError.invalidResponse }
            if item["type"]?.stringValue == "function_call" {
                guard let name = item["name"]?.stringValue, let callID = item["call_id"]?.stringValue,
                      let arguments = item["arguments"]?.stringValue else { throw ClientError.invalidResponse }
                calls.append(.init(name: name, callID: callID, arguments: arguments))
            }
            if item["type"]?.stringValue == "message" {
                for content in item["content"]?.arrayValue ?? [] {
                    if let value = content.objectValue?["text"]?.stringValue { text.append(value) }
                    if let value = content.objectValue?["refusal"]?.stringValue { text.append(value) }
                }
            }
        }
        return .init(output: outputs.map { AgentMessage(value: $0) }, calls: calls, text: text.joined(separator: "\n"))
    }
    static func imageDataURL(_ image: CGImage) throws -> String {
        let scale = min(1.0, 3000.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ClientError.imageEncoding }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw ClientError.imageEncoding }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw ClientError.imageEncoding }
        CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ClientError.imageEncoding }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }
}

/// Only terminal completed output is executable. Argument deltas are never interpreted.
struct CalendarAgentStreamParser {
    private(set) var completed: JSONValue?
    private var items: [Int: JSONValue] = [:]
    mutating func consume(line: String) throws -> JSONValue? {
        guard line.hasPrefix("data:"), let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let event = try? JSONDecoder().decode(JSONValue.self, from: data), let object = event.objectValue else { return nil }
        switch object["type"]?.stringValue {
        case "response.failed", "response.incomplete", "error":
            throw ResponsesCalendarAgentClient.ClientError.request(ResponsesCalendarAgentClient.streamFailureMessage(event))
        case "response.output_item.done":
            if case .number(let index) = object["output_index"], let item = object["item"] { items[Int(index)] = item }
        case "response.completed":
            guard var response = object["response"]?.objectValue else { throw ResponsesCalendarAgentClient.ClientError.invalidResponse }
            if (response["output"]?.arrayValue ?? []).isEmpty, !items.isEmpty {
                response["output"] = .array(items.keys.sorted().compactMap { items[$0] })
            }
            completed = .object(response)
        default: break
        }
        return event
    }
}
