import Foundation

/// The server migration for knowledge sync has not been applied to this Supabase project yet.
struct KnowledgeSyncUnavailable: Error {}

/// Syncs what Calshot knows with the user's account so every Mac shares it. The local file is read on every
/// request (no network on the hot path); this runs in the background with account sync. Server-readable and
/// owner-only. Behavior counters and the calendar profile are never uploaded. Shared-friend content never enters
/// knowledge, so it never reaches the server either.
@MainActor
extension CalshotModel {
    private var knowledgeSyncKey: String { "calshot.knowledgeSync." + (account.userID?.uuidString ?? "local") }
    var knowledgeSyncEnabled: Bool {
        get { account.userID != nil && (UserDefaults.standard.object(forKey: knowledgeSyncKey) as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: knowledgeSyncKey); objectWillChange.send() }
    }
    var knowledgeSyncSnapshot: JSONValue {
        .object(["available": .bool(account.enabled && account.userID != nil), "enabled": .bool(knowledgeSyncEnabled), "busy": .bool(knowledgeSyncBusy),
                 "status": .string(knowledgeSyncStatus), "error": knowledgeSyncError.map(JSONValue.string) ?? .null, "serverReady": .bool(!knowledgeSyncUnavailable)])
    }

    static func syncDate(_ value: JSONValue?) -> Date? {
        guard let text = value?.stringValue else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        // Postgres sends microseconds; keep milliseconds.
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let digits = text[text.index(after: dot)..<zone].prefix(3)
            if let date = formatter.date(from: String(text[..<dot]) + "." + digits + String(text[zone...])) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
    }

    func syncPersonalKnowledge() async {
        guard knowledgeSyncEnabled, account.enabled, let user = account.userID, activeLocalAccountID == user, !knowledgeSyncBusy else { return }
        let store = personalMemory
        guard store.error == nil, store.ownerID == user else { return }
        knowledgeSyncBusy = true; knowledgeSyncError = nil
        defer { knowledgeSyncBusy = false }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        do {
            // Read first (overlapping the last read by two minutes, so a late-committing write is never skipped) so other devices' forgets and corrections land before anything is sent.
            let since: JSONValue = store.document.sync?.cursor.map { .string(iso.string(from: $0.addingTimeInterval(-120))) } ?? .null
            let response: JSONValue = try await account.syncRPC("read_personal_knowledge", body: .object(["since": since]), user: user)
            guard account.userID == user, store === personalMemory, let fields = response.objectValue, let cursor = Self.syncDate(fields["serverTime"]) else { return }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let items: [PersonalMemoryStore.RemoteItem] = (fields["items"]?.arrayValue ?? []).compactMap { row in
                guard let values = row.objectValue, let id = values["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                      let deleted = values["deleted"]?.boolValue, let updated = Self.syncDate(values["updatedAt"]) else { return nil }
                let item = values["item"].flatMap { $0 == .null ? nil : try? decoder.decode(MemoryItem.self, from: JSONEncoder().encode($0)) }
                return .init(id: id, item: item, deleted: deleted, updatedAt: updated)
            }
            let tombstones: [PersonalMemoryStore.Tombstone] = (fields["tombstones"]?.arrayValue ?? []).compactMap { row in
                guard let hash = row.objectValue?["hash"]?.stringValue, let at = Self.syncDate(row.objectValue?["forgottenAt"]) else { return nil }
                return .init(normalizedTextHash: hash, forgottenAt: at)
            }
            if try store.applyRemote(items: items, tombstones: tombstones, cursor: cursor) > 0 { objectWillChange.send() }
            // Then send what changed here, in bounded batches.
            let outgoing = store.outgoingChanges()
            if !outgoing.isEmpty {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                var rows: [JSONValue] = try outgoing.items.map { item in
                    .object(["id": .string(item.id.uuidString), "item": try JSONDecoder().decode(JSONValue.self, from: encoder.encode(item)),
                             "deleted": .bool(false), "updatedAt": .string(iso.string(from: item.updatedAt))])
                }
                rows += outgoing.deletes.map { .object(["id": .string($0.id.uuidString), "item": .null, "deleted": .bool(true), "updatedAt": .string(iso.string(from: $0.at))]) }
                let marks: [JSONValue] = outgoing.tombstones.map { .object(["hash": .string($0.normalizedTextHash), "forgottenAt": .string(iso.string(from: $0.forgottenAt))]) }
                var start = 0
                repeat {
                    let end = min(rows.count, start + 500)
                    let batch: [String: JSONValue] = ["items": .array(Array(rows[start..<end])), "tombstones": .array(start == 0 ? marks : [])]
                    let _: JSONValue = try await account.syncRPC("write_personal_knowledge", body: .object(["changes": .object(batch)]), user: user)
                    start = end
                } while start < rows.count
                guard account.userID == user, store === personalMemory else { return }
                try store.markSent(outgoing)
            }
            knowledgeSyncUnavailable = false
            knowledgeSyncStatus = "Synced with your account"
        } catch is CancellationError {
        } catch is KnowledgeSyncUnavailable {
            knowledgeSyncUnavailable = true
            knowledgeSyncStatus = "Account sync for memory isn’t set up on the server yet. Everything stays on this Mac."
        } catch {
            knowledgeSyncError = error.localizedDescription
        }
    }

    /// Settings: turn syncing on or off for this account on this Mac. Turning it off keeps the account copy.
    func setKnowledgeSync(enabled: Bool) async {
        knowledgeSyncEnabled = enabled
        knowledgeSyncStatus = enabled ? "" : "Not syncing. What Calshot knows stays on this Mac."
        knowledgeSyncError = nil
        if enabled { await syncPersonalKnowledge() }
    }

    /// Settings: removes the account copy (every Mac keeps its local copy) and turns syncing off here.
    func removeSyncedKnowledge() async throws {
        guard let user = account.userID else { throw CalendarToolArgumentError("Sign in to manage the synced copy.") }
        guard !knowledgeSyncBusy else { throw CalendarToolArgumentError("Sync is running. Try again in a moment.") }
        knowledgeSyncBusy = true; defer { knowledgeSyncBusy = false }
        do {
            let _: JSONValue? = try await account.syncRPC("clear_personal_knowledge", body: .object([:]), user: user)
        } catch is KnowledgeSyncUnavailable {
            knowledgeSyncUnavailable = true
        }
        try personalMemory.resetSync()
        knowledgeSyncEnabled = false
        knowledgeSyncStatus = "Removed from your account. What Calshot knows stays on this Mac."
    }
}
