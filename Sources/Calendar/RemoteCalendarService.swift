import Foundation

/// Direct Google and Microsoft transport. IDs include account/calendar routing context.
actor RemoteCalendarService: CalendarDestinationService {
    private let accountsLoader: @Sendable () -> [CalendarAccountConnection.Account]
    private let accountAccess: @Sendable (UUID) async throws -> CalendarAccountConnection.Account
    private let http: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    init(accountsLoader: @escaping @Sendable () -> [CalendarAccountConnection.Account] = { CalendarAccountConnection.accounts() },
         accountAccess: @escaping @Sendable (UUID) async throws -> CalendarAccountConnection.Account = { try await CalendarAccountConnection.shared.access(accountID: $0) },
         http: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.accountsLoader = accountsLoader; self.accountAccess = accountAccess; self.http = http
    }
    private var calendars: [String: CalendarDestinationInfo] = [:]
    private(set) var accountErrors: [UUID: String] = [:]
    struct Route: Sendable {
        let accountID: UUID; let calendarID: String; var eventID: String?
        var calendarIdentifier: String { "remote:\(accountID.uuidString):\(CalendarAccountConnection.base64URL(Data(calendarID.utf8)))" }
        func identifier(event: String) -> String { calendarIdentifier + ":" + CalendarAccountConnection.base64URL(Data(event.utf8)) }
        init(accountID: UUID, calendarID: String, eventID: String? = nil) { self.accountID = accountID; self.calendarID = calendarID; self.eventID = eventID }
        init?(identifier: String) {
            let parts = identifier.split(separator: ":", omittingEmptySubsequences: false)
            guard (3...4).contains(parts.count), parts[0] == "remote", let id = UUID(uuidString: String(parts[1])),
                  let calendar = Self.decode(String(parts[2])), !calendar.isEmpty else { return nil }
            accountID = id; calendarID = calendar
            if parts.count == 4 { guard let event = Self.decode(String(parts[3])), !event.isEmpty else { return nil }; eventID = event }
        }
        private static func decode(_ value: String) -> String? {
            let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
    func availableDestinations() async throws -> [CalendarDestinationInfo] {
        accountErrors = [:]
        let accounts = accountsLoader().filter { $0.provider != .icloud }
        calendars = calendars.filter { key, _ in Route(identifier: key).map { route in accounts.contains { $0.id == route.accountID } } ?? false }
        for account in accounts {
            do {
                let path = account.provider == .google ? "https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=250" : "https://graph.microsoft.com/v1.0/me/calendars?$top=100"
                let items = try await list(path, account: account, googleKey: "items")
                guard !items.isEmpty else { throw CalendarAccountConnection.ConnectionError(message: "This account exposes no calendars to Calshot. Calendar services may be unavailable or blocked by the organization's policy.") }
                var found: [String: CalendarDestinationInfo] = [:]
                for item in items {
                    guard let id = item["id"] as? String else { continue }
                    let route = Route(accountID: account.id, calendarID: id)
                    let readOnly = account.provider == .google ? !["owner", "writer"].contains(item["accessRole"] as? String ?? "") : !(item["canEdit"] as? Bool ?? false)
                    found[route.calendarIdentifier] = CalendarDestinationInfo(id: route.calendarIdentifier,
                        title: (item[account.provider == .google ? "summary" : "name"] as? String ?? "Calendar") + " · " + account.email,
                        provider: account.provider == .google ? .google : .outlook, isReadOnly: readOnly,
                        accountIdentifier: account.email, remoteCalendarIdentifier: id, sourceName: account.provider.title, timeZone: item["timeZone"] as? String)
                }
                calendars = calendars.filter { Route(identifier: $0.key)?.accountID != account.id }
                calendars.merge(found) { _, new in new }
            } catch { accountErrors[account.id] = error.localizedDescription }
        }
        return calendars.values.sorted { $0.title < $1.title }
    }
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] {
        let (route, account, calendar) = try await context(destination)
        guard end > start, end.timeIntervalSince(start) <= 366 * 86400 else { throw CalendarDestinationError.invalidDraft("invalid search range") }
        let base = eventPath(route, provider: account.provider)
        var url = URLComponents(string: account.provider == .google ? base : base.replacingOccurrences(of: "/events", with: "/calendarView"))!
        var parameters = ["timeMin": ISO8601DateFormatter().string(from: start), "timeMax": ISO8601DateFormatter().string(from: end), "singleEvents": "true", "orderBy": "startTime", "maxResults": "250"]
        if account.provider == .outlook { parameters = ["startDateTime": ISO8601DateFormatter().string(from: start), "endDateTime": ISO8601DateFormatter().string(from: end), "$top": "100", "$orderby": "start/dateTime"] }
        url.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        let objects = try await list(url.url!.absoluteString, account: account, googleKey: "items")
        let events = try objects.filter { ($0["status"] as? String) != "cancelled" && ($0["isCancelled"] as? Bool) != true }.map { try Self.snapshot($0, route: route, account: account, calendar: calendar) }
        let text = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return events.filter { text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) || ($0.notes ?? "").localizedCaseInsensitiveContains(text) }.sorted { $0.start < $1.start }.prefix(40).map { $0 }
    }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? {
        let (route, account, calendar) = try await context(destination)
        guard let eventRoute = Route(identifier: identifier), eventRoute.calendarIdentifier == route.calendarIdentifier, let eventID = eventRoute.eventID else { throw CalendarDestinationError.calendarUnavailable }
        do {
            let value = try await request(eventPath(route, provider: account.provider) + "/" + Self.escape(eventID), account: account)
            guard value["id"] as? String == eventID else { throw CalendarDestinationError.calendarUnavailable }
            return try Self.snapshot(value, route: route, account: account, calendar: calendar)
        } catch let error as HTTPError where error.status == 404 || error.status == 410 { return nil }
    }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] {
        guard let start = draft.startDate, let end = draft.endDate else { return [] }
        return try await searchEvents(query: nil, start: start.addingTimeInterval(-60), end: end.addingTimeInterval(60), in: destination)
            .filter { CalendarDraftValidation.sameEvent($0.draft, draft) }.map(\.eventIdentifier)
    }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String {
        let (route, account, calendar) = try await context(destination, write: true)
        var body = try Self.body(draft, provider: account.provider)
        if account.provider == .google { body["id"] = draft.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        else { body["transactionId"] = draft.id.uuidString }
        let result: [String: Any]
        do { result = try await request(eventPath(route, provider: account.provider), account: account, method: "POST", body: body) }
        catch let error as HTTPError where error.status == 409 && account.provider == .google {
            let id = draft.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let existing = try await request(eventPath(route, provider: account.provider) + "/" + id, account: account)
            guard CalendarDraftValidation.sameEvent(try Self.snapshot(existing, route: route, account: account, calendar: calendar).draft, draft) else { throw error }
            result = existing
        }
        guard let id = result["id"] as? String else { throw CalendarDestinationError.calendarUnavailable }
        return route.identifier(event: id)
    }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String {
        let (route, account, _) = try await context(destination, write: true)
        guard let target = Route(identifier: identifier), target.calendarIdentifier == route.calendarIdentifier, let id = target.eventID else { throw CalendarDestinationError.calendarUnavailable }
        let full = try Self.body(draft, provider: account.provider, includeURL: false)
        let fields = Set(draft.changedFieldNames ?? ["title", "date", "startTime", "endTime", "allDay", "timeZone", "location", "url", "notes"])
        var body: [String: Any] = [:]
        if fields.contains("title") { body[account.provider == .google ? "summary" : "subject"] = full[account.provider == .google ? "summary" : "subject"] }
        if !fields.isDisjoint(with: ["date", "startTime", "endTime", "allDay", "timeZone"]) {
            body["start"] = full["start"]; body["end"] = full["end"]
            if account.provider == .outlook { body["isAllDay"] = full["isAllDay"] }
        }
        if fields.contains("location") { body["location"] = full["location"] }
        if draft.isTaskDeadline == true { body[account.provider == .google ? "transparency" : "showAs"] = account.provider == .google ? "transparent" : "free" }
        if fields.contains("notes") { body[account.provider == .google ? "description" : "body"] = full[account.provider == .google ? "description" : "body"] }
        if fields.contains("url") { throw CalendarDestinationError.invalidDraft("this provider does not support changing an event URL") }
        _ = try await request(eventPath(route, provider: account.provider) + "/" + Self.escape(id), account: account, method: "PATCH", body: body)
        return identifier
    }
    func delete(identifier: String, in destination: CalendarDestination) async throws {
        let (route, account, _) = try await context(destination, write: true)
        guard let target = Route(identifier: identifier), target.calendarIdentifier == route.calendarIdentifier, let id = target.eventID else { throw CalendarDestinationError.calendarUnavailable }
        _ = try await request(eventPath(route, provider: account.provider) + "/" + Self.escape(id), account: account, method: "DELETE")
    }
    private func context(_ destination: CalendarDestination, write: Bool = false) async throws -> (Route, CalendarAccountConnection.Account, CalendarDestinationInfo) {
        let raw: String
        switch destination { case .eventKit(let id), .google(let id), .direct(let id): raw = id }
        guard let route = Route(identifier: raw), let calendar = calendars[route.calendarIdentifier] else { throw CalendarDestinationError.calendarUnavailable }
        if write && calendar.isReadOnly { throw CalendarDestinationError.calendarReadOnly }
        let account = try await accountAccess(route.accountID)
        guard account.id == route.accountID, account.provider != .icloud else { throw CalendarDestinationError.calendarUnavailable }
        return (route, account, calendar)
    }
    private func eventPath(_ route: Route, provider: CalendarAccountConnection.Provider) -> String {
        provider == .google ? "https://www.googleapis.com/calendar/v3/calendars/\(Self.escape(route.calendarID))/events" : "https://graph.microsoft.com/v1.0/me/calendars/\(Self.escape(route.calendarID))/events"
    }
    struct HTTPError: LocalizedError { let status: Int; let message: String; var errorDescription: String? { message } }
    private func request(_ url: String, account: CalendarAccountConnection.Account, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let current = try await accountAccess(account.id)
        guard current.id == account.id, current.provider == account.provider else { throw CalendarDestinationError.calendarUnavailable }
        guard let endpoint = URL(string: url), endpoint.scheme == "https", ["www.googleapis.com", "graph.microsoft.com"].contains(endpoint.host ?? "") else { throw CalendarDestinationError.calendarUnavailable }
        var request = URLRequest(url: endpoint); request.httpMethod = method; request.timeoutInterval = 60
        request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("IdType=\"ImmutableId\", outlook.timezone=\"\(TimeZone.current.identifier)\"", forHTTPHeaderField: "Prefer")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await http(request)
        guard let http = response as? HTTPURLResponse else { throw CalendarDestinationError.calendarUnavailable }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = (object?["error"] as? [String: Any])?["message"] as? String ?? "Calendar request did not complete."
            throw HTTPError(status: http.statusCode, message: "\(account.provider.title) calendar request failed (HTTP \(http.statusCode)): \(detail)")
        }
        if data.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    private func list(_ initial: String, account: CalendarAccountConnection.Account, googleKey: String) async throws -> [[String: Any]] {
        var next: String? = initial; var values: [[String: Any]] = []; var visited = Set<String>()
        while let url = next {
            try Task.checkCancellation()
            guard visited.insert(url).inserted, visited.count <= 100 else { throw CalendarDestinationError.invalidDraft("calendar pagination did not finish") }
            let response = try await request(url, account: account)
            values += response[account.provider == .google ? googleKey : "value"] as? [[String: Any]] ?? []
            if account.provider == .google, let token = response["nextPageToken"] as? String {
                var components = URLComponents(string: initial)!; var items = components.queryItems ?? []
                items.removeAll { $0.name == "pageToken" }; items.append(.init(name: "pageToken", value: token)); components.queryItems = items; next = components.url!.absoluteString
            } else { next = response["@odata.nextLink"] as? String }
        }
        return values
    }
    static func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    static func snapshot(_ value: [String: Any], route: Route, account: CalendarAccountConnection.Account, calendar: CalendarDestinationInfo) throws -> CalendarEventSnapshot {
        guard let id = value["id"] as? String, let startObject = value["start"] as? [String: Any], let endObject = value["end"] as? [String: Any] else { throw CalendarDestinationError.invalidDraft("incomplete provider event") }
        let allDay = account.provider == .google ? startObject["date"] != nil : value["isAllDay"] as? Bool ?? false
        var startFields = startObject, endFields = endObject
        if account.provider == .google, allDay { startFields["timeZone"] = calendar.timeZone ?? TimeZone.current.identifier; endFields["timeZone"] = calendar.timeZone ?? TimeZone.current.identifier }
        let start = try instant(startFields), end = try instant(endFields)
        let body = value["body"] as? [String: Any]
        let location = account.provider == .google ? value["location"] as? String : (value["location"] as? [String: Any])?["displayName"] as? String
        var event = CalendarEventSnapshot(eventIdentifier: route.identifier(event: id), title: value[account.provider == .google ? "summary" : "subject"] as? String ?? "Untitled event",
            start: start, end: end, isAllDay: allDay, timeZone: startFields["timeZone"] as? String ?? "UTC", location: location, calendarName: calendar.title,
            url: (value[account.provider == .google ? "htmlLink" : "webLink"] as? String).flatMap(URL.init(string:)), notes: account.provider == .google ? value["description"] as? String : body?["content"] as? String)
        event.isFree = account.provider == .google ? value["transparency"] as? String == "transparent" : value["showAs"] as? String == "free"
        event.externalEventIdentifier = value[account.provider == .google ? "iCalUID" : "iCalUId"] as? String
        if let attendees = value["attendees"] as? [Any] { event.hasAttendees = !attendees.isEmpty } else if account.provider == .google { event.hasAttendees = false }
        if account.provider == .google {
            event.isRecurring = value["recurringEventId"] != nil || value["recurrence"] != nil || value["originalStartTime"] != nil
            if let original = value["originalStartTime"] as? [String: Any] {
                if let date = original["date"] as? String {
                    event.recurrenceDate = validatedCalendarDate(date)
                } else if let raw = original["dateTime"] as? String {
                    // RFC3339 must carry an offset: do not invent a timezone for identity.
                    event.originalOccurrenceStart = providerTimestamp(raw)
                }
            }
            event.modifiedAt = (value["updated"] as? String).flatMap(providerTimestamp)
        } else {
            switch value["type"] as? String {
            case "singleInstance": event.isRecurring = false
            case "occurrence", "exception", "seriesMaster": event.isRecurring = true
            default: event.isRecurring = value["seriesMasterId"] != nil ? true : nil
            }
            // Graph originalStart is an instant even for all-day events. Its original
            // date/timezone type is not supplied, so never derive a date-only anchor.
            if !allDay { event.originalOccurrenceStart = (value["originalStart"] as? String).flatMap(providerTimestamp) }
            event.modifiedAt = (value["lastModifiedDateTime"] as? String).flatMap(providerTimestamp)
        }
        return event
    }
    static func providerTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
    static func validatedCalendarDate(_ raw: String) -> String? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { return nil }
        return raw
    }
    static func instant(_ value: [String: Any]) throws -> Date {
        if let day = value["date"] as? String {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = (value["timeZone"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
            if let result = formatter.date(from: day) { return result }
        }
        if let raw = value["dateTime"] as? String {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let result = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) { return result }
            let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX")
            local.timeZone = (value["timeZone"] as? String).flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)
            local.dateFormat = raw.contains(".") ? "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS" : "yyyy-MM-dd'T'HH:mm:ss"
            if let result = local.date(from: raw) { return result }
        }
        throw CalendarDestinationError.invalidDraft("invalid provider event date")
    }
    static func body(_ draft: EventDraft, provider: CalendarAccountConnection.Provider, includeURL: Bool = true) throws -> [String: Any] {
        guard CalendarDraftValidation.issues(draft).isEmpty, let start = draft.startDate, let end = draft.endDate else { throw CalendarDestinationError.invalidDraft("review event dates first") }
        let zone = draft.timeZoneIdentifier ?? TimeZone.current.identifier
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: zone) ?? .current
        if provider == .google {
            let startValue: [String: Any], endValue: [String: Any]
            if draft.isAllDay { formatter.dateFormat = "yyyy-MM-dd"; startValue = ["date": formatter.string(from: start)]; endValue = ["date": formatter.string(from: end)] }
            else { startValue = ["dateTime": ISO8601DateFormatter().string(from: start), "timeZone": zone]; endValue = ["dateTime": ISO8601DateFormatter().string(from: end), "timeZone": zone] }
            var notes = draft.notes ?? ""; if includeURL, let url = draft.url { notes += "\n" + url.absoluteString }
            return ["transparency": draft.isTaskDeadline == true ? "transparent" : "opaque", "summary": draft.title, "start": startValue, "end": endValue, "location": draft.location ?? "", "description": notes]
        }
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var notes = draft.notes ?? ""; if includeURL, let url = draft.url { notes += "\n" + url.absoluteString }
        return ["showAs": draft.isTaskDeadline == true ? "free" : "busy", "subject": draft.title, "start": ["dateTime": formatter.string(from: start), "timeZone": zone], "end": ["dateTime": formatter.string(from: end), "timeZone": zone], "isAllDay": draft.isAllDay,
                "location": ["displayName": draft.location ?? ""], "body": ["contentType": "text", "content": notes]]
    }
}
