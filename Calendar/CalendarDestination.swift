import Foundation

/// A stable destination choice suitable for persisting in app preferences.
enum CalendarDestination: Sendable, Equatable, Identifiable {
    /// Any calendar returned by EventKit, including Google calendars configured in macOS.
    case eventKit(calendarIdentifier: String)
    /// Reserved for direct Google API access. It is intentionally separate from EventKit
    /// destinations so a single save can never silently write to both providers.
    case google(calendarIdentifier: String)

    var id: String {
        switch self {
        case .eventKit(let id): "eventkit:\(id)"
        case .google(let id): "google:\(id)"
        }
    }
}

struct CalendarDestinationInfo: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let provider: Provider
    let isReadOnly: Bool

    enum Provider: String, Sendable { case apple, google, other }

    init(id: String, title: String, provider: Provider, isReadOnly: Bool) {
        self.id = id
        self.title = title
        self.provider = provider
        self.isReadOnly = isReadOnly
    }
}

protocol CalendarDestinationService: Sendable {
    func availableDestinations() async throws -> [CalendarDestinationInfo]
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String
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
            "Direct Google Calendar access needs an OAuth client ID and redirect configuration. Google calendars already added to macOS are available through Apple Calendar."
        case .googleAdapterUnavailable:
            "Direct Google Calendar saving is not enabled in this build."
        }
    }
}
