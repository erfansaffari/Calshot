import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// iCloud's standard CalDAV transport. Credentials never enter agent context.
actor ICloudCalendarService: CalendarDestinationService {
    private var calendars: [String: URL] = [:]
    private var writable = Set<String>()
    private var names: [String: String] = [:]
    private(set) var accountErrors: [UUID: String] = [:]
    struct Route {
        let accountID: UUID; let calendar: URL; var resource: URL?; var recurrence: String?
        var id: String { "icloud:\(accountID):\(CalendarAccountConnection.base64URL(Data(calendar.absoluteString.utf8)))" }
        var eventID: String { id + ":" + CalendarAccountConnection.base64URL(Data((resource?.absoluteString ?? "").utf8)) + ":" + CalendarAccountConnection.base64URL(Data((recurrence ?? "").utf8)) }
        init(accountID: UUID, calendar: URL, resource: URL? = nil, recurrence: String? = nil) { self.accountID = accountID; self.calendar = calendar; self.resource = resource; self.recurrence = recurrence }
        init?(id: String) {
            let p = id.split(separator: ":", omittingEmptySubsequences: false)
            guard p.count == 3 || p.count == 5, p[0] == "icloud", let account = UUID(uuidString: String(p[1])), let calendar = Self.decode(String(p[2])).flatMap(URL.init(string:)), ICloudCalendarService.allowed(calendar) else { return nil }
            accountID = account; self.calendar = calendar
            if p.count == 5 {
                guard let raw = Self.decode(String(p[3])), let resource = URL(string: raw), ICloudCalendarService.allowed(resource), Self.contains(resource, in: calendar) else { return nil }
                self.resource = resource; recurrence = Self.decode(String(p[4]))
            }
        }
        static func contains(_ resource: URL, in calendar: URL) -> Bool {
            let parent = resource.deletingLastPathComponent().standardized.absoluteURL
            return parent == calendar.standardized.absoluteURL && resource.query == nil && resource.fragment == nil
        }
        static func decode(_ value: String) -> String? {
            let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
    nonisolated static func allowed(_ url: URL) -> Bool { url.scheme == "https" && (url.host == "caldav.icloud.com" || (url.host?.hasSuffix("-caldav.icloud.com") == true)) && url.user == nil && url.password == nil }
    nonisolated static func discover(email: String, password: String) async throws -> URL {
        let root = URL(string: "https://caldav.icloud.com/")!
        let principal = try await send(root, method: "PROPFIND", body: #"<d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>"#, email: email, password: password, headers: ["Depth": "0"])
        let response = try DAVResponse.parse(principal.0)
        guard let href = response.first?.properties["current-user-principal"], let url = URL(string: href, relativeTo: principal.1.url!)?.absoluteURL, allowed(url) else { throw CalendarAccountConnection.ConnectionError(message: "iCloud did not return a trusted calendar principal.") }
        let home = try await send(url, method: "PROPFIND", body: #"<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><c:calendar-home-set/></d:prop></d:propfind>"#, email: email, password: password, headers: ["Depth": "0"])
        guard let path = try DAVResponse.parse(home.0).first?.properties["calendar-home-set"], let result = URL(string: path, relativeTo: home.1.url!)?.absoluteURL, allowed(result) else { throw CalendarAccountConnection.ConnectionError(message: "iCloud did not return a trusted calendar home.") }
        return result
    }
    func availableDestinations() async throws -> [CalendarDestinationInfo] {
        accountErrors = [:]; var result: [CalendarDestinationInfo] = []
        for account in CalendarAccountConnection.accounts() where account.provider == .icloud {
            do {
                guard let raw = account.calDAVHomeURL, let home = URL(string: raw), Self.allowed(home) else { throw CalendarDestinationError.calendarUnavailable }
                let (data, response) = try await Self.send(home, method: "PROPFIND", body: #"<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:displayname/><d:resourcetype/><d:current-user-privilege-set/></d:prop></d:propfind>"#, email: account.email, password: account.accessToken, headers: ["Depth": "1"])
                for entry in try DAVResponse.parse(data) where entry.isCalendar {
                    guard let url = URL(string: entry.href, relativeTo: response.url!)?.absoluteURL, Self.allowed(url) else { continue }
                    let route = Route(accountID: account.id, calendar: url)
                    let title = (entry.properties["displayname"] ?? "iCloud calendar") + " · " + account.email
                    calendars[route.id] = url; names[route.id] = title
                    if entry.canWrite { writable.insert(route.id) } else { writable.remove(route.id) }
                    result.append(.init(id: route.id, title: title, provider: .apple, isReadOnly: !entry.canWrite, accountIdentifier: account.email, remoteCalendarIdentifier: url.absoluteString, sourceName: "Direct iCloud"))
                }
                if !result.contains(where: { Route(id: $0.id)?.accountID == account.id }) { throw CalendarAccountConnection.ConnectionError(message: "No accessible iCloud calendars were found.") }
            } catch { accountErrors[account.id] = error.localizedDescription }
        }
        return result
    }
    private func context(_ destination: CalendarDestination, write: Bool = false) throws -> (Route, CalendarAccountConnection.Account) {
        let id: String; switch destination { case .eventKit(let raw), .google(let raw), .direct(let raw): id = raw }
        guard let route = Route(id: id), let account = CalendarAccountConnection.accounts().first(where: { $0.id == route.accountID && $0.provider == .icloud }), calendars[route.id] != nil else { throw CalendarDestinationError.calendarUnavailable }
        if write && !writable.contains(route.id) { throw CalendarDestinationError.calendarReadOnly }
        return (route, account)
    }
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] {
        let (route, account) = try context(destination)
        guard end > start, end.timeIntervalSince(start) <= 366 * 86400 else { throw CalendarDestinationError.invalidDraft("invalid search range") }
        let from = ICS.date(start), to = ICS.date(end)
        let xml = "<c:calendar-query xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\"><d:prop><d:getetag/><c:calendar-data><c:expand start=\"\(from)\" end=\"\(to)\"/></c:calendar-data></d:prop><c:filter><c:comp-filter name=\"VCALENDAR\"><c:comp-filter name=\"VEVENT\"><c:time-range start=\"\(from)\" end=\"\(to)\"/></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"
        let (data, response) = try await Self.send(route.calendar, method: "REPORT", body: xml, email: account.email, password: account.accessToken, headers: ["Depth": "1"])
        var events: [CalendarEventSnapshot] = []
        for entry in try DAVResponse.parse(data) {
            guard let raw = entry.properties["calendar-data"], let resource = URL(string: entry.href, relativeTo: response.url!)?.absoluteURL, Self.allowed(resource), Route.contains(resource, in: route.calendar) else { throw CalendarDestinationError.invalidDraft("iCloud could not return every matching event") }
            let (originalData, _) = try await Self.send(resource, method: "GET", email: account.email, password: account.accessToken)
            let originals = ICS(String(decoding: originalData, as: UTF8.self)).events
            for var component in ICS(raw).events {
                let original = originals.first { ICS.sameRecurrence($0.line("RECURRENCE-ID") ?? "", component.line("RECURRENCE-ID") ?? "") } ?? originals.first { !$0.has("RECURRENCE-ID") }
                if let original {
                    component.set("X-CALSHOT-TIMEZONE", "X-CALSHOT-TIMEZONE:" + original.timeZone)
                    if !component.has("LAST-MODIFIED") { component.set("LAST-MODIFIED", original.line("LAST-MODIFIED")) }
                }
                if component.value("STATUS") == "CANCELLED" { continue }
                guard !component.has("RRULE") else { throw CalendarDestinationError.invalidDraft("iCloud did not expand a recurring event; this calendar cannot be searched accurately") }
                var eventRoute = route; eventRoute.resource = resource; eventRoute.recurrence = component.line("RECURRENCE-ID") ?? ""
                var event = try component.snapshot(route: eventRoute, name: names[route.id] ?? "iCloud")
                if original?.has("RRULE") == true || original?.has("RDATE") == true { event.isRecurring = true }
                if event.start < end && event.end > start && CalendarSearchMatch.matches(query, title: event.title, notes: event.notes, location: event.location) { events.append(event) }
            }
        }
        return Array(events.sorted { $0.start < $1.start }.prefix(CalendarSearchMatch.resultLimit))
    }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? {
        let (calendar, account) = try context(destination)
        guard let route = Route(id: identifier), route.id == calendar.id, let resource = route.resource else { throw CalendarDestinationError.calendarUnavailable }
        do {
            let (data, _) = try await Self.send(resource, method: "GET", email: account.email, password: account.accessToken)
            let ics = ICS(String(decoding: data, as: UTF8.self))
            if let event = ics.events.first(where: { ICS.sameRecurrence($0.line("RECURRENCE-ID") ?? "", route.recurrence ?? "") }), !event.has("RRULE") {
                return event.value("STATUS") == "CANCELLED" ? nil : try event.snapshot(route: route, name: names[route.id] ?? "iCloud")
            }
            // Unmodified recurrence instances must be expanded by the server, not guessed locally.
            guard let recurrence = route.recurrence, !recurrence.isEmpty, let original = try? ICS.Component.parseDate(recurrence) else { throw CalendarDestinationError.invalidDraft("unsupported iCloud recurrence") }
            let values = try await searchEvents(query: nil, start: original.addingTimeInterval(-1), end: original.addingTimeInterval(2 * 86400), in: destination)
            return values.first { $0.eventIdentifier == identifier }
        } catch let error as DAVError where error.status == 404 || error.status == 410 { return nil }
    }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] {
        guard let start = draft.startDate, let end = draft.endDate else { return [] }
        return try await searchEvents(query: nil, start: start.addingTimeInterval(-60), end: end.addingTimeInterval(60), in: destination).filter { CalendarDraftValidation.sameEvent($0.draft, draft) }.map(\.eventIdentifier)
    }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String {
        let (calendar, account) = try context(destination, write: true)
        let resource = calendar.calendar.appendingPathComponent(draft.id.uuidString + ".ics")
        let body = try ICS.new(draft)
        do { _ = try await Self.send(resource, method: "PUT", body: body, email: account.email, password: account.accessToken, headers: ["Content-Type": "text/calendar; charset=utf-8", "If-None-Match": "*"]) }
        catch let error as DAVError where error.status == 412 {
            var target = calendar; target.resource = resource; target.recurrence = ""
            guard let existing = try await event(identifier: target.eventID, in: destination), CalendarDraftValidation.sameEvent(existing.draft, draft) else { throw error }
        }
        var route = calendar; route.resource = resource; route.recurrence = ""; return route.eventID
    }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String {
        try await modify(draft: draft, identifier: identifier, destination: destination, deleting: false); return identifier
    }
    func delete(identifier: String, in destination: CalendarDestination) async throws { try await modify(draft: nil, identifier: identifier, destination: destination, deleting: true) }
    private func modify(draft: EventDraft?, identifier: String, destination: CalendarDestination, deleting: Bool) async throws {
        let (calendar, account) = try context(destination, write: true)
        guard let route = Route(id: identifier), route.id == calendar.id, let resource = route.resource else { throw CalendarDestinationError.calendarUnavailable }
        let (data, response) = try await Self.send(resource, method: "GET", email: account.email, password: account.accessToken)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else { throw CalendarDestinationError.invalidDraft("iCloud returned no version for this event; refresh before changing it") }
        var document = ICS(String(decoding: data, as: UTF8.self))
        let recurrence = route.recurrence ?? ""
        if deleting && recurrence.isEmpty {
            _ = try await Self.send(resource, method: "DELETE", email: account.email, password: account.accessToken, headers: ["If-Match": etag]); return
        }
        let existing = try await event(identifier: identifier, in: destination)
        guard let existing else { throw CalendarDestinationError.calendarUnavailable }
        let revised = deleting ? existing.draft : draft!
        try document.change(revised, recurrence: recurrence, deleting: deleting)
        _ = try await Self.send(resource, method: "PUT", body: document.text, email: account.email, password: account.accessToken, headers: ["Content-Type": "text/calendar; charset=utf-8", "If-Match": etag])
    }
    struct DAVError: LocalizedError { let status: Int; var errorDescription: String? { "iCloud calendar request failed (HTTP \(status)). Check the app-specific password and calendar access." } }
    nonisolated static func send(_ url: URL, method: String, body: String? = nil, email: String, password: String, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard allowed(url) else { throw CalendarDestinationError.calendarUnavailable }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 60
        request.setValue("Basic " + Data((email + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }; request.httpBody = body?.data(using: .utf8)
        let session = URLSession(configuration: .ephemeral, delegate: ICloudRedirectDelegate(authorization: request.value(forHTTPHeaderField: "Authorization")!), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let final = http.url, allowed(final) else { throw CalendarDestinationError.calendarUnavailable }
        guard (200..<300).contains(http.statusCode) else { throw DAVError(status: http.statusCode) }
        return (data, http)
    }
}

/// Namespace-aware DAV parser; external entity resolution stays disabled.
final class DAVResponse: NSObject, XMLParserDelegate {
    struct Entry { var href = ""; var properties: [String: String] = [:]; var isCalendar = false; var canWrite = false }
    private var entries: [Entry] = []; private var current: Entry?; private var stack: [String] = []; private var text = ""; private var property: String?
    static func parse(_ data: Data) throws -> [Entry] {
        let delegate = DAVResponse(); let parser = XMLParser(data: data); parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw CalendarDestinationError.invalidDraft("invalid iCloud calendar response") }; return delegate.entries
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name); text = ""
        if name == "response" { current = Entry() }
        if stack.dropLast().last == "prop" { property = name }
        if name == "calendar" && namespaceURI == "urn:ietf:params:xml:ns:caldav" { current?.isCalendar = true }
        if name == "write" || name == "write-content" || name == "all" { current?.canWrite = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "href" {
            if let property { current?.properties[property] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            else { current?.href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if name == property { if current?.properties[name] == nil { current?.properties[name] = text.trimmingCharacters(in: .whitespacesAndNewlines) }; property = nil }
        if name == "response", let current { entries.append(current); self.current = nil }
        _ = stack.popLast(); text = ""
    }
}

struct ICS {
    struct Component {
        var lines: [String]
        func line(_ key: String) -> String? { lines.first { $0.split(separator: ":", maxSplits: 1).first?.split(separator: ";").first?.uppercased() == key } }
        func has(_ key: String) -> Bool { line(key) != nil }
        func value(_ key: String) -> String? { line(key).flatMap { $0.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) } }
        mutating func set(_ key: String, _ value: String?) { lines.removeAll { $0.split(separator: ":", maxSplits: 1).first?.split(separator: ";").first?.uppercased() == key }; if let value { lines.insert(value, at: max(1, lines.count - 1)) } }
        static func parseDate(_ line: String) throws -> Date {
            let parts = line.split(separator: ":", maxSplits: 1); guard parts.count == 2 else { throw CalendarDestinationError.invalidDraft("invalid iCloud date") }
            let raw = String(parts[1]); let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            if let zone = parts[0].split(separator: ";").first(where: { $0.hasPrefix("TZID=") }) {
                guard let timeZone = TimeZone(identifier: String(zone.dropFirst(5)).replacingOccurrences(of: "\"", with: "")) else { throw CalendarDestinationError.invalidDraft("unsupported iCloud timezone") }; formatter.timeZone = timeZone
            } else { formatter.timeZone = raw.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0) : .current }
            formatter.dateFormat = raw.count == 8 ? "yyyyMMdd" : raw.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"
            guard let date = formatter.date(from: raw) else { throw CalendarDestinationError.invalidDraft("invalid iCloud date") }; return date
        }
        var timeZone: String {
            if let custom = value("X-CALSHOT-TIMEZONE"), TimeZone(identifier: custom) != nil { return custom }
            guard let start = line("DTSTART") else { return TimeZone.current.identifier }
            return start.split(separator: ":", maxSplits: 1)[0].split(separator: ";").first(where: { $0.hasPrefix("TZID=") }).map { String($0.dropFirst(5)).replacingOccurrences(of: "\"", with: "") } ?? (start.hasSuffix("Z") ? "UTC" : TimeZone.current.identifier)
        }
        func snapshot(route: ICloudCalendarService.Route, name: String) throws -> CalendarEventSnapshot {
            guard let startLine = line("DTSTART"), let uid = value("UID") else { throw CalendarDestinationError.invalidDraft("incomplete iCloud event") }
            let allDay = (value("DTSTART")?.count == 8)
            func eventDate(_ line: String) throws -> Date {
                if allDay, let raw = line.split(separator: ":", maxSplits: 1).last { return try Self.parseDate("DTSTART;TZID=\(timeZone):\(raw)") }
                return try Self.parseDate(line)
            }
            let start = try eventDate(startLine)
            let end: Date
            if let raw = line("DTEND") { end = try eventDate(raw) }
            else if let duration = value("DURATION"), let seconds = ICS.duration(duration) { end = start.addingTimeInterval(seconds) }
            else if allDay {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
                end = calendar.date(byAdding: .day, value: 1, to: start)!
            }
            else { throw CalendarDestinationError.invalidDraft("iCloud event has no end time") }
            var result = CalendarEventSnapshot(eventIdentifier: route.eventID, title: ICS.unescape(value("SUMMARY") ?? "Untitled event"), start: start, end: end, isAllDay: allDay, timeZone: timeZone,
                         location: value("LOCATION").map(ICS.unescape), calendarName: name, url: value("URL").flatMap(URL.init(string:)), notes: value("DESCRIPTION").map(ICS.unescape), externalEventIdentifier: uid, isFree: value("TRANSP")?.uppercased() == "TRANSPARENT")
            let recurrence = line("RECURRENCE-ID")
            result.isRecurring = recurrence != nil || has("RRULE") || has("RDATE")
            result.hasAttendees = has("ATTENDEE")
            if let recurrence, let raw = value("RECURRENCE-ID") {
                if raw.count == 8 {
                    // Keep the provider's original date, independent of a moved DTSTART.
                    let date = String(raw.prefix(4)) + "-" + String(raw.dropFirst(4).prefix(2)) + "-" + String(raw.suffix(2))
                    result.recurrenceDate = RemoteCalendarService.validatedCalendarDate(date)
                } else if recurrence.hasSuffix("Z") || recurrence.contains(";TZID=") {
                    result.originalOccurrenceStart = try? Self.parseDate(recurrence)
                }
                // Floating recurrence times have no known instant; leave unresolved.
            }
            if let modified = line("LAST-MODIFIED"), modified.hasSuffix("Z") {
                result.modifiedAt = try? Self.parseDate(modified)
            }
            return result
        }
    }
    var lines: [String]
    init(_ text: String) {
        lines = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty { lines[lines.count - 1] += line.dropFirst() }
            else if !line.isEmpty { lines.append(line) }
        }
    }
    var events: [Component] { ranges.map { .init(lines: Array(lines[$0])) } }
    private var ranges: [Range<Int>] {
        var result: [Range<Int>] = []; var start: Int?
        for (index, line) in lines.enumerated() { if line == "BEGIN:VEVENT" { start = index }; if line == "END:VEVENT", let beginning = start { result.append(beginning..<(index + 1)); start = nil } }; return result
    }
    var text: String { lines.map(Self.fold).joined(separator: "\r\n") + "\r\n" }
    static func new(_ draft: EventDraft) throws -> String {
        var document = ICS("BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Calshot//Calendar Agent//EN\nBEGIN:VEVENT\nUID:\(draft.id.uuidString)\nEND:VEVENT\nEND:VCALENDAR")
        try document.change(draft, recurrence: "", deleting: false); return document.text
    }
    mutating func change(_ draft: EventDraft, recurrence: String, deleting: Bool) throws {
        guard CalendarDraftValidation.issues(draft).isEmpty, let start = draft.startDate, let end = draft.endDate, let master = events.first(where: { !$0.has("RECURRENCE-ID") }) else { throw CalendarDestinationError.invalidDraft("cannot change this iCloud event") }
        let index = events.firstIndex { Self.sameRecurrence($0.line("RECURRENCE-ID") ?? "", recurrence) }
        var event = index.map { events[$0] } ?? master
        if !recurrence.isEmpty { for field in ["RRULE", "RDATE", "EXDATE", "EXRULE"] { event.set(field, nil) }; event.set("RECURRENCE-ID", try Self.normalizedRecurrence(recurrence, master: master)) }
        if draft.isTaskDeadline == true { event.set("TRANSP", "TRANSP:TRANSPARENT") }
        event.set("DTSTAMP", "DTSTAMP:" + Self.date(.now))
        event.set("SEQUENCE", "SEQUENCE:" + String((Int(event.value("SEQUENCE") ?? "0") ?? 0) + 1))
        if index == nil {
            if draft.isAllDay {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = draft.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current; f.dateFormat = "yyyyMMdd"
                event.set("DTSTART", "DTSTART;VALUE=DATE:" + f.string(from: start)); event.set("DTEND", "DTEND;VALUE=DATE:" + f.string(from: end))
            } else { event.set("DTSTART", "DTSTART:" + Self.date(start)); event.set("DTEND", "DTEND:" + Self.date(end)) }
            event.set("X-CALSHOT-TIMEZONE", "X-CALSHOT-TIMEZONE:" + (draft.timeZoneIdentifier ?? TimeZone.current.identifier))
            event.set("DURATION", nil)
        }
        if deleting { event.set("STATUS", "STATUS:CANCELLED") }
        else {
            let fields = Set(draft.changedFieldNames ?? ["title", "date", "startTime", "endTime", "allDay", "timeZone", "location", "url", "notes"])
            if fields.contains("title") { event.set("SUMMARY", "SUMMARY:" + Self.escape(draft.title)) }
            if !fields.isDisjoint(with: ["date", "startTime", "endTime", "allDay", "timeZone"]) {
                event.set("X-CALSHOT-TIMEZONE", "X-CALSHOT-TIMEZONE:" + (draft.timeZoneIdentifier ?? TimeZone.current.identifier))
                if draft.isAllDay {
                    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = draft.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current; formatter.dateFormat = "yyyyMMdd"
                    event.set("DTSTART", "DTSTART;VALUE=DATE:" + formatter.string(from: start)); event.set("DTEND", "DTEND;VALUE=DATE:" + formatter.string(from: end))
                } else { event.set("DTSTART", "DTSTART:" + Self.date(start)); event.set("DTEND", "DTEND:" + Self.date(end)) }
                event.set("DURATION", nil)
            }
            if fields.contains("location") { event.set("LOCATION", draft.location.map { "LOCATION:" + Self.escape($0) }) }
            if fields.contains("url") { event.set("URL", draft.url.map { "URL:" + $0.absoluteString }) }
            if fields.contains("notes") { event.set("DESCRIPTION", draft.notes.map { "DESCRIPTION:" + Self.escape($0) }) }
        }
        if let index { lines.replaceSubrange(ranges[index], with: event.lines) }
        else if let end = lines.lastIndex(of: "END:VCALENDAR") { lines.insert(contentsOf: event.lines, at: end) }
    }
    static func sameRecurrence(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.isEmpty || rhs.isEmpty { return lhs == rhs }
        guard let left = try? Component.parseDate(lhs), let right = try? Component.parseDate(rhs) else { return lhs == rhs }
        return left == right
    }
    static func normalizedRecurrence(_ recurrence: String, master: Component) throws -> String {
        guard let start = master.line("DTSTART") else { throw CalendarDestinationError.invalidDraft("recurrence has no master start") }
        let date = try Component.parseDate(recurrence)
        let prefix = String(start.split(separator: ":", maxSplits: 1)[0]).replacingOccurrences(of: "DTSTART", with: "RECURRENCE-ID")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if let tz = start.split(separator: ":", maxSplits: 1)[0].split(separator: ";").first(where: { $0.hasPrefix("TZID=") }) { f.timeZone = TimeZone(identifier: String(tz.dropFirst(5))) }
        else { f.timeZone = start.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0) : .current }
        f.dateFormat = master.value("DTSTART")?.count == 8 ? "yyyyMMdd" : start.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"
        return prefix + ":" + f.string(from: date)
    }
    static func date(_ date: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; return f.string(from: date) }
    static func escape(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,") }
    static func unescape(_ value: String) -> String {
        var result = "", escaped = false
        for char in value { if escaped { result += (char == "n" || char == "N") ? "\n" : String(char); escaped = false } else if char == "\\" { escaped = true } else { result.append(char) } }; return result
    }
    static func fold(_ value: String) -> String { var parts: [String] = []; var line = ""; for char in value { if line.utf8.count + String(char).utf8.count > 74 { parts.append(line); line = " " }; line.append(char) }; parts.append(line); return parts.joined(separator: "\r\n") }
    static func duration(_ value: String) -> TimeInterval? {
        guard value.hasPrefix("P"), let regex = try? NSRegularExpression(pattern: #"^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let factors: [Double] = [604800, 86400, 3600, 60, 1]; return (1...5).reduce(0) { sum, i in guard let range = Range(match.range(at: i), in: value), let count = Double(value[range]) else { return sum }; return sum + count * factors[i - 1] }
    }
}

private final class ICloudRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let authorization: String
    init(authorization: String) { self.authorization = authorization }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ICloudCalendarService.allowed(url) else { completionHandler(nil); return }
        var redirected = request
        redirected.setValue(authorization, forHTTPHeaderField: "Authorization")
        redirected.httpMethod = task.originalRequest?.httpMethod; redirected.httpBody = task.originalRequest?.httpBody
        redirected.setValue(task.originalRequest?.value(forHTTPHeaderField: "Content-Type"), forHTTPHeaderField: "Content-Type")
        redirected.setValue(task.originalRequest?.value(forHTTPHeaderField: "Depth"), forHTTPHeaderField: "Depth")
        completionHandler(redirected)
    }
}
