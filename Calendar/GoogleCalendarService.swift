import Foundation

/// Configuration seam for a future direct Google Calendar OAuth adapter.
/// Do not ship a placeholder OAuth flow as if it can create events. In the first
/// release, Google calendars added to macOS are surfaced through EventKit.
struct GoogleCalendarConfiguration: Sendable, Equatable {
    let clientID: String
    let redirectURI: URL
    let keychainService: String

    init(clientID: String, redirectURI: URL, keychainService: String = "com.calshot.google-oauth") {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.keychainService = keychainService
    }
}

/// Honest placeholder: direct Google API support remains disabled until OAuth,
/// Keychain token storage, refresh, and API insertion are implemented together.
struct GoogleCalendarService: CalendarDestinationService {
    let configuration: GoogleCalendarConfiguration?

    init(configuration: GoogleCalendarConfiguration? = nil) {
        self.configuration = configuration
    }

    func availableDestinations() async throws -> [CalendarDestinationInfo] {
        guard configuration != nil else { throw CalendarDestinationError.googleNotConfigured }
        throw CalendarDestinationError.googleAdapterUnavailable
    }

    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String {
        guard configuration != nil else { throw CalendarDestinationError.googleNotConfigured }
        throw CalendarDestinationError.googleAdapterUnavailable
    }
}
