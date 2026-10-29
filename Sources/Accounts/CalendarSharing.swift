import AppKit
import CryptoKit
import Foundation
#if DEBUG
import Auth
#endif

struct SharedCalendarSource: Codable, Identifiable {
    var id: UUID
    var sourceKey: String
    var name: String
    var revision: Int
    var withdrawn: Bool
    var syncedAt: String
    var coverageStart: String
    var coverageEnd: String
    var error: String?
}
struct FriendCalendar: Codable, Identifiable {
    var id: UUID
    var name: String
    var syncedAt: String
    var stale: Bool
    var error: String?
}
struct CalendarShare: Codable, Identifiable {
    var id: UUID
    var ownerID: UUID
    var recipientID: UUID?
    var outgoing: Bool
    var personName: String
    var email: String?
    var permission: String
    var status: String
    var expiresAt: String
    var calendars: [FriendCalendar]
}
struct CalendarSharingState: Codable {
    var sources: [SharedCalendarSource] = []
    var shares: [CalendarShare] = []
    var token: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
extension CalshotModel {
    func sharingCall(_ name: String, _ body: JSONValue = .object([:]), user: UUID) async throws -> JSONValue {
        guard account.userID == user else { throw CancellationError() }
        let response: JSONValue
        if let sharingRPC { response = try await sharingRPC(name, body, user) }
        else { response = try await account.syncRPC(name, body: body, user: user) }
        guard account.userID == user, !Task.isCancelled else { throw CancellationError() }
        return response
    }
    func readSharing(user: UUID) async throws {
        let response = try await sharingCall("read_calendar_sharing", user: user)
        let state = try JSONDecoder().decode(CalendarSharingState.self, from: JSONEncoder().encode(response))
        guard account.userID == user else { throw CancellationError() }
        calendarSharing = state; sharingLoaded = true; sharingError = nil
    }
    func refreshSharing() async {
        guard !softwareUpdates.installing else { return }
        guard let user = account.userID, !sharingBusy else { return }
        sharingBusy = true
        defer { if account.userID == user { sharingBusy = false } }
        do { try await readSharing(user: user) }
        catch is CancellationError { }
        catch { guard account.userID == user else { return }; sharingError = "Sharing couldn’t refresh. Check your connection and try again. Friend calendars haven’t been verified." }
    }
    func requireSharing(_ token: String?) throws -> UUID {
        guard account.canUseWorkspace, let user = account.userID, sharingLoaded, !sharingBusy, token == calendarSharing.token else {
            throw CalendarToolArgumentError("Sharing changed. Refresh Friends & sharing and try again.")
        }
        return user
    }
    func sharingSourceKey(_ calendarID: String) -> String { Self.syncDeviceID + ":" + MacCalendarSnapshot.key(calendarID) }
    func publishSharingCalendar(_ calendarID: String, permission: String, user: UUID, allowNew: Bool) async throws -> UUID {
        guard let calendar = readableCalendars.first(where: { $0.id == calendarID && !$0.id.hasPrefix("unavailable:") }) else { throw CalendarToolArgumentError("This calendar is unavailable on this Mac. Check Calendar accounts.") }
        let source = calendarSharing.sources.first { $0.sourceKey == sharingSourceKey(calendarID) }
        guard allowNew || source?.withdrawn == false else { throw CancellationError() }
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(-7 * 86400)
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(55 * 86400)
        let rows = try await MacCalendarSnapshot.events(service: calendarService, calendarID: calendarID, start: start, end: end)
        guard account.userID == user, !agentIsRunning, !isSaving, !isCapturing, !isRecognizing else { throw CalendarToolArgumentError("Sync paused while a task is active. Try again when it finishes.") }
        guard rows.count <= 500 else { throw CalendarToolArgumentError("This calendar exceeds the 500-event sharing limit. Its previous copy is kept.") }
        let existingPermissions = calendarSharing.shares.filter { $0.outgoing && ["pending", "accepted"].contains($0.status) && $0.calendars.contains(where: { $0.id == source?.id }) }.map(\.permission)
        let rank = ["busy": 0, "titles": 1, "details": 2]
        let level = (existingPermissions + [permission]).max { (rank[$0] ?? 0) < (rank[$1] ?? 0) } ?? permission
        let raw = Dictionary(rows.map { (MacCalendarSnapshot.key($0.eventIdentifier + "|" + String($0.start.timeIntervalSince1970)), $0) }, uniquingKeysWith: { first, _ in first })
        let items = (MacCalendarSnapshot.payload(rows, start: start, end: end).arrayValue ?? []).map { item -> JSONValue in
            var fields = item.objectValue ?? [:]
            let id = fields.removeValue(forKey: "id")?.stringValue ?? ""
            fields["key"] = .string(id)
            fields.removeValue(forKey: "date"); fields.removeValue(forKey: "endDate")
            if level == "busy" { fields["title"] = .string("Busy") }
            if level == "details" {
                if let location = raw[id]?.location { fields["location"] = .string(String(location.prefix(500))) }
                if let notes = raw[id]?.notes { fields["notes"] = .string(String(notes.prefix(4000))) }
                if let url = raw[id]?.url { fields["url"] = .string(String(url.absoluteString.prefix(2000))) }
            } else { fields.removeValue(forKey: "location") }
            return .object(fields)
        }
        guard try JSONEncoder().encode(items).count <= 350_000 else { throw CalendarToolArgumentError("This calendar is too large to share completely. Its previous copy is kept.") }
        let result = try await sharingCall("publish_calendar", .object([
            "source": .string(sharingSourceKey(calendarID)), "title": .string(String(calendar.title.prefix(200))),
            "items": .array(items), "starts": .string(ISO8601DateFormatter().string(from: start)), "ends": .string(ISO8601DateFormatter().string(from: end)),
            "expected_revision": .number(Double(source?.revision ?? 0))]), user: user)
        guard let id = result.objectValue?["calendarID"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw CalendarToolArgumentError("Sharing couldn’t confirm the calendar upload. Refresh before trying again.") }
        if let revision = result.objectValue?["revision"] {
            _ = try await sharingCall("calendar_publication_status", .object(["calendar": .string(id.uuidString), "expected_revision": revision, "failure": .null]), user: user)
        }
        try await readSharing(user: user)
        return id
    }
    func sendCalendarRequest(email: String, calendarIDs: [String], permission: String, token: String?) async throws {
        let user = try requireSharing(token)
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.count <= 254, email.contains("@"), (1...20).contains(calendarIDs.count), Set(calendarIDs).count == calendarIDs.count, ["busy", "titles", "details"].contains(permission), !agentIsRunning, !isSaving, !isCapturing, !isRecognizing else { throw CalendarToolArgumentError("Enter your friend’s account email, choose calendars and an access level, then wait for any active task to finish.") }
        sharingBusy = true; sharingError = nil
        defer { if account.userID == user { sharingBusy = false } }
        try await readSharing(user: user)
        var published: [JSONValue] = []
        for calendarID in calendarIDs { published.append(.string(try await publishSharingCalendar(calendarID, permission: permission, user: user, allowNew: true).uuidString)) }
        _ = try await sharingCall("request_calendar_share", .object(["email_address": .string(email), "calendars": .array(published), "access_level": .string(permission)]), user: user)
        try await readSharing(user: user)
    }
    func respondCalendarRequest(id: UUID, accept: Bool, token: String?) async throws {
        let user = try requireSharing(token)
        guard calendarSharing.shares.contains(where: { $0.id == id && !$0.outgoing && $0.status == "pending" }) else { throw CalendarToolArgumentError("This request is no longer waiting. Refresh sharing.") }
        sharingBusy = true
        defer { if account.userID == user { sharingBusy = false } }
        _ = try await sharingCall("respond_calendar_request", .object(["request": .string(id.uuidString), "accept_request": .bool(accept)]), user: user)
        try await readSharing(user: user)
    }
    func manageCalendarShare(id: UUID, permission: String, stop: Bool, token: String?) async throws {
        let user = try requireSharing(token)
        guard let share = calendarSharing.shares.first(where: { $0.id == id && ["pending", "accepted", "expired"].contains($0.status) }), stop || share.outgoing,
              ["busy", "titles", "details"].contains(permission) else { throw CalendarToolArgumentError("Refresh this sharing setting and try again.") }
        sharingBusy = true
        defer { if account.userID == user { sharingBusy = false } }
        _ = try await sharingCall("manage_calendar_request", .object(["request": .string(id.uuidString), "expected_permission": .string(share.permission), "next_permission": .string(permission), "stop": .bool(stop)]), user: user)
        try await readSharing(user: user)
        // Fresh publication is required when a friend is explicitly granted more detail.
        if !stop, share.outgoing {
            for calendar in share.calendars {
                if let local = readableCalendars.first(where: { sharingSourceKey($0.id) == calendarSharing.sources.first(where: { $0.id == calendar.id })?.sourceKey }) {
                    _ = try await publishSharingCalendar(local.id, permission: permission, user: user, allowNew: false)
                }
            }
        }
    }
    func withdrawSharingCalendar(id: UUID, token: String?) async throws {
        let user = try requireSharing(token)
        guard calendarSharing.sources.contains(where: { $0.id == id && !$0.withdrawn }) else { throw CalendarToolArgumentError("This calendar is no longer published.") }
        sharingBusy = true
        defer { if account.userID == user { sharingBusy = false } }
        _ = try await sharingCall("withdraw_calendar", .object(["calendar": .string(id.uuidString)]), user: user)
        try await readSharing(user: user)
    }
    func syncSharedCalendars(force: Bool = false) async {
        guard !softwareUpdates.installing else { return }
        guard account.canUseWorkspace, let user = account.userID, !sharingBusy, !agentIsRunning, !isSaving, !isCapturing, !isRecognizing else { return }
        sharingBusy = true
        defer { if account.userID == user { sharingBusy = false } }
        do {
            try await readSharing(user: user)
            let sources = calendarSharing.sources.filter { !$0.withdrawn && $0.sourceKey.hasPrefix(Self.syncDeviceID + ":") }
            for source in sources {
                let grants = calendarSharing.shares.filter { $0.outgoing && ["pending", "accepted"].contains($0.status) && $0.calendars.contains(where: { $0.id == source.id }) }
                guard !grants.isEmpty else { continue }
                let iso = ISO8601DateFormatter(); iso.formatOptions.insert(.withFractionalSeconds)
                let date = iso.date(from: source.syncedAt) ?? ISO8601DateFormatter().date(from: source.syncedAt)
                if !force, source.error == nil, let date, Date().timeIntervalSince(date) < 60 { continue }
                do {
                    guard let calendar = readableCalendars.first(where: { sharingSourceKey($0.id) == source.sourceKey }) else { throw CalendarToolArgumentError("This calendar is unavailable on its source Mac.") }
                    _ = try await publishSharingCalendar(calendar.id, permission: "busy", user: user, allowNew: false)
                } catch is CancellationError { return }
                catch {
                    _ = try? await sharingCall("calendar_publication_status", .object(["calendar": .string(source.id.uuidString), "expected_revision": .number(Double(source.revision)), "failure": .string(String(error.localizedDescription.prefix(500)))]), user: user)
                }
            }
            try await readSharing(user: user)
        } catch is CancellationError { }
        catch { guard account.userID == user else { return }; sharingError = "Sharing couldn’t sync. Previous copies may be out of date. Refresh to try again." }
    }
    func listAgentFriends() async throws -> JSONValue {
        guard let user = account.userID, !sharingBusy else { throw CalendarToolArgumentError("Sign in to Calshot and wait for any sharing update to finish.") }
        try await readSharing(user: user)
        let incoming = calendarSharing.shares.filter { !$0.outgoing && $0.status == "accepted" }
        var seen = Set<UUID>()
        return .object(["friends": .array(incoming.filter { seen.insert($0.ownerID).inserted }.map { share in
            .object(["id": .string(share.ownerID.uuidString), "name": .string(share.personName), "email": share.email.map(JSONValue.string) ?? .null, "readOnly": .bool(true)])
        }), "scope": .string("Only friends who accepted sharing and shared calendars with you appear here. Your outgoing sharing does not grant you access to their calendars.")])
    }
    func searchAgentFriend(_ fields: [String: JSONValue]) async throws -> JSONValue {
        guard let user = account.userID, let friend = fields["friendID"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw CalendarToolArgumentError("List friends first, then choose their account ID.") }
        return try await sharingCall("search_friend_calendars", .object(["friend": .string(friend.uuidString), "starts": fields["start"] ?? .null, "ends": fields["end"] ?? .null, "search": fields["query"] ?? .string("")]), user: user)
    }
}

@MainActor
extension CalshotModel {
    var friendBrowserSources: [(id: String, share: CalendarShare, calendar: FriendCalendar)] {
        guard sharingLoaded, sharingError == nil, account.userID != nil else { return [] }
        let rank = ["busy": 0, "titles": 1, "details": 2]
        var seen = Set<String>()
        return calendarSharing.shares.sorted { (rank[$0.permission] ?? 0) > (rank[$1.permission] ?? 0) }.filter { !$0.outgoing && $0.status == "accepted" }.flatMap { share in
            share.calendars.filter { seen.insert(share.ownerID.uuidString + ":" + $0.id.uuidString).inserted }.map { ("shared:" + share.id.uuidString.lowercased() + ":" + $0.id.uuidString.lowercased(), share, $0) }
        }
    }
    var friendAccessToken: String {
        let rows = friendBrowserSources.map { $0.id + ":" + $0.share.permission + ":" + $0.calendar.name }
        return SHA256.hash(data: Data((rows.joined(separator: "|") + (sharingError ?? "") + (account.userID?.uuidString ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func browseFriendCalendar(id: String, start: Date, end: Date) async throws -> (events: [JSONValue], warning: String?) {
        guard let user = account.userID, let source = friendBrowserSources.first(where: { $0.id.lowercased() == id.lowercased() }) else { throw CalendarToolArgumentError("This friend calendar is no longer available. Refresh sharing.") }
        let token = friendAccessToken
        let result = try await sharingCall("read_shared_calendar", .object(["invite": .string(source.share.id.uuidString), "calendar": .string(source.calendar.id.uuidString), "starts": .string(ISO8601DateFormatter().string(from: start)), "ends": .string(ISO8601DateFormatter().string(from: end)), "search": .string("")]), user: user)
        guard friendAccessToken == token else { throw CancellationError() }
        let fields = result.objectValue ?? [:]
        // Server permission can have changed since metadata was loaded. Discard the old view.
        guard fields["permission"]?.stringValue == source.share.permission else {
            try await readSharing(user: user)
            throw CalendarToolArgumentError("Your friend changed access. Refresh the calendar view.")
        }
        let rows = (fields["events"]?.arrayValue ?? []).map { value -> JSONValue in
            var row = value.objectValue ?? [:]
            row["eventIdentifier"] = .string("shared:" + (row.removeValue(forKey: "key")?.stringValue ?? UUID().uuidString))
            row["isAllDay"] = row.removeValue(forKey: "allDay") ?? .bool(false)
            row["calendarIdentifier"] = .string(id); row["calendarName"] = .string(source.calendar.name)
            row["sourceName"] = .string(source.share.personName + " · Shared read-only")
            if let url = row["url"]?.stringValue, !["http", "https", "mailto"].contains(URL(string: url)?.scheme?.lowercased() ?? "") { row.removeValue(forKey: "url") }
            return .object(row)
        }
        let warning = fields["error"]?.stringValue ?? (fields["stale"]?.boolValue == true ? "This friend calendar is out of date. Ask your friend to open Calshot and sync before relying on availability." : fields["complete"]?.boolValue != true ? "This friend calendar does not cover the full displayed date range. Missing events do not mean free time." : nil)
        return (rows, warning)
    }
}

#if DEBUG
@MainActor
extension CalshotModel {
    static func sharingPreviewModel() -> CalshotModel {
        let model = CalshotModel(calendarService: CalendarDemoService(), memoryStore: MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("CalshotSharingPreview")), loadsAIConnection: false)
        model.account.onAuthenticated = nil
        let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        model.account.accept(User(id: user, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "sam@example.invalid", createdAt: .now, updatedAt: .now), provider: "email")
        model.workspaceSelection = .settings
        let calendar = FriendCalendar(id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, name: "Studio workshops, portfolio reviews and community events", syncedAt: ISO8601DateFormatter().string(from: .now), stale: false)
        let request = CalendarShare(id: UUID(), ownerID: UUID(), recipientID: user, outgoing: false, personName: "Riley Morgan", email: "riley@example.invalid", permission: "titles", status: "pending", expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 86400)), calendars: [calendar])
        var friend = request; friend.id = UUID(); friend.ownerID = UUID(); friend.personName = "Jordan Lee"; friend.email = "jordan@example.invalid"; friend.status = "accepted"; friend.permission = "busy"; friend.calendars[0].stale = true; friend.calendars[0].error = "Source Mac is offline. The previous sharing copy is kept."
        model.calendarSharing = CalendarSharingState(shares: [request, friend]); model.sharingLoaded = true
        let snapshot = model.calendarSharing
        model.sharingRPC = { name, _, _ in
            if name == "read_calendar_sharing" { return WebWorkspaceState.encoded(snapshot) }
            throw CalendarToolArgumentError("Isolated preview only. No sharing request was sent or access changed.")
        }
        Task { await model.loadCalendars() }
        return model
    }
}
#endif
