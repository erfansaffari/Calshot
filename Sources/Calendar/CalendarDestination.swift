import Foundation

/// A stable destination choice suitable for persisting in app preferences.
enum CalendarDestination: Sendable, Equatable, Identifiable {
    /// Any calendar returned by EventKit, including Google calendars configured in macOS.
    case eventKit(calendarIdentifier: String)
    /// Reserved for direct Google API access. It is intentionally separate from EventKit
    /// destinations so a single save can never silently write to both providers.
    case google(calendarIdentifier: String)
    /// Account-scoped IDs handled by the connected provider router.
    case direct(calendarIdentifier: String)

    static func resolve(identifier: String) -> CalendarDestination {
        identifier.hasPrefix("remote:") || identifier.hasPrefix("icloud:") || identifier.hasPrefix("unavailable:")
            ? .direct(calendarIdentifier: identifier) : .eventKit(calendarIdentifier: identifier)
    }

    var id: String {
        switch self {
        case .eventKit(let id): "eventkit:\(id)"
        case .google(let id): "google:\(id)"
        case .direct(let id): "direct:\(id)"
        }
    }
}

struct CalendarDestinationInfo: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let provider: Provider
    let isReadOnly: Bool
    var accountIdentifier: String?
    var remoteCalendarIdentifier: String?
    var systemAccountIdentifier: String?
    var sourceName: String?
    var timeZone: String?

    enum Provider: String, Sendable { case apple, google, outlook, other }

    init(id: String, title: String, provider: Provider, isReadOnly: Bool, accountIdentifier: String? = nil, remoteCalendarIdentifier: String? = nil, sourceName: String? = nil, timeZone: String? = nil, systemAccountIdentifier: String? = nil) {
        self.id = id
        self.title = title
        self.provider = provider
        self.isReadOnly = isReadOnly
        self.accountIdentifier = accountIdentifier; self.remoteCalendarIdentifier = remoteCalendarIdentifier; self.sourceName = sourceName; self.timeZone = timeZone; self.systemAccountIdentifier = systemAccountIdentifier
    }
}

/// Immutable calendar data safe to pass into the model and approval UI.
public struct CalendarEventSnapshot: Codable, Sendable {
    public var eventIdentifier: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var timeZone: String?
    public var location: String?
    public var calendarName: String
    public var url: URL?
    public var notes: String?
    public var externalEventIdentifier: String? = nil
    public var isFree: Bool? = nil
    /// Provider-supplied original timed occurrence, never the mutable current start.
    /// All-day original anchors use recurrenceDate instead. IDs remain device scoped.
    public var originalOccurrenceStart: Date? = nil
    /// Original all-day calendar date (yyyy-MM-dd), without an invented due time.
    public var recurrenceDate: String? = nil
    /// nil means the provider did not establish whether this event repeats.
    public var isRecurring: Bool? = nil
    /// Provider modification time; absence does not imply an unchanged source.
    public var modifiedAt: Date? = nil

    public var draft: EventDraft {
        EventDraft(title: title, startDate: start, endDate: end, isAllDay: isAllDay,
                   timeZoneIdentifier: timeZone, location: location, url: url, notes: notes,
                   sourceText: "Existing calendar event", confidence: 1, ambiguities: [])
    }
}

protocol CalendarDestinationService: Sendable {
    func availableDestinations() async throws -> [CalendarDestinationInfo]
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String]
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot]
    /// Resolve an exact event in this readable calendar, including read-only sources.
    /// Implementations must reject other accounts/calendars; this confers no write authority.
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot?
    /// Revalidate a selected occurrence. Identifier-only EventKit reads return a series' first occurrence.
    func event(matching selected: CalendarEventSnapshot, in destination: CalendarDestination) async throws -> CalendarEventSnapshot?
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String
    func delete(identifier: String, in destination: CalendarDestination) async throws
    /// Changes only the selected occurrence. Series-wide edits are not offered here.
    func update(_ draft: EventDraft, matching selected: CalendarEventSnapshot, in destination: CalendarDestination) async throws -> String
    func delete(matching selected: CalendarEventSnapshot, in destination: CalendarDestination) async throws
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String
}

extension CalendarDestinationService {
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] { throw CalendarDestinationError.calendarUnavailable }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? { throw CalendarDestinationError.calendarUnavailable }
    func event(matching selected: CalendarEventSnapshot, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? {
        try await event(identifier: selected.eventIdentifier, in: destination)
    }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String { throw CalendarDestinationError.calendarUnavailable }
    func delete(identifier: String, in destination: CalendarDestination) async throws { throw CalendarDestinationError.calendarUnavailable }
    /// Changes the selected occurrence. The default uses the event identifier, which is one instance for provider calendars.
    func update(_ draft: EventDraft, matching selected: CalendarEventSnapshot, in destination: CalendarDestination) async throws -> String {
        try await update(draft, identifier: selected.eventIdentifier, in: destination)
    }
    func delete(matching selected: CalendarEventSnapshot, in destination: CalendarDestination) async throws {
        try await delete(identifier: selected.eventIdentifier, in: destination)
    }
}

enum CalendarDestinationError: LocalizedError, Sendable {
    case permissionDenied
    case calendarUnavailable
    case calendarReadOnly
    case invalidDraft(String)
    case googleNotConfigured
    case googleAdapterUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Calshot needs calendar access to list calendars and save events. Enable Calendar access in System Settings → Privacy & Security → Calendars."
        case .calendarUnavailable:
            "That calendar is no longer available. Choose another calendar."
        case .calendarReadOnly:
            "That calendar is read-only. Choose a calendar that allows changes."
        case .invalidDraft(let reason): "This event can’t be saved: \(reason)"
        case .googleNotConfigured:
            "Connect Google Calendar in Settings → Calendar accounts, or use a Google calendar already added to macOS."
        case .googleAdapterUnavailable:
            "Direct Google Calendar saving is not enabled in this build."
        }
    }
}
