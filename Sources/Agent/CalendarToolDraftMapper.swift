import Foundation

struct CalendarToolArgumentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum CalendarToolDraftMapper {
    static func keys(_ fields: [String: JSONValue], allowed: Set<String>) throws {
        let unknown = Set(fields.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw CalendarToolArgumentError("Unknown arguments: \(unknown.sorted().joined(separator: ", ")).") }
    }
    static func string(_ fields: [String: JSONValue], _ key: String, required: Bool = false, limit: Int = 8000) throws -> String? {
        guard let value = fields[key], value != .null else {
            if required { throw CalendarToolArgumentError("\(key) is required.") }
            return nil
        }
        guard let string = value.stringValue, string.count <= limit else { throw CalendarToolArgumentError("\(key) must be a string of at most \(limit) characters.") }
        return string
    }
    static func boolean(_ fields: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let value = fields[key], value != .null else { return nil }
        guard let bool = value.boolValue else { throw CalendarToolArgumentError("\(key) must be a boolean or null.") }
        return bool
    }
    static func instant(_ fields: [String: JSONValue], _ key: String) throws -> Date? {
        guard let value = try string(fields, key, limit: 40) else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let date = formatter.date(from: value) else { throw CalendarToolArgumentError("\(key) must be an ISO-8601 timestamp including its timezone.") }
        return date
    }
    private static func date(_ value: String?, calendar: Calendar) throws -> Date? {
        guard let value else { return nil }
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw CalendarToolArgumentError("date must be YYYY-MM-DD or null.") }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1900...2200).contains(parts[0]),
              let result = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.component(.year, from: result) == parts[0], calendar.component(.month, from: result) == parts[1],
              calendar.component(.day, from: result) == parts[2] else { throw CalendarToolArgumentError("date is not a real calendar date.") }
        return result
    }
    private static func minutes(_ value: String?) throws -> Int? {
        guard let value else { return nil }
        guard value.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil else { throw CalendarToolArgumentError("Times must be HH:mm or null.") }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { throw CalendarToolArgumentError("Invalid time.") }
        return parts[0] * 60 + parts[1]
    }
    private static func validURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    static func create(_ value: JSONValue, context: String, confirmedContext: String = "") throws -> EventDraft {
        guard let fields = value.objectValue else { throw CalendarToolArgumentError("Each event must be an object.") }
        try keys(fields, allowed: ["title", "date", "startTime", "endTime", "allDay", "timeZone", "location", "url", "notes", "evidence", "yearInferred", "dateAmbiguous"])
        guard let title = try string(fields, "title", required: true, limit: 500), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CalendarToolArgumentError("Every event needs a title.") }
        let dateValue = try string(fields, "date", limit: 20)
        let startTime = try minutes(string(fields, "startTime", limit: 10))
        let endTime = try minutes(string(fields, "endTime", limit: 10))
        let requestedAllDay = try boolean(fields, "allDay")
        let zoneName = try string(fields, "timeZone", limit: 100)
        let evidence = try string(fields, "evidence", limit: 4000) ?? ""
        let location = try string(fields, "location", limit: 1000)
        let rawURL = try string(fields, "url", limit: 2048)
        let notes = try string(fields, "notes")
        let yearInferred = try boolean(fields, "yearInferred")
        let dateAmbiguous = try boolean(fields, "dateAmbiguous")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zoneName.flatMap(TimeZone.init(identifier:)) ?? .current
        let day = try date(dateValue, calendar: calendar)
        var issues: [EventAmbiguity] = []
        if day == nil { issues.append(.missingDate) }
        if let year = dateValue?.prefix(4), yearInferred == true || !(context + "\n" + evidence).contains(String(year)) { issues.append(.missingYear) }
        let explicitAllDay = (confirmedContext + "\n" + evidence).range(of: #"(?i)\ball[- ]day\b"#, options: .regularExpression) != nil
        if startTime == nil && !(requestedAllDay == true && explicitAllDay) { issues.append(.missingTime) }
        if dateAmbiguous == true { issues.append(.ambiguousDate) }
        if !evidence.isEmpty {
            let parsed = EventDraftParser.parse(evidence, timeZone: calendar.timeZone)
            if parsed.first?.ambiguities.contains(.ambiguousDate) == true && !issues.contains(.ambiguousDate) { issues.append(.ambiguousDate) }
        }
        if zoneName != nil && TimeZone(identifier: zoneName!) == nil { issues.append(.ambiguousTimeZone) }
        if rawURL != nil && validURL(rawURL) == nil { issues.append(.invalidURL) }
        // Date-only proposals stay unset as timed events until an explicit all-day choice is reviewed.
        let allDay = requestedAllDay == true
        let start = day.flatMap { day in allDay ? calendar.startOfDay(for: day) : startTime.flatMap { calendar.date(byAdding: .minute, value: $0, to: day) } }
        let end: Date?
        if allDay, let start { end = calendar.date(byAdding: .day, value: 1, to: start) }
        else if let day, let endTime { end = calendar.date(byAdding: .minute, value: endTime, to: day) }
        else if let start { end = start.addingTimeInterval(3600) }
        else { end = nil }
        if !allDay && endTime == nil { issues.append(.missingEndTime) }
        return EventDraft(title: title, startDate: start ?? (startTime == nil ? day : nil), endDate: end, isAllDay: allDay,
                          timeZoneIdentifier: zoneName ?? calendar.timeZone.identifier, location: location, url: validURL(rawURL), notes: notes,
                          sourceText: evidence, confidence: issues.isEmpty ? 0.9 : 0.5, ambiguities: issues)
    }

    static func update(_ fields: [String: JSONValue], before: EventDraft) throws -> EventDraft {
        var draft = before
        draft.changedFieldNames = fields.keys.filter { $0 != "eventIdentifier" }.sorted()
        draft.id = UUID(); draft.sourceText = "Requested calendar update"; draft.ambiguities = []
        if fields["title"] != nil {
            guard let title = try string(fields, "title", required: true, limit: 500), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CalendarToolArgumentError("title cannot be empty.") }
            draft.title = title
        }
        let oldCalendar = CalendarDraftValidation.calendar(for: before)
        if fields["timeZone"] != nil {
            let name = try string(fields, "timeZone", limit: 100)
            draft.timeZoneIdentifier = name
            if let name, TimeZone(identifier: name) == nil { draft.ambiguities.append(.ambiguousTimeZone) }
        }
        let calendar = CalendarDraftValidation.calendar(for: draft)
        if fields["timeZone"] != nil, calendar.timeZone != oldCalendar.timeZone {
            draft.startDate = before.startDate.flatMap { calendar.date(from: oldCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0)) }
            draft.endDate = before.endDate.flatMap { calendar.date(from: oldCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0)) }
        }
        if fields["date"] != nil {
            if let newDay = try date(string(fields, "date", limit: 20), calendar: calendar), let start = draft.startDate {
                let parts = calendar.dateComponents([.hour, .minute, .second], from: start)
                let newStart = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0, of: newDay)
                let duration = draft.endDate.map { $0.timeIntervalSince(start) }
                draft.startDate = newStart
                draft.endDate = newStart.flatMap { date in duration.map { date.addingTimeInterval($0) } }
            } else { draft.startDate = nil; draft.endDate = nil; draft.ambiguities.append(.missingDate) }
        }
        if fields["allDay"] != nil {
            guard let enabled = try boolean(fields, "allDay") else { throw CalendarToolArgumentError("allDay must be true or false when changed.") }
            CalendarDraftValidation.setAllDay(&draft, enabled: enabled)
        }
        if fields["startTime"] != nil {
            if let value = try minutes(string(fields, "startTime", limit: 10)), let start = draft.startDate {
                draft.startDate = calendar.date(byAdding: .minute, value: value, to: calendar.startOfDay(for: start))
                draft.ambiguities.removeAll { $0 == .missingTime }
                if draft.isAllDay { draft.isAllDay = false }
            } else { draft.startDate = nil; draft.ambiguities.append(.missingTime) }
        }
        if fields["endTime"] != nil {
            if let value = try minutes(string(fields, "endTime", limit: 10)), let start = draft.startDate {
                draft.endDate = calendar.date(byAdding: .minute, value: value, to: calendar.startOfDay(for: start))
                draft.ambiguities.removeAll { $0 == .missingEndTime }
            } else { draft.endDate = nil; draft.ambiguities.append(.missingEndTime) }
        }
        if draft.isAllDay, fields["date"] != nil || fields["allDay"] != nil, let start = draft.startDate {
            let days = before.isAllDay ? before.startDate.flatMap { originalStart in
                before.endDate.flatMap { oldCalendar.dateComponents([.day], from: originalStart, to: $0).day }
            } ?? 1 : 1
            draft.startDate = calendar.startOfDay(for: start)
            draft.endDate = calendar.date(byAdding: .day, value: max(1, days), to: calendar.startOfDay(for: start))
        }
        if fields["location"] != nil { draft.location = try string(fields, "location", limit: 1000) }
        if fields["notes"] != nil { draft.notes = try string(fields, "notes") }
        if fields["url"] != nil {
            let value = try string(fields, "url", limit: 2048)
            draft.url = validURL(value)
            if value != nil && draft.url == nil { draft.ambiguities.append(.invalidURL) }
        }
        return draft
    }
}
