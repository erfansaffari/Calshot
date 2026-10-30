import Foundation
import CryptoKit

struct MemoryItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case preference, fact, person, routine }
    enum Origin: String, Codable, Sendable { case explicit, suggested }
    enum Status: String, Codable, Sendable { case active, pendingApproval }
    var id = UUID()
    var version = UUID()
    var ownerID: UUID?
    var kind: Kind
    var text: String
    var origin: Origin
    var status: Status
    var sourceReference: String?
    var createdAt: Date
    var updatedAt: Date
    var expiresAt: Date?
    func isExpired(at date: Date) -> Bool { expiresAt.map { $0 <= date } ?? false }
}

/// One instance per account directory. A failed load permanently blocks this instance's writes.
final class PersonalMemoryStore {
    struct Tombstone: Codable { let normalizedTextHash: String; let forgottenAt: Date }
    struct Document: Codable {
        var schemaVersion = 1
        var items: [MemoryItem] = []
        var tombstones: [Tombstone] = []
    }
    let directory: URL
    let ownerID: UUID?
    var url: URL { directory.appendingPathComponent("personal-memory-v1.json") }
    private(set) var document = Document()
    private(set) var error: String?
    private(set) var token = UUID().uuidString
    var items: [MemoryItem] { document.items }
    init(directory: URL, ownerID: UUID? = nil) {
        self.directory = directory; self.ownerID = ownerID
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let doc = try decoder.decode(Document.self, from: Data(contentsOf: url))
                try validate(doc); document = doc
            }
        } catch { self.error = "Couldn’t read personal memory. The file was kept unchanged. \(error.localizedDescription)" }
    }
    static func normalize(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(normalize(text).utf8)).map { String(format: "%02x", $0) }.joined() }
    private func validate(_ doc: Document) throws {
        guard doc.schemaVersion == 1, doc.items.count <= 500, Set(doc.items.map(\.id)).count == doc.items.count else { throw CalendarToolArgumentError("Unsupported or invalid memory document (maximum 500 items).") }
        var keys = Set<String>()
        for item in doc.items {
            guard item.ownerID == ownerID, item.text == item.text.trimmingCharacters(in: .whitespacesAndNewlines), (1...500).contains(item.text.count),
                  keys.insert(item.kind.rawValue + ":" + Self.normalize(item.text)).inserted,
                  !doc.tombstones.contains(where: { $0.normalizedTextHash == Self.hash(item.text) }) else { throw CalendarToolArgumentError("Invalid, duplicate or forgotten memory.") }
        }
    }
    private func save(_ doc: Document) throws {
        if let error { throw CalendarToolArgumentError(error) }
        try validate(doc)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        // Atomic replacement preserves the previous document on serialization/write failure.
        try encoder.encode(doc).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        document = doc; token = UUID().uuidString
    }
    @discardableResult
    func add(kind: MemoryItem.Kind, text: String, origin: MemoryItem.Origin = .explicit, sourceReference: String? = nil, expiresAt: Date? = nil, now: Date = .now) throws -> MemoryItem {
        let item = MemoryItem(ownerID: ownerID, kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines), origin: origin,
                              status: origin == .explicit ? .active : .pendingApproval, sourceReference: sourceReference, createdAt: now, updatedAt: now, expiresAt: expiresAt)
        var doc = document; doc.items.append(item); try save(doc); return item
    }
    @discardableResult
    func suggest(kind: MemoryItem.Kind, text: String, sourceReference: String? = nil) throws -> MemoryItem {
        try add(kind: kind, text: text, origin: .suggested, sourceReference: sourceReference)
    }
    func change(id: UUID, expectedVersion: UUID, kind: MemoryItem.Kind? = nil, text: String? = nil, approve: Bool = false) throws {
        var doc = document
        guard let index = doc.items.firstIndex(where: { $0.id == id && $0.version == expectedVersion }) else { throw CalendarToolArgumentError("This memory changed. Use the latest version and try again.") }
        if let kind { doc.items[index].kind = kind }
        if let text { doc.items[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if approve {
            guard doc.items[index].status == .pendingApproval else { throw CalendarToolArgumentError("This suggestion was already reviewed.") }
            doc.items[index].status = .active
        }
        doc.items[index].version = UUID(); doc.items[index].updatedAt = .now; try save(doc)
    }
    func remove(id: UUID, expectedVersion: UUID, forget: Bool = true) throws {
        guard let item = items.first(where: { $0.id == id && $0.version == expectedVersion }) else { throw CalendarToolArgumentError("This memory changed. Use the latest version and try again.") }
        guard forget || item.status == .pendingApproval else { throw CalendarToolArgumentError("Only a pending suggestion can be rejected.") }
        var doc = document; doc.items.removeAll { $0.id == id }
        if forget { doc.tombstones.append(.init(normalizedTextHash: Self.hash(item.text), forgottenAt: .now)) }
        try save(doc)
    }
    func clear(confirmed: Bool) throws {
        guard confirmed else { throw CalendarToolArgumentError("Confirm forgetting all personal memories first.") }
        var doc = document
        doc.tombstones += doc.items.map { .init(normalizedTextHash: Self.hash($0.text), forgottenAt: .now) }
        doc.items = []; try save(doc)
    }
}

@MainActor
extension CalshotModel {
    /// Resolve from identity, rather than the possibly still-switching history store.
    var personalMemory: PersonalMemoryStore {
        var root = accountMemoryRoot.locationURL
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".calshot-account").path) { root.deleteLastPathComponent() }
        let directory = account.userID.map { root.appendingPathComponent($0.uuidString, isDirectory: true) } ?? root
        if let cached = personalMemoryCache, cached.directory == directory, cached.ownerID == account.userID { return cached }
        let store = PersonalMemoryStore(directory: directory, ownerID: account.userID)
        personalMemoryCache = store; return store
    }
    func personalMemoryContext(for request: String, relevantOnly: Bool = false) -> String {
        MemoryContextBuilder.build(request: request, items: personalMemory.items, characterBudget: relevantOnly ? 2_000 : 6_000, relevantOnly: relevantOnly)
    }
    @discardableResult
    func suggestPersonalMemory(kind: MemoryItem.Kind, text: String, sourceReference: String? = nil) throws -> MemoryItem {
        try personalMemory.suggest(kind: kind, text: text, sourceReference: sourceReference)
    }
    func handlePersonalMemoryAction(_ action: String, body: [String: Any], isNotch: Bool) throws {
        guard (isNotch && ["approveMemory", "rejectMemory"].contains(action)) || (!isNotch && workspaceSelection == .settings) else { throw CalendarToolArgumentError("Manage personal memory in Settings.") }
        let store = personalMemory
        var allowed: Set<String> = ["action", "id", "token"]
        switch action {
        case "addMemory": allowed.formUnion(["kind", "text"])
        case "editMemory": allowed.formUnion(["memoryID", "expectedVersion", "kind", "text"])
        case "approveMemory", "forgetMemory": allowed.formUnion(["memoryID", "expectedVersion"])
        case "rejectMemory": allowed.formUnion(["memoryID", "expectedVersion", "dontSuggestAgain"])
        case "clearMemory": allowed.insert("confirmed")
        default: throw CalendarToolArgumentError("Unknown memory action.")
        }
        guard Set(body.keys).isSubset(of: allowed), body["token"] as? String == store.token else { throw CalendarToolArgumentError("Memory changed. Check the latest memories and try again.") }
        func boolean(_ key: String) throws -> Bool {
            guard let value = body[key], CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool else { throw CalendarToolArgumentError("\(key) must be a boolean.") }
            return flag
        }
        if action == "clearMemory" { try store.clear(confirmed: boolean("confirmed")); return }
        if action == "addMemory" || action == "editMemory" {
            guard let raw = body["kind"] as? String, let kind = MemoryItem.Kind(rawValue: raw), let text = body["text"] as? String, (1...500).contains(text.trimmingCharacters(in: .whitespacesAndNewlines).count) else { throw CalendarToolArgumentError("Choose a memory kind and enter 1–500 characters.") }
            if action == "addMemory" { try store.add(kind: kind, text: text); return }
        }
        guard let id = (body["memoryID"] as? String).flatMap(UUID.init(uuidString:)), let version = (body["expectedVersion"] as? String).flatMap(UUID.init(uuidString:)) else { throw CalendarToolArgumentError("Choose a current memory and version.") }
        if isNotch {
            guard store.items.contains(where: { $0.id == id && $0.version == version && $0.status == .pendingApproval }) else { throw CalendarToolArgumentError("Choose a pending memory suggestion.") }
        }
        switch action {
        case "editMemory": try store.change(id: id, expectedVersion: version, kind: MemoryItem.Kind(rawValue: body["kind"] as! String), text: body["text"] as? String)
        case "approveMemory": try store.change(id: id, expectedVersion: version, approve: true)
        case "forgetMemory": try store.remove(id: id, expectedVersion: version)
        case "rejectMemory": try store.remove(id: id, expectedVersion: version, forget: boolean("dontSuggestAgain"))
        default: throw CalendarToolArgumentError("Unknown memory action.")
        }
    }
}

