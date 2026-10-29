import AppKit
import CryptoKit
import Foundation

/// Personal account data only. Credentials and screenshot files are never Codable here.
struct AccountSyncConnection: Codable, Equatable {
    var key: String
    var provider: String
    var label: String
}
struct AccountSyncDevice: Codable {
    var name: String
    var connections: [AccountSyncConnection]
    var updatedAt: Date
}
struct AccountSyncDocument: Codable {
    var preferences: [String: JSONValue] = [:]
    var devices: [String: AccountSyncDevice] = [:]
    var history: [String: MemoryCaptureRecord] = [:]
    var deleted: [UUID] = []
}
struct AccountSyncResponse: Decodable {
    var revision: Int
    var payload: AccountSyncDocument
    var displayName: String
}
struct AccountSyncBaseline: Codable {
    var hashes: [String: String] = [:]
    var preferences: [String: JSONValue] = [:]
}

extension MemoryCaptureRecord {
    /// Conversation text and action receipts travel; screen images and replayable
    /// tool calls stay local. Unfinished writes from another device need review.
    func accountSyncCopy() -> MemoryCaptureRecord {
        var copy = self
        copy = MemoryCaptureRecord(id: id, createdAt: createdAt, screenshotFileName: "", imageFormat: imageFormat,
            event: event, recognizedText: recognizedText, analysisProvider: analysisProvider,
            savedToCalendarAt: savedToCalendarAt, savedCalendarName: savedCalendarName,
            calendarEventIdentifier: calendarEventIdentifier, schemaVersion: schemaVersion,
            proposals: calendarProposals.map { item in
                var item = item; item.isSelected = false
                if item.state == .saving {
                    item.state = .failed; item.error = "Interrupted on another device. Check the source calendar before retrying."
                    item.attemptedDestinationID = nil; item.attemptedCalendarName = nil
                }
                return item
            }, agentTranscript: (agentTranscript ?? []).filter { $0.toolName == nil && ["user", "assistant"].contains($0.role) }.map { turn in
                var value = AgentTurn(role: turn.role, content: turn.content); value.sharedCalendarContext = turn.sharedCalendarContext; return value
            })
        return copy
    }
    func syncHash() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; encoder.dateEncodingStrategy = .iso8601
        return SHA256.hash(data: try encoder.encode(accountSyncCopy())).map { String(format: "%02x", $0) }.joined()
    }
}

enum AccountSyncMerge {
    /// Merge against the last successful baseline. Concurrent history edits keep
    /// both versions; a tombstone cannot silently resurrect an old local record.
    static func merge(remote: AccountSyncDocument, local: [MemoryCaptureRecord], baseline: AccountSyncBaseline) throws -> AccountSyncDocument {
        var result = remote
        let localIDs = Set(local.map { $0.id.uuidString })
        var deleted = Set(remote.deleted)
        for key in baseline.hashes.keys where !localIDs.contains(key) {
            if let cloud = remote.history[key], try cloud.syncHash() != baseline.hashes[key] { continue }
            if let id = UUID(uuidString: key) { deleted.insert(id); result.history.removeValue(forKey: key) }
        }
        for record in local {
            let key = record.id.uuidString, hash = try record.syncHash()
            let previous = baseline.hashes[key]
            let changed = hash != previous
            if deleted.contains(record.id) {
                if changed && previous != nil { let fork = try fork(record); result.history[fork.id.uuidString] = fork }
                result.history.removeValue(forKey: key); continue
            }
            if let cloud = remote.history[key] {
                let cloudHash = try cloud.syncHash()
                if changed && cloudHash != hash {
                    if previous == nil || cloudHash != previous {
                        let fork = try fork(record); result.history[fork.id.uuidString] = fork
                    } else { result.history[key] = record.accountSyncCopy() }
                }
            } else { result.history[key] = record.accountSyncCopy() }
        }
        result.deleted = deleted.sorted { $0.uuidString < $1.uuidString }
        guard result.history.count <= 1000 else { throw CalendarToolArgumentError("Account sync supports up to 1,000 tasks. Your local history is kept.") }
        return result
    }
    private static func fork(_ record: MemoryCaptureRecord) throws -> MemoryCaptureRecord {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(record.accountSyncCopy())) as! [String: Any]
        object["id"] = UUID().uuidString
        object["analysisProvider"] = "Recovered concurrent edit"
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MemoryCaptureRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@MainActor
extension CalshotModel {
    func scheduleAccountSync() {
        guard account.enabled, account.userID != nil else { return }
        accountSyncTask?.cancel()
        accountSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncAccount()
        }
    }
    func startAccountSync() {
        accountSyncTimer?.invalidate()
        accountSyncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncAccount(); await self?.syncTasks(); await self?.syncMacCalendars(); await self?.syncSharedCalendars() }
        }
        scheduleAccountSync()
        Task { [weak self] in await self?.syncTasks(); await self?.refreshSharing() }
    }
    func syncAccount() async {
        guard !softwareUpdates.installing else { return }
        guard let user = account.userID, activeLocalAccountID == user, !accountSyncBusy else { return }
        guard !agentIsRunning, !isSaving, !isCapturing, !isRecognizing, !calendarAccountIsConnecting else {
            accountSyncStatus = "Sync will continue when the current task finishes."; return
        }
        let store = memoryStore
        accountSyncBusy = true; accountSyncError = nil
        defer { accountSyncBusy = false }
        do {
            let response: AccountSyncResponse = try await account.syncRPC("read_account_state", body: .object([:]), user: user)
            guard account.userID == user, memoryStore === store, !agentIsRunning, !isSaving, !isCapturing, !isRecognizing else { return }
            let baselineKey = "calshot.sync.baseline." + user.uuidString
            let baseline = UserDefaults.standard.data(forKey: baselineKey).flatMap { try? JSONDecoder().decode(AccountSyncBaseline.self, from: $0) } ?? AccountSyncBaseline()
            let localRecords = store.listRecords()
            let localHashes = try Dictionary(uniqueKeysWithValues: localRecords.map { ($0.id.uuidString, try $0.syncHash()) })
            var document = try AccountSyncMerge.merge(remote: response.payload, local: localRecords, baseline: baseline)
            let localPreferences: [String: JSONValue] = ["appearance": .string(appearanceMode.rawValue), "sidebarExpanded": .bool(sidebarExpanded)]
            for (key, value) in localPreferences {
                if document.preferences[key] == nil || (baseline.preferences[key] != nil && value != baseline.preferences[key]) { document.preferences[key] = value }
            }
            var connections = directCalendarAccounts.map { AccountSyncConnection(key: Self.connectionKey($0.provider.rawValue + ":" + $0.subject), provider: $0.provider.rawValue, label: $0.email) }
            for calendar in readableCalendars where calendar.provider == .apple && !connections.contains(where: { $0.key == Self.connectionKey("apple:" + (calendar.sourceName ?? "Apple Calendar")) }) {
                connections.append(.init(key: Self.connectionKey("apple:" + (calendar.sourceName ?? "Apple Calendar")), provider: "apple", label: calendar.sourceName ?? "Apple Calendar"))
            }
            if let chatGPTAccount { connections.append(.init(key: Self.connectionKey("chatgpt:" + chatGPTAccount.subject), provider: "chatgpt", label: chatGPTAccount.email)) }
            let deviceID = Self.syncDeviceID
            let name = String((Host.current().localizedName ?? "Mac").prefix(100))
            let oldDevice = document.devices[deviceID]
            if oldDevice?.connections != connections || oldDevice?.name != name {
                document.devices[deviceID] = AccountSyncDevice(name: name, connections: connections, updatedAt: .now)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; encoder.dateEncodingStrategy = .iso8601
            if try encoder.encode(document) != encoder.encode(response.payload) {
                let payload = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(document))
                let _: Int = try await account.syncRPC("write_account_state", body: .object(["document": payload, "expected_revision": .number(Double(response.revision))]), user: user)
            }
            guard account.userID == user, memoryStore === store, !agentIsRunning, !isSaving, !isCapturing, !isRecognizing else { return }
            let latestHashes = try Dictionary(uniqueKeysWithValues: store.listRecords().map { ($0.id.uuidString, try $0.syncHash()) })
            guard latestHashes == localHashes, appearanceMode.rawValue == localPreferences["appearance"]?.stringValue,
                  sidebarExpanded == localPreferences["sidebarExpanded"]?.boolValue else {
                throw CalendarToolArgumentError("Local data changed during sync. Your changes are kept; sync again to finish.")
            }
            try store.applyAccountSync(document)
            memoryRecords = store.listRecords()
            if let mode = document.preferences["appearance"]?.stringValue.flatMap(AppAppearance.init(rawValue:)) { appearanceMode = mode }
            if let expanded = document.preferences["sidebarExpanded"]?.boolValue { sidebarExpanded = expanded }
            let next = AccountSyncBaseline(hashes: try document.history.mapValues { try $0.syncHash() }, preferences: document.preferences)
            UserDefaults.standard.set(try JSONEncoder().encode(next), forKey: baselineKey)
            accountSyncDevices = document.devices; accountDisplayName = response.displayName
            accountSyncLastDate = .now; accountSyncStatus = "Up to date · Screenshots stay on this Mac"
        } catch is CancellationError { }
        catch { guard account.userID == user else { return }; accountSyncError = error.localizedDescription; accountSyncStatus = "Not synced · Local changes are kept" }
    }
    static var syncDeviceID: String {
        if let value = UserDefaults.standard.string(forKey: "calshot.sync.deviceID") { return value }
        let value = UUID().uuidString; UserDefaults.standard.set(value, forKey: "calshot.sync.deviceID"); return value
    }
    private static func connectionKey(_ identity: String) -> String { SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() }
}

/// A server-authoritative opt-in. Credentials and provider identifiers never leave the Mac.
struct MacCalendarMirror: Codable, Identifiable {
    var id: UUID
    var sourceKey: String
    var generation: UUID
    var enabled: Bool
    var name: String
    var syncedAt: String?
    var complete: Bool
    var error: String?
}

enum MacCalendarSnapshot {
    static func key(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func events(service: any CalendarDestinationService, calendarID: String, start: Date, end: Date, depth: Int = 0) async throws -> [CalendarEventSnapshot] {
        try Task.checkCancellation()
        let rows = try await service.searchEvents(query: nil, start: start, end: end, in: .resolve(identifier: calendarID))
        guard rows.count >= 40 else { return rows }
        guard depth < 11, end.timeIntervalSince(start) > 3600 else { throw CalendarToolArgumentError("This calendar is too busy to sync completely. The previous web copy is kept.") }
        let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        let left = try await events(service: service, calendarID: calendarID, start: start, end: middle, depth: depth + 1)
        let right = try await events(service: service, calendarID: calendarID, start: middle, end: end, depth: depth + 1)
        let combined = unique(left + right)
        guard combined.count <= 1000 else { throw CalendarToolArgumentError("This calendar has more than 1,000 events in the sync range. The previous web copy is kept.") }
        return combined
    }
    static func unique(_ rows: [CalendarEventSnapshot]) -> [CalendarEventSnapshot] {
        var seen = Set<String>()
        return rows.filter { seen.insert(key($0.eventIdentifier + "|" + String($0.start.timeIntervalSince1970))).inserted }
    }
    static func payload(_ rows: [CalendarEventSnapshot], start: Date, end: Date) -> JSONValue {
        let iso = ISO8601DateFormatter()
        return .array(unique(rows).filter { $0.start < end && $0.end > start }.map { row in
            let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.calendar = Calendar(identifier: .gregorian)
            day.timeZone = row.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current; day.dateFormat = "yyyy-MM-dd"
            var fields: [String: JSONValue] = ["id": .string(key(row.eventIdentifier + "|" + String(row.start.timeIntervalSince1970))), "title": .string(String((row.title.isEmpty ? "Untitled event" : row.title).prefix(500))), "start": .string(iso.string(from: row.start)), "end": .string(iso.string(from: row.end)), "allDay": .bool(row.isAllDay)]
            if row.isAllDay {
                // EventKit can return 23:59:59 on the final included day.
                // Web/calendar dates use an exclusive end at the next midnight.
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = day.timeZone
                let firstDay = calendar.startOfDay(for: row.start)
                let finalBoundary = calendar.startOfDay(for: row.end)
                let exclusiveEnd = row.end > finalBoundary ? calendar.date(byAdding: .day, value: 1, to: finalBoundary)! : finalBoundary
                fields["start"] = .string(iso.string(from: firstDay)); fields["end"] = .string(iso.string(from: exclusiveEnd))
                fields["date"] = .string(day.string(from: firstDay)); fields["endDate"] = .string(day.string(from: exclusiveEnd))
            }
            if let zone = row.timeZone { fields["timeZone"] = .string(zone) }
            if let location = row.location { fields["location"] = .string(String(location.prefix(1000))) }
            return .object(fields)
        })
    }
}

@MainActor
extension CalshotModel {
    func macCalendarCall(_ name: String, _ body: JSONValue, user: UUID) async throws -> JSONValue {
        guard account.userID == user else { throw CancellationError() }
        let value: JSONValue
        if let macCalendarRPC { value = try await macCalendarRPC(name, body, user) }
        else { value = try await account.syncRPC(name, body: body, user: user) }
        guard account.userID == user else { throw CancellationError() }
        return value
    }
    func refreshMacCalendarChoices(user: UUID) async throws {
        let result = try await macCalendarCall("read_mac_calendar_sync", .object(["device": .string(Self.syncDeviceID)]), user: user)
        let rows = try JSONDecoder().decode([MacCalendarMirror].self, from: JSONEncoder().encode(result))
        guard account.userID == user else { return }
        macCalendarMirrors = rows
    }
    func stopMacCalendarSync(mirrorID: UUID) async throws {
        guard account.canUseWorkspace, let user = account.userID, !macCalendarSyncBusy,
              macCalendarMirrors.contains(where: { $0.id == mirrorID }) else { throw CalendarToolArgumentError("Refresh your calendar sync choices and try again.") }
        macCalendarSyncBusy = true; macCalendarSyncError = nil
        defer { macCalendarSyncBusy = false }
        _ = try await macCalendarCall("disable_mac_calendar_sync", .object(["mirror": .string(mirrorID.uuidString)]), user: user)
        try await refreshMacCalendarChoices(user: user)
    }
    func setMacCalendarSync(calendarID: String, enabled: Bool) async throws {
        guard account.canUseWorkspace, let user = account.userID, !macCalendarSyncBusy,
              let calendar = readableCalendars.first(where: { $0.id == calendarID && !$0.id.hasPrefix("unavailable:") }) else { throw CalendarToolArgumentError("Sign in and choose an available calendar. Wait for any current sync to finish.") }
        macCalendarSyncBusy = true; macCalendarSyncError = nil
        do {
            let result = try await macCalendarCall("set_mac_calendar_sync", .object([
                "device": .string(Self.syncDeviceID), "source": .string(MacCalendarSnapshot.key(calendarID)),
                "title": .string(String(calendar.title.prefix(500))), "source_title": .string(String((calendar.sourceName ?? "Mac Calendar").prefix(500))),
                "device_title": .string(String((Host.current().localizedName ?? "Mac").prefix(100))), "zone": calendar.timeZone.map(JSONValue.string) ?? .null, "enabled": .bool(enabled)]), user: user)
            let mirror = try JSONDecoder().decode(MacCalendarMirror.self, from: JSONEncoder().encode(result))
            macCalendarMirrors.removeAll { $0.sourceKey == mirror.sourceKey }; macCalendarMirrors.append(mirror)
            macCalendarSyncBusy = false
            if enabled { await syncMacCalendars(force: true) }
        } catch {
            macCalendarSyncBusy = false
            guard account.userID == user else { return }
            macCalendarSyncError = "Couldn’t save your web sync choice. Check your connection and try again."
            throw CalendarToolArgumentError(macCalendarSyncError!)
        }
    }
    func syncMacCalendars(force: Bool = false) async {
        guard !softwareUpdates.installing else { return }
        guard account.canUseWorkspace, let user = account.userID, !macCalendarSyncBusy,
              !agentIsRunning, !isSaving, !isCapturing, !isRecognizing else { return }
        macCalendarSyncBusy = true; macCalendarSyncError = nil
        defer { macCalendarSyncBusy = false }
        do {
            try await refreshMacCalendarChoices(user: user)
            let iso = ISO8601DateFormatter(); iso.formatOptions.insert(.withFractionalSeconds)
            let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-7 * 86400), end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(55 * 86400)
            var failedUploads: [UUID: (UUID, String)] = [:]
            for mirror in macCalendarMirrors where mirror.enabled {
                guard account.userID == user, !agentIsRunning, !isSaving, !isCapturing, !isRecognizing else { return }
                let synced = mirror.syncedAt.flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                if !force, mirror.error == nil, let synced, Date().timeIntervalSince(synced) < 60 { continue }
                var body: [String: JSONValue] = ["mirror": .string(mirror.id.uuidString), "version": .string(mirror.generation.uuidString), "starts": .string(ISO8601DateFormatter().string(from: start)), "ends": .string(ISO8601DateFormatter().string(from: end)), "items": .array([])]
                do {
                    guard let calendar = readableCalendars.first(where: { MacCalendarSnapshot.key($0.id) == mirror.sourceKey && !$0.id.hasPrefix("unavailable:") }) else { throw CalendarToolArgumentError("This calendar is unavailable on the Mac. Check Calendar access, or stop syncing it.") }
                    let rows = try await MacCalendarSnapshot.events(service: calendarService, calendarID: calendar.id, start: start, end: end)
                    guard account.userID == user, !agentIsRunning, !isSaving, !isCapturing, !isRecognizing else { return }
                    body["items"] = MacCalendarSnapshot.payload(rows, start: start, end: end)
                    guard try JSONEncoder().encode(body["items"]!).count <= 900_000 else { throw CalendarToolArgumentError("This calendar is too large to sync completely. The previous web copy is kept.") }
                } catch is CancellationError { return }
                catch { body["failure"] = .string(error.localizedDescription); body["items"] = .array([]) }
                do {
                    _ = try await macCalendarCall("write_mac_calendar_snapshot", .object(body), user: user)
                } catch is CancellationError { return }
                catch {
                    let message = error.localizedDescription
                    failedUploads[mirror.id] = (mirror.generation, message)
                    body["failure"] = .string(message); body["items"] = .array([])
                    // Persist the failure beside this calendar, then continue the batch.
                    do { _ = try await macCalendarCall("write_mac_calendar_snapshot", .object(body), user: user) }
                    catch is CancellationError { return }
                    catch { /* The local row still shows the failure if the network is down. */ }
                }
            }
            try await refreshMacCalendarChoices(user: user)
            for index in macCalendarMirrors.indices {
                let row = macCalendarMirrors[index]
                if row.enabled, let (version, message) = failedUploads[row.id], row.generation == version { macCalendarMirrors[index].error = message; macCalendarMirrors[index].complete = false }
            }
        } catch is CancellationError { }
        catch { guard account.userID == user else { return }; macCalendarSyncError = error.localizedDescription }
    }
}
