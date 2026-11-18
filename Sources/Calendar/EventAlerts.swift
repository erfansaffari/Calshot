import Foundation

/// Event alerts, stored on the calendar provider so every device and calendar app shows them.
/// A value is minutes before the event start; a negative value fires after the start (an all-day
/// event's "9 AM on the day" is -540). nil on a draft means "leave the provider's alerts as they are".
enum EventAlerts {
    /// Google's limit, and a sensible cap everywhere.
    static let maximumCount = 5
    /// Four weeks, Google's limit.
    static let maximumMinutes = 40_320
    /// Up to a day after the start, for all-day events read from Apple calendars.
    static let minimumMinutes = -1_439

    /// Sorted, de-duplicated and bounded, or a message the agent and editor can show.
    static func normalized(_ values: [Int]) throws -> [Int] {
        let unique = Array(Set(values)).sorted()
        guard unique.count <= maximumCount else { throw CalendarToolArgumentError("An event can have at most \(maximumCount) alerts.") }
        guard unique.allSatisfy({ (minimumMinutes...maximumMinutes).contains($0) }) else {
            throw CalendarToolArgumentError("Alerts must be between the event start and four weeks before it.")
        }
        return unique
    }

    /// Reads an `alerts` tool argument: an array of whole minutes, [] for none, null to leave unchanged.
    static func argument(_ value: JSONValue?) throws -> [Int]? {
        guard let value, value != .null else { return nil }
        guard case .array(let items) = value else { throw CalendarToolArgumentError("alerts must be an array of minutes before the start, [] for none, or null.") }
        let minutes = try items.map { item -> Int in
            guard let number = item.numberValue, number.isFinite, number == number.rounded() else { throw CalendarToolArgumentError("Each alert is a whole number of minutes before the start.") }
            return Int(number)
        }
        let result = try normalized(minutes)
        guard result.allSatisfy({ $0 >= 0 }) else { throw CalendarToolArgumentError("Alerts must be at or before the event start.") }
        return result
    }

    static func label(_ minutes: Int) -> String {
        if minutes == 0 { return "At start" }
        if minutes < 0 { return "\(clock(-minutes)) after start" }
        return "\(clock(minutes)) before"
    }
    private static func clock(_ minutes: Int) -> String {
        if minutes % 10_080 == 0 { let w = minutes / 10_080; return w == 1 ? "1 week" : "\(w) weeks" }
        if minutes % 1_440 == 0 { let d = minutes / 1_440; return d == 1 ? "1 day" : "\(d) days" }
        if minutes % 60 == 0 { let h = minutes / 60; return h == 1 ? "1 hour" : "\(h) hours" }
        if minutes > 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        return "\(minutes) min"
    }
    static func summary(_ values: [Int]?) -> String {
        guard let values else { return "Calendar default" }
        return values.isEmpty ? "None" : values.map(label).joined(separator: ", ")
    }

    // MARK: iCalendar

    /// A relative TRIGGER duration for an alert this many minutes before the start.
    static func trigger(_ minutes: Int) -> String {
        if minutes == 0 { return "PT0S" }
        let sign = minutes > 0 ? "-" : ""
        var rest = abs(minutes), text = "P"
        if rest >= 1_440, rest % 1_440 == 0 { return sign + "P\(rest / 1_440)D" }
        if rest >= 1_440 { text += "\(rest / 1_440)D"; rest %= 1_440 }
        text += "T"
        if rest >= 60 { text += "\(rest / 60)H"; rest %= 60 }
        if rest > 0 || text.hasSuffix("T") { text += "\(rest)M" }
        return sign + text
    }
    /// Minutes before the start for a relative TRIGGER value ("-PT15M", "-P1DT2H", "PT0S"), or nil.
    static func minutes(trigger value: String) -> Int? {
        var text = value.trimmingCharacters(in: .whitespaces).uppercased()
        var sign = 1
        if text.hasPrefix("-") { sign = -1; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
        guard let seconds = ICS.duration(text) else { return nil }
        // "-PT15M" (before) is +15 minutes before; "PT15M" (after) is -15.
        return -sign * Int((seconds / 60).rounded())
    }
}
