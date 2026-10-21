import Foundation

/// JSON that can safely cross concurrency boundaries. Tool payloads never contain images.
indirect enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode([String: JSONValue].self) { self = .object(decoded) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    func jsonString() -> String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "null" }
}

public struct AgentTurn: Codable, Sendable, Equatable {
    public var role: String
    public var toolName: String?
    public var arguments: String?
    public var result: String?
    public var content: String?
    public var callID: String?
    public var sharedCalendarContext: Bool?
    public init(role: String, toolName: String? = nil, arguments: String? = nil, result: String? = nil,
         content: String? = nil, callID: String? = nil) {
        self.role = role; self.toolName = toolName; self.arguments = arguments
        self.result = result; self.content = content; self.callID = callID
    }
}

struct AgentMessage: Sendable, Equatable {
    var value: JSONValue
    static func text(role: String, content: String) -> Self {
        Self(value: .object(["role": .string(role), "content": .string(content)]))
    }
}
struct AgentFunctionCall: Sendable, Equatable {
    let name: String
    let callID: String
    let arguments: String
}
struct AgentModelResponse: Sendable {
    var output: [AgentMessage]
    var calls: [AgentFunctionCall]
    var text: String
    init(output: [AgentMessage] = [], calls: [AgentFunctionCall] = [], text: String = "") {
        self.output = output; self.calls = calls; self.text = text
    }
}

@MainActor
protocol CalendarAgentModelClient {
    func turn(conversation: [AgentMessage], imageDataURL: String?, instructions: String,
              tools: [JSONValue], onText: @escaping @MainActor (String) -> Void) async throws -> AgentModelResponse
}
@MainActor
protocol CalendarAgentToolExecuting: AnyObject {
    func execute(name: String, arguments: JSONValue, sessionID: UUID) async -> String
    func cancelPending(sessionID: UUID)
}
