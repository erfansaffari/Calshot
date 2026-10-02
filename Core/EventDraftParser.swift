import Foundation

/// A deliberately conservative, offline parser for common event-page text.
/// Uncertain fields remain visible in `ambiguities` for the review step.
enum EventDraftParser {
    static func parse(_ text: String, referenceDate: Date = .now,
                      timeZone: TimeZone = .current, locale: Locale = .current) -> [EventDraft] {
        let cleaned = text.replacingOccurrences(of: "\r", with: "")
        let lines = cleaned.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        let zone = findTimeZone(in: cleaned)
        let eventZone = zone.identifier.flatMap(TimeZone.init(identifier:)) ?? timeZone
        let dates = findDates(in: cleaned, referenceDate: referenceDate, timeZone: eventZone, locale: locale)
        let times = findTimes(in: cleaned)
        let urls = findURLs(in: cleaned)
        let title = chooseTitle(lines)
        let explicitAllDay = dates.first != nil && times.isEmpty && cleaned.range(of: #"(?i)\b(all[- ]day|full[- ]day)\b"#, options: .regularExpression) != nil
        var issues: [EventAmbiguity] = []
        if title.isEmpty { issues.append(.missingTitle) }
        if dates.isEmpty { issues.append(.missingDate) }
        if dates.contains(where: \.yearWasAssumed) { issues.append(.missingYear) }
        if dates.contains(where: \.ambiguous) { issues.append(.ambiguousDate) }
        if dates.first != nil && times.isEmpty && !explicitAllDay { issues.append(.missingTime) }
        if times.contains(where: \.ambiguous) { issues.append(.ambiguousTime) }
        if zone.ambiguous { issues.append(.ambiguousTimeZone) }
        if dates.count > 1 { issues.append(.multipleEvents) }

        let eventDate = dates.first?.date
        // Keep the recognized date visible in the editor. Date-only text uses
        // a provisional all-day shape, and `.missingTime` makes that assumption
        // explicit so the user can choose a time or confirm all-day.
        let provisionalAllDay = dates.first != nil && times.isEmpty
        let allDay = explicitAllDay || provisionalAllDay
        let start = eventDate.flatMap { date in times.first.map { applying($0.startMinutes, to: date, calendar: calendar(eventZone)) } }
            ?? (allDay ? eventDate.map { calendar(eventZone).startOfDay(for: $0) } : nil)
        var end = eventDate.flatMap { date in
            times.first?.endMinutes.map { applying($0, to: date, calendar: calendar(eventZone)) }
        }
        if !times.isEmpty && times[0].endMinutes == nil {
            issues.append(.missingEndTime)
            if let start, let provisionalEnd = calendar(eventZone).date(byAdding: .hour, value: 1, to: start) { end = provisionalEnd }
        }
        if allDay, let date = eventDate, let dayEnd = calendar(eventZone).date(byAdding: .day, value: 1, to: calendar(eventZone).startOfDay(for: date)) { end = dayEnd }
        if let start, let candidateEnd = end, candidateEnd <= start,
           let adjusted = calendar(eventZone).date(byAdding: .day, value: 1, to: candidateEnd) { end = adjusted }

        let confidence = max(0.05, min(0.99, 0.92 - Double(issues.count) * 0.11))
        let location = findLocation(lines)
        let notes: String? = nil
        return [EventDraft(title: title, startDate: allDay ? eventDate.map { calendar(eventZone).startOfDay(for: $0) } : start, endDate: end, isAllDay: allDay,
                           timeZoneIdentifier: zone.identifier ?? timeZone.identifier,
                           location: location, url: urls.first, notes: notes,
                           sourceText: cleaned, confidence: confidence, ambiguities: issues)]
    }

    private struct ParsedDate { let date: Date; let yearWasAssumed: Bool; let ambiguous: Bool }
    private struct ParsedTime { let startMinutes: Int; let endMinutes: Int?; let ambiguous: Bool }
    private struct ZoneResult { let identifier: String?; let ambiguous: Bool }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c
    }

    private static func findDates(in text: String, referenceDate: Date, timeZone: TimeZone, locale: Locale) -> [ParsedDate] {
        let cal = calendar(timeZone)
        let month = #"(?i)\b(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#
        let numeric = #"\b(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?\b"#
        var results: [ParsedDate] = []
        let ns = text as NSString
        let isoRanges = matches(#"\b\d{4}-\d{2}-\d{2}\b"#, text).map(\.range)
        func add(_ date: Date, assumed: Bool, ambiguous: Bool, range: NSRange) {
            if results.allSatisfy({ abs($0.date.timeIntervalSince(date)) > 12 * 3600 }) {
                results.append(ParsedDate(date: date, yearWasAssumed: assumed, ambiguous: ambiguous))
            }
        }
        for range in isoRanges {
            let value = ns.substring(with: range).split(separator: "-").compactMap { Int($0) }
            guard value.count == 3, let date = makeDate(year: value[0], month: value[1], day: value[2], calendar: cal) else { continue }
            add(date, assumed: false, ambiguous: false, range: range)
        }
        for match in matches(month, text) {
            guard match.numberOfRanges >= 3, let m = capture(match, 1, ns)?.lowercased(),
                  let day = capture(match, 2, ns).flatMap(Int.init) else { continue }
            let months = ["january","february","march","april","may","june","july","august","september","october","november","december"]
            let prefixes = ["jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"]
            guard let idx = months.firstIndex(where: { $0 == m || $0.hasPrefix(m == "sept" ? "sep" : m) }) ?? prefixes.firstIndex(of: String(m.prefix(3))) else { continue }
            let year = capture(match, 3, ns).flatMap(Int.init) ?? cal.component(.year, from: referenceDate)
            if let d = makeDate(year: year, month: idx + 1, day: day, calendar: cal) {
                add(d, assumed: capture(match, 3, ns) == nil, ambiguous: false, range: match.range)
            }
        }
        for match in matches(numeric, text) {
            if isoRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            guard let a = capture(match, 1, ns).flatMap(Int.init), let b = capture(match, 2, ns).flatMap(Int.init) else { continue }
            let rawYear = capture(match, 3, ns).flatMap(Int.init)
            let year = rawYear.map { $0 < 100 ? 2000 + $0 : $0 } ?? cal.component(.year, from: referenceDate)
            let ambiguous = a <= 12 && b <= 12 && a != b
            // Keep both interpretations as a single flagged proposal, favoring the locale's usual order.
            let usOrder = locale.region?.identifier == "US"
            let month = usOrder ? a : (b > 12 ? a : b)
            let day = usOrder ? b : (b > 12 ? b : a)
            if let d = makeDate(year: year, month: month, day: day, calendar: cal) {
                add(d, assumed: rawYear == nil, ambiguous: ambiguous, range: match.range)
            }
        }
        let weekdays = ["sunday","monday","tuesday","wednesday","thursday","friday","saturday"]
        let lower = text.lowercased()
        for (idx, name) in weekdays.enumerated() where lower.range(of: #"\b" + name + #"\b"# , options: .regularExpression) != nil {
            let today = cal.component(.weekday, from: referenceDate)
            var delta = (idx + 1 - today + 7) % 7
            if delta == 0 && lower.contains("next \(name)") { delta = 7 }
            if let d = cal.date(byAdding: .day, value: delta, to: cal.startOfDay(for: referenceDate)),
               results.allSatisfy({ !cal.isDate($0.date, inSameDayAs: d) }) {
                results.append(ParsedDate(date: d, yearWasAssumed: true, ambiguous: false))
            }
        }
        if lower.contains("tomorrow"), let d = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: referenceDate)), results.isEmpty {
            results.append(ParsedDate(date: d, yearWasAssumed: true, ambiguous: false))
        }
        return results.sorted { $0.date < $1.date }
    }

    private static func findTimes(in text: String) -> [ParsedTime] {
        let pattern = #"(?i)\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:-|–|—|to)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b|\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let isoRanges = matches(#"\b\d{4}-\d{2}-\d{2}\b"#, text).map(\.range)
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { match in !isoRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) }
            .compactMap { m in
            func value(_ i: Int) -> String? { capture(m, i, ns) }
            if let firstHour = value(1).flatMap(Int.init) {
                let firstMeridiem = value(3)?.lowercased(), secondMeridiem = value(6)?.lowercased() ?? firstMeridiem
                let first = minutes(hour: firstHour, minute: Int(value(2) ?? "0") ?? 0, meridiem: firstMeridiem)
                let second = value(4).flatMap(Int.init).map { minutes(hour: $0, minute: Int(value(5) ?? "0") ?? 0, meridiem: secondMeridiem) }
                return ParsedTime(startMinutes: first, endMinutes: second, ambiguous: firstMeridiem == nil || secondMeridiem == nil)
            }
            guard let hour = value(7).flatMap(Int.init) else { return nil }
            return ParsedTime(startMinutes: minutes(hour: hour, minute: Int(value(8) ?? "0") ?? 0, meridiem: value(9)?.lowercased()), endMinutes: nil, ambiguous: false)
        }
    }

    private static func minutes(hour: Int, minute: Int, meridiem: String?) -> Int {
        var h = hour
        if meridiem == "pm" && h < 12 { h += 12 }
        if meridiem == "am" && h == 12 { h = 0 }
        return min(23, max(0, h)) * 60 + min(59, max(0, minute))
    }

    private static func applying(_ minutes: Int, to date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .minute, value: minutes, to: day) ?? date
    }

    private static func makeDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day
        guard let date = calendar.date(from: c) else { return nil }
        let result = calendar.dateComponents([.year, .month, .day], from: date)
        return result.year == year && result.month == month && result.day == day ? date : nil
    }

    private static func findURLs(in text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>\]\[()]+"#, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            URL(string: ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!")))
        }
    }

    private static func findTimeZone(in text: String) -> ZoneResult {
        let patterns = [#"\b(?:PST|PDT|MST|MDT|CST|CDT|EST|EDT|GMT|UTC)\b"#, #"\b(?:America|Europe|Asia|Australia)/[A-Za-z_+-]+(?:/[A-Za-z_+-]+)?\b"#]
        var found: [String] = []
        for pattern in patterns {
            let ns = text as NSString
            for m in matches(pattern, text) { if let s = capture(m, 0, ns) { found.append(s.uppercased()) } }
        }
        let map = ["PST":"America/Los_Angeles", "PDT":"America/Los_Angeles", "MST":"America/Denver", "MDT":"America/Denver", "CST":"America/Chicago", "CDT":"America/Chicago", "EST":"America/New_York", "EDT":"America/New_York", "GMT":"Etc/GMT", "UTC":"Etc/UTC"]
        let zones = Set(found.map { map[$0] ?? $0 })
        return ZoneResult(identifier: zones.first, ambiguous: zones.count > 1)
    }

    private static func findLocation(_ lines: [String]) -> String? {
        lines.first { line in
            let l = line.lowercased()
            return [" at ", "location:", "venue:", "room ", "street", " avenue", " road", " boulevard"].contains { l.contains($0) }
                && !line.contains("http")
        }?.replacingOccurrences(of: #"(?i)^(location|venue):\s*"#, with: "", options: .regularExpression)
    }

    private static func chooseTitle(_ lines: [String]) -> String {
        lines.first { line in
            let l = line.lowercased()
            let dateLine = l.range(of: #"\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}[/-]\d{1,2}\b|\b(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\.?\s+\d{1,2}\b|\b(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#, options: .regularExpression) != nil
            let timeLine = l.range(of: #"\b\d{1,2}(?::\d{2})?\s*(am|pm)?\s*(?:-|–|—|to)\s*\d{1,2}(?::\d{2})?\s*(am|pm)?\b|\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*(am|pm)\b"#, options: .regularExpression) != nil
            return line.count > 2 && !line.contains("http") && !line.contains("@")
                && !dateLine && !timeLine && !l.hasPrefix("location:") && !l.hasPrefix("venue:")
        } ?? ""
    }

    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func capture(_ match: NSTextCheckingResult, _ index: Int, _ ns: NSString) -> String? {
        guard index < match.numberOfRanges, match.range(at: index).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: index))
    }
}
