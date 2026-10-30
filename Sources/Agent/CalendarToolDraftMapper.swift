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

    /// Relative phrases in the user's own words resolve from the clock, so they settle the year (screen text never does).
    static let relativeDatePattern = #"(?i)\b(today|tonight|tomorrow|day after tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next (week|month)|this (week|weekend|month)|in \d+ (days?|weeks?))\b"#
    /// Only native user/answer text can settle a model's inferred-year flag. Competing or
    /// negated years remain unresolved and can be confirmed in the explicit review control.
    static func explicitlyConfirmsYear(_ year: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:19\d{2}|20\d{2}|21\d{2}|2200)\b"#) else { return false }
        let ns = text as NSString
        let years = Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
        guard years == Set([year]) else { return false }
        let negated = #"(?i)\b(?:not|isn't|is not|don't use|do not use)\s+(?:the year\s+)?"# + year + #"\b"#
        return text.range(of: negated, options: .regularExpression) == nil
    }
    private static let monthPatterns = ["jan(?:uary)?", "feb(?:ruary)?", "mar(?:ch)?", "apr(?:il)?", "may", "june?", "july?", "aug(?:ust)?",
                                        "sep(?:t(?:ember)?)?", "oct(?:ober)?", "nov(?:ember)?", "dec(?:ember)?"]
    /// True when the user's own words name this month and day ("Nov 12", "November 12th", "12 November", "the 12th of Nov").
    /// Numeric forms such as 11/12 are skipped: day/month order is ambiguous.
    static func userNamesMonthDay(month: Int, day: Int, in text: String) -> Bool {
        guard (1...12).contains(month), (1...31).contains(day) else { return false }
        let name = monthPatterns[month - 1], number = "0?\(day)(?:st|nd|rd|th)?"
        let patterns = [#"(?i)\b"# + name + #"\.?,?\s+(?:the\s+)?"# + number + #"\b"#,
                        #"(?i)\b(?:the\s+)?"# + number + #"\s+(?:of\s+)?"# + name + #"\b"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
    static func mentionsAnyYear(_ text: String) -> Bool {
        text.range(of: #"\b(?:19|20|21)\d{2}\b"#, options: .regularExpression) != nil
    }
    /// The next time this month/day occurs, today included, in the event's calendar. Skips years where it does not exist (Feb 29).
    static func nextOccurrence(month: Int, day: Int, from now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now), year = calendar.component(.year, from: now)
        for offset in 0..<9 {
            guard let date = calendar.date(from: DateComponents(year: year + offset, month: month, day: day)),
                  calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { continue }
            if date >= today { return date }
        }
        return nil
    }
    static func create(_ value: JSONValue, context: String, confirmedContext: String = "", now: Date = .now) throws -> EventDraft {
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
        var day = try date(dateValue, calendar: calendar)
        var issues: [EventAmbiguity] = []
        if day == nil { issues.append(.missingDate) }
        let spokenRelative = confirmedContext.range(of: relativeDatePattern, options: .regularExpression) != nil
        let clockYear = calendar.component(.year, from: now)
        // A month and day the user typed or said without any year means the next time it comes around.
        // Native code settles that year deterministically (correcting a past year the model chose); dates that
        // appear only in a screenshot or other source keep their year unresolved for review.
        var yearFromUserWords = false
        if let parsed = day, !mentionsAnyYear(confirmedContext) {
            let month = calendar.component(.month, from: parsed), dayOfMonth = calendar.component(.day, from: parsed)
            if userNamesMonthDay(month: month, day: dayOfMonth, in: confirmedContext),
               let upcoming = nextOccurrence(month: month, day: dayOfMonth, from: now, calendar: calendar) {
                day = upcoming; yearFromUserWords = true
            }
        }
        let resolvedYear = day.map { String(calendar.component(.year, from: $0)) }
        if !yearFromUserWords, let year = resolvedYear ?? dateValue.map({ String($0.prefix(4)) }), !explicitlyConfirmsYear(String(year), in: confirmedContext),
           yearInferred == true || !((context + "\n" + evidence).contains(String(year)) || (spokenRelative && yearInferred == false && [clockYear, clockYear + 1].contains(Int(year) ?? 0))) {
            issues.append(.missingYear)
        }
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
