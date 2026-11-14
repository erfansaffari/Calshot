import Foundation
import CryptoKit

struct MemoryItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case preference, fact, person, routine, style, goal }
    enum Origin: String, Codable, Sendable { case explicit, suggested, learned }
    enum Status: String, Codable, Sendable { case active, pendingApproval }
    /// Where the knowledge came from. Nil on version 1 items, which were all user-stated or user-approved.
    /// `screen` knowledge was inferred from what was on the user's screen; it never leaves this device.
    enum Source: String, Codable, Sendable { case user, conversation, behavior, calendar, screen }
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
    var source: Source?
    /// 0–1. Repetition raises it; inferred items start lower than things the user said.
    var confidence: Double?
    /// How many separate times this was said, observed or learned.
    var evidenceCount: Int?
    var lastSeenAt: Date?
    func isExpired(at date: Date) -> Bool { expiresAt.map { $0 <= date } ?? false }
    var effectiveConfidence: Double { confidence ?? 1 }
}

/// Native, model-free counters of how the user reacts. They become style knowledge; they never authorize anything.
struct BehaviorSignals: Codable, Equatable, Sendable {
    /// Spoken replies that finished or were cut off, newest last (bounded).
    var voiceReplies: [Date] = []
    /// Replies the user talked over before they finished, newest last (bounded).
    var voiceInterruptions: [Date] = []
    static let limit = 200
    static let window: TimeInterval = 30 * 86_400
    func recent(_ dates: [Date], now: Date) -> Int { dates.filter { now.timeIntervalSince($0) <= Self.window }.count }
    /// Short replies become the default once the user has cut Calshot off at least three times and in a quarter of replies.
    func prefersShortSpokenReplies(now: Date) -> Bool {
        let interrupted = recent(voiceInterruptions, now: now), replies = max(recent(voiceReplies, now: now), interrupted)
        return interrupted >= 3 && Double(interrupted) / Double(replies) >= 0.25
    }
}

/// A short dated note of one finished conversation, so later sessions know what was discussed and done.
/// Kept on this device only; context, never authorization.
struct ConversationNote: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var at: Date
    var text: String
    /// "voice" or "typed".
    var channel: String
}

/// One instance per account directory. A failed load permanently blocks this instance's writes.
final class PersonalMemoryStore {
    struct Tombstone: Codable, Equatable { let normalizedTextHash: String; let forgottenAt: Date }
    struct Document: Codable {
        var schemaVersion = PersonalMemoryStore.schemaVersion
        var items: [MemoryItem] = []
        var tombstones: [Tombstone] = []
        var signals: BehaviorSignals?
        var sync: SyncState?
        /// Newest last. Never synced.
        var notes: [ConversationNote]?
    }
    /// What this device has sent to and read from the account copy. Never synced itself.
    struct SyncState: Codable, Equatable {
        /// Server time of the last read; the next read asks only for later changes.
        var cursor: Date?
        /// Item id → version last sent or received, so unchanged items are not sent again.
        var known: [UUID: UUID] = [:]
        /// Items removed here that the account copy still has, with when they were removed.
        var pendingDeletes: [UUID: Date] = [:]
        var sentTombstones: Set<String> = []
    }
    struct RemoteItem { let id: UUID; let item: MemoryItem?; let deleted: Bool; let updatedAt: Date }
    struct OutgoingChanges: Equatable {
        var items: [MemoryItem] = []
        var deletes: [(id: UUID, at: Date)] = []
        var tombstones: [Tombstone] = []
        var isEmpty: Bool { items.isEmpty && deletes.isEmpty && tombstones.isEmpty }
        static func == (a: Self, b: Self) -> Bool { a.items == b.items && a.deletes.map(\.id) == b.deletes.map(\.id) && a.tombstones.map(\.normalizedTextHash) == b.tombstones.map(\.normalizedTextHash) }
    }
    static let schemaVersion = 2
    static let shortRepliesText = "Keep spoken replies short: one or two sentences, with details only when asked."
    let directory: URL
    let ownerID: UUID?
    var url: URL { directory.appendingPathComponent("personal-memory-v1.json") }
    private(set) var document = Document()
    private(set) var error: String?
    private(set) var token = UUID().uuidString
    var items: [MemoryItem] { document.items }
    var signals: BehaviorSignals { document.signals ?? BehaviorSignals() }
    var notes: [ConversationNote] { document.notes ?? [] }
    static let noteLimit = 200
    /// Records what one conversation was about. The oldest notes fall off past the limit.
    @discardableResult
    func addNote(_ text: String, channel: String, now: Date = .now) throws -> ConversationNote? {
        let clean = String(text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(600))
        guard clean.count >= 8, !isForgotten(clean) else { return nil }
        let note = ConversationNote(at: now, text: clean, channel: channel)
        var doc = document; doc.notes = Array(((doc.notes ?? []) + [note]).suffix(Self.noteLimit))
        try save(doc); return note
    }
    func removeNote(id: UUID) throws {
        guard notes.contains(where: { $0.id == id }) else { throw CalendarToolArgumentError("That conversation note is already gone.") }
        var doc = document; doc.notes?.removeAll { $0.id == id }
        try save(doc)
    }
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
    func isForgotten(_ text: String) -> Bool { document.tombstones.contains { $0.normalizedTextHash == Self.hash(text) } }
    private func validate(_ doc: Document) throws {
        guard (1...Self.schemaVersion).contains(doc.schemaVersion), doc.items.count <= 500, Set(doc.items.map(\.id)).count == doc.items.count,
              (doc.notes ?? []).count <= Self.noteLimit else { throw CalendarToolArgumentError("Unsupported or invalid memory document (maximum 500 items).") }
        var keys = Set<String>()
        for item in doc.items {
            guard item.ownerID == ownerID, item.text == item.text.trimmingCharacters(in: .whitespacesAndNewlines), (1...500).contains(item.text.count),
                  keys.insert(item.kind.rawValue + ":" + Self.normalize(item.text)).inserted,
                  !doc.tombstones.contains(where: { $0.normalizedTextHash == Self.hash(item.text) }) else { throw CalendarToolArgumentError("Invalid, duplicate or forgotten memory.") }
        }
    }
    private func save(_ doc: Document, recordDeletes: Bool = true) throws {
        if let error { throw CalendarToolArgumentError(error) }
        var doc = doc; doc.schemaVersion = Self.schemaVersion
        if recordDeletes {
            // Anything removed here is removed from the account copy on the next sync.
            let kept = Set(doc.items.map(\.id)), now = Date()
            var sync = doc.sync ?? SyncState()
            for item in document.items where !kept.contains(item.id) { sync.pendingDeletes[item.id] = now; sync.known[item.id] = nil }
            if sync != (doc.sync ?? SyncState()) { doc.sync = sync }
        }
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
                              status: origin == .suggested ? .pendingApproval : .active, sourceReference: sourceReference, createdAt: now, updatedAt: now, expiresAt: expiresAt)
        var doc = document; doc.items.append(item); try save(doc); return item
    }
    @discardableResult
    func suggest(kind: MemoryItem.Kind, text: String, sourceReference: String? = nil) throws -> MemoryItem {
        try add(kind: kind, text: text, origin: .suggested, sourceReference: sourceReference)
    }
    enum LearnOutcome: Equatable { case added(MemoryItem), reinforced(MemoryItem), updated(MemoryItem), forgottenBefore }
    /// Adds knowledge as active at once, or reinforces the same knowledge already held (any kind).
    /// `replacing` supersedes an older item: its text is tombstoned so retained history cannot bring it back.
    /// Inferred, low-confidence knowledge expires unless it is seen again. Never re-creates forgotten text.
    @discardableResult
    func learn(kind: MemoryItem.Kind, text: String, source: MemoryItem.Source, confidence: Double? = nil, replacing: UUID? = nil,
               sourceReference: String? = nil, now: Date = .now) throws -> LearnOutcome {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...500).contains(clean.count) else { throw CalendarToolArgumentError("Memory text must be 1–500 characters.") }
        if isForgotten(clean) { return .forgottenBefore }
        let base = min(1, max(0.1, confidence ?? (source == .user ? 0.95 : 0.6)))
        func expiry(_ value: Double) -> Date? { source == .user || (value >= 0.75 && source != .screen) ? nil : now.addingTimeInterval(90 * 86_400) }
        var doc = document
        if let index = doc.items.firstIndex(where: { Self.normalize($0.text) == Self.normalize(clean) }) {
            var item = doc.items[index]
            let evidence = (item.evidenceCount ?? 1) + 1
            item.evidenceCount = evidence; item.lastSeenAt = now; item.updatedAt = now; item.version = UUID()
            item.confidence = min(1, max(item.effectiveConfidence, base) + 0.1)
            if source == .user { item.source = .user; item.origin = .explicit; item.status = .active }
            item.expiresAt = item.source == .user ? nil : expiry(item.effectiveConfidence).map { max($0, item.expiresAt ?? $0) }
            doc.items[index] = item
            if let replacing, replacing != item.id, let old = doc.items.firstIndex(where: { $0.id == replacing }) {
                doc.tombstones.append(.init(normalizedTextHash: Self.hash(doc.items[old].text), forgottenAt: now)); doc.items.remove(at: old)
            }
            try save(doc); return .reinforced(item)
        }
        if let replacing, let index = doc.items.firstIndex(where: { $0.id == replacing }) {
            var item = doc.items[index]
            doc.tombstones.append(.init(normalizedTextHash: Self.hash(item.text), forgottenAt: now))
            item.text = clean; item.kind = kind; item.version = UUID(); item.updatedAt = now; item.lastSeenAt = now
            item.source = source == .user || item.source == .user ? .user : source
            item.origin = item.source == .user ? .explicit : .learned; item.status = .active
            item.confidence = max(base, item.effectiveConfidence * 0.9); item.evidenceCount = 1
            item.expiresAt = item.source == .user ? nil : expiry(item.effectiveConfidence)
            item.sourceReference = sourceReference ?? item.sourceReference
            doc.items[index] = item
            try save(doc); return .updated(item)
        }
        if doc.items.count >= 500 {
            // Make room by dropping the weakest inferred knowledge; never what the user said.
            guard let weakest = doc.items.indices.filter({ doc.items[$0].source != nil && doc.items[$0].source != .user })
                .min(by: { (doc.items[$0].effectiveConfidence, doc.items[$0].lastSeenAt ?? doc.items[$0].updatedAt) < (doc.items[$1].effectiveConfidence, doc.items[$1].lastSeenAt ?? doc.items[$1].updatedAt) })
            else { throw CalendarToolArgumentError("Memory is full. Forget something in Settings first.") }
            doc.items.remove(at: weakest)
        }
        let item = MemoryItem(ownerID: ownerID, kind: kind, text: clean, origin: source == .user ? .explicit : .learned, status: .active,
                              sourceReference: sourceReference, createdAt: now, updatedAt: now, expiresAt: expiry(base),
                              source: source, confidence: base, evidenceCount: 1, lastSeenAt: now)
        doc.items.append(item); try save(doc); return .added(item)
    }
    /// Forgets one item by id (agent tools and the reflection pass). Tombstoned so it is never re-learned.
    @discardableResult
    func forget(id: UUID, now: Date = .now) throws -> MemoryItem {
        guard let item = items.first(where: { $0.id == id }) else { throw CalendarToolArgumentError("That memory isn’t saved. Use an id from recall.") }
        var doc = document; doc.items.removeAll { $0.id == id }
        doc.tombstones.append(.init(normalizedTextHash: Self.hash(item.text), forgottenAt: now))
        try save(doc); return item
    }
    /// Records one spoken reply and whether the user cut it off. Derives the short-reply style once the pattern holds.
    @discardableResult
    func recordVoiceReply(interrupted: Bool, now: Date = .now) throws -> Bool {
        var doc = document
        var signals = doc.signals ?? BehaviorSignals()
        signals.voiceReplies = Array((signals.voiceReplies + [now]).suffix(BehaviorSignals.limit))
        if interrupted { signals.voiceInterruptions = Array((signals.voiceInterruptions + [now]).suffix(BehaviorSignals.limit)) }
        doc.signals = signals
        try save(doc)
        guard interrupted, signals.prefersShortSpokenReplies(now: now) else { return false }
        if case .added = try learn(kind: .style, text: Self.shortRepliesText, source: .behavior, confidence: 0.8, now: now) { return true }
        return false
    }
    func change(id: UUID, expectedVersion: UUID, kind: MemoryItem.Kind? = nil, text: String? = nil, approve: Bool = false) throws {
        var doc = document
        guard let index = doc.items.firstIndex(where: { $0.id == id && $0.version == expectedVersion }) else { throw CalendarToolArgumentError("This memory changed. Use the latest version and try again.") }
        if let kind { doc.items[index].kind = kind }
        if let text {
            doc.items[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // The user edited it, so it is now their own statement.
            if doc.items[index].source != nil { doc.items[index].source = .user; doc.items[index].confidence = 1; doc.items[index].expiresAt = nil }
        }
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
    // MARK: Account sync (server-readable copy in Supabase; this file stays the fast, authoritative local copy)

    func outgoingChanges() -> OutgoingChanges {
        let sync = document.sync ?? SyncState()
        // Knowledge inferred from the screen stays on this device.
        return OutgoingChanges(items: items.filter { sync.known[$0.id] != $0.version && $0.source != .screen },
                               deletes: sync.pendingDeletes.map { ($0.key, $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString },
                               tombstones: document.tombstones.filter { !sync.sentTombstones.contains($0.normalizedTextHash) })
    }
    /// Records what reached the account copy. Items changed again since `sent` was taken stay outgoing.
    func markSent(_ sent: OutgoingChanges) throws {
        var doc = document, sync = doc.sync ?? SyncState()
        for item in sent.items where doc.items.contains(where: { $0.id == item.id && $0.version == item.version }) { sync.known[item.id] = item.version }
        for delete in sent.deletes where sync.pendingDeletes[delete.id] == delete.at { sync.pendingDeletes[delete.id] = nil }
        sync.sentTombstones.formUnion(sent.tombstones.map(\.normalizedTextHash))
        doc.sync = sync; try save(doc, recordDeletes: false)
    }
    /// Merges changes from other devices. Newer wins per item; forgotten text is removed everywhere; when two
    /// devices learned the same thing separately, both keep the copy with the smaller id. Local changes not yet
    /// sent win over older remote copies.
    @discardableResult
    func applyRemote(items remote: [RemoteItem], tombstones: [Tombstone], cursor: Date) throws -> Int {
        var doc = document, sync = doc.sync ?? SyncState(), changed = 0
        for tombstone in tombstones where !doc.tombstones.contains(where: { $0.normalizedTextHash == tombstone.normalizedTextHash }) {
            doc.tombstones.append(tombstone); sync.sentTombstones.insert(tombstone.normalizedTextHash)
            let before = doc.items.count
            doc.items.removeAll { Self.hash($0.text) == tombstone.normalizedTextHash }
            changed += before - doc.items.count
        }
        for row in remote {
            let local = doc.items.firstIndex { $0.id == row.id }
            let unsent = local.map { sync.known[row.id] != doc.items[$0].version } ?? false
            if row.deleted {
                if let local, !(unsent && doc.items[local].updatedAt > row.updatedAt) { doc.items.remove(at: local); changed += 1 }
                sync.known[row.id] = nil; sync.pendingDeletes[row.id] = nil
                continue
            }
            guard var item = row.item, item.id == row.id, item.ownerID == nil || item.ownerID == ownerID else { continue }
            item.ownerID = ownerID
            if doc.tombstones.contains(where: { $0.normalizedTextHash == Self.hash(item.text) }) || sync.pendingDeletes[row.id] != nil { continue }
            if let local {
                guard doc.items[local].version != item.version, !(unsent && doc.items[local].updatedAt >= item.updatedAt) else {
                    if !unsent { sync.known[row.id] = doc.items[local].version }
                    continue
                }
            }
            if let twin = doc.items.firstIndex(where: { $0.id != item.id && Self.normalize($0.text) == Self.normalize(item.text) }) {
                // The same knowledge learned on two devices: keep one copy, the same one on both.
                if doc.items[twin].id.uuidString < item.id.uuidString {
                    if let local { doc.items.remove(at: local) }
                    sync.known[row.id] = nil; sync.pendingDeletes[row.id] = Date(); continue
                }
                sync.pendingDeletes[doc.items[twin].id] = Date(); sync.known[doc.items[twin].id] = nil
                doc.items.remove(at: twin)
            }
            if let index = doc.items.firstIndex(where: { $0.id == item.id }) { doc.items[index] = item }
            else { guard doc.items.count < 500 else { continue }; doc.items.append(item) }
            sync.known[row.id] = item.version; changed += 1
        }
        sync.cursor = cursor; doc.sync = sync
        try save(doc, recordDeletes: false)
        return changed
    }
    /// Starts sync over (after the account copy was removed): everything here is sent again.
    func resetSync() throws { var doc = document; doc.sync = nil; try save(doc, recordDeletes: false) }

    func clear(confirmed: Bool) throws {
        guard confirmed else { throw CalendarToolArgumentError("Confirm forgetting all personal memories first.") }
        var doc = document
        doc.tombstones += doc.items.map { .init(normalizedTextHash: Self.hash($0.text), forgottenAt: .now) }
        doc.items = []; doc.signals = nil; doc.notes = nil; try save(doc)
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
    /// Knowledge plus the learned calendar profile. Per-turn additions (`relevantOnly`) carry knowledge only.
    /// The standing picture (not `relevantOnly`) also says who the user is and what earlier conversations were about.
    func personalMemoryContext(for request: String, relevantOnly: Bool = false, characterBudget: Int = 6_000) -> String {
        let knowledge = MemoryContextBuilder.build(request: request, items: personalMemory.items, characterBudget: relevantOnly ? 2_000 : characterBudget, relevantOnly: relevantOnly)
        guard !relevantOnly else { return knowledge }
        return [userIdentityContext, knowledge, calendarProfileContext ?? "", MemoryContextBuilder.notes(personalMemory.notes)].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    /// The account's display name, else the name of this Mac's user account.
    var userIdentityContext: String {
        let fromAccount = !accountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return MemoryContextBuilder.identity(name: fromAccount ? accountDisplayName : NSFullUserName(), nameIsFromAccount: fromAccount, email: account.email)
    }
    @discardableResult
    func suggestPersonalMemory(kind: MemoryItem.Kind, text: String, sourceReference: String? = nil) throws -> MemoryItem {
        try personalMemory.suggest(kind: kind, text: text, sourceReference: sourceReference)
    }
    /// Something the user said about themselves: saved at once, visible and forgettable in Settings.
    @discardableResult
    func learnPersonalMemory(kind: MemoryItem.Kind, text: String, source: MemoryItem.Source, confidence: Double? = nil, replacing: UUID? = nil) throws -> PersonalMemoryStore.LearnOutcome {
        let outcome = try personalMemory.learn(kind: kind, text: text, source: source, confidence: confidence, replacing: replacing, sourceReference: currentMemoryRecordID?.uuidString)
        objectWillChange.send(); return outcome
    }
    /// A spoken reply ended; `interrupted` when the user talked over it. Failures never interrupt voice.
    func recordVoiceReply(interrupted: Bool) -> Bool {
        guard personalMemory.error == nil, agentToolExecutor?.memorySuggestionsBlocked != true else { return false }
        let learned = (try? personalMemory.recordVoiceReply(interrupted: interrupted)) ?? false
        if learned { objectWillChange.send() }
        return learned
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
        case "forgetNote": allowed.insert("noteID")
        default: throw CalendarToolArgumentError("Unknown memory action.")
        }
        guard Set(body.keys).isSubset(of: allowed), body["token"] as? String == store.token else { throw CalendarToolArgumentError("Memory changed. Check the latest memories and try again.") }
        func boolean(_ key: String) throws -> Bool {
            guard let value = body[key], CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool else { throw CalendarToolArgumentError("\(key) must be a boolean.") }
            return flag
        }
        if action == "clearMemory" { try store.clear(confirmed: boolean("confirmed")); return }
        if action == "forgetNote" {
            guard let id = (body["noteID"] as? String).flatMap(UUID.init(uuidString:)) else { throw CalendarToolArgumentError("Choose a current conversation note.") }
            try store.removeNote(id: id); return
        }
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

