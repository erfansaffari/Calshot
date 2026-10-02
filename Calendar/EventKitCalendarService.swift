import EventKit
import Foundation

/// Apple Calendar writer. Calendars from Google and other accounts already configured
/// in macOS are exposed by EventKit and should be saved through this adapter to avoid
/// duplicating an event through a second provider connection.
actor EventKitCalendarService: CalendarDestinationService {
    private let store = EKEventStore()
    /// Prevents rapid repeated confirmations from creating the same event twice.
    private var savedEventIdentifiers: [UUID: String] = [:]

    init() {}

    func availableDestinations() async throws -> [CalendarDestinationInfo] {
        try await ensureFullAccess()
        return store.calendars(for: .event).map { calendar in
            let provider: CalendarDestinationInfo.Provider
            switch calendar.source.sourceType {
            case .local, .calDAV:
                let sourceName = calendar.source.title.lowercased()
                provider = sourceName.contains("google") ? .google : .apple
            default:
                provider = .other
            }
            return CalendarDestinationInfo(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                provider: provider,
                isReadOnly: !calendar.allowsContentModifications
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String {
        if let existingIdentifier = savedEventIdentifiers[draft.id] {
            return existingIdentifier
        }
        guard case .eventKit(let identifier) = destination else {
            throw CalendarDestinationError.googleNotConfigured
        }
        try await ensureFullAccess()
        guard let calendar = store.calendar(withIdentifier: identifier) else {
            throw CalendarDestinationError.calendarUnavailable
        }
        guard calendar.allowsContentModifications else {
            throw CalendarDestinationError.calendarReadOnly
        }
        let (startDate, endDate) = try validatedDates(draft)

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = draft.isAllDay
        event.timeZone = draft.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
        event.location = draft.location
        event.url = draft.url

        let notes = draft.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        event.notes = notes.isEmpty ? nil : notes
        try store.save(event, span: .thisEvent, commit: true)
        let eventIdentifier = event.eventIdentifier ?? event.calendarItemIdentifier
        savedEventIdentifiers[draft.id] = eventIdentifier
        return eventIdentifier
    }

    private func ensureFullAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly:
            // Write-only authorization cannot enumerate calendars. Requesting full access
            // is required by the explicit calendar destination picker.
            if EKEventStore.authorizationStatus(for: .event) == .writeOnly {
                let granted = try await store.requestFullAccessToEvents()
                guard granted else { throw CalendarDestinationError.permissionDenied }
            }
        case .notDetermined:
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { throw CalendarDestinationError.permissionDenied }
        case .denied, .restricted:
            throw CalendarDestinationError.permissionDenied
        @unknown default:
            throw CalendarDestinationError.permissionDenied
        }
    }

    private func validatedDates(_ draft: EventDraft) throws -> (Date, Date) {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalendarDestinationError.invalidDraft("the title is empty")
        }
        guard let startDate = draft.startDate, let endDate = draft.endDate else {
            throw CalendarDestinationError.invalidDraft("start and end dates are required")
        }
        guard endDate > startDate else {
            throw CalendarDestinationError.invalidDraft("the end must be later than the start")
        }
        if let identifier = draft.timeZoneIdentifier, TimeZone(identifier: identifier) == nil {
            throw CalendarDestinationError.invalidDraft("the time zone identifier is invalid")
        }
        return (startDate, endDate)
    }
}
