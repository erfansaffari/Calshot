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
                provider = sourceName.contains("google") || sourceName.contains("gmail") ? .google : (sourceName.contains("outlook") || sourceName.contains("microsoft") ? .outlook : .apple)
            case .exchange: provider = .outlook
            default:
                provider = .other
            }
            return CalendarDestinationInfo(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                provider: provider,
                isReadOnly: !calendar.allowsContentModifications, sourceName: calendar.source.title, systemAccountIdentifier: calendar.source.sourceIdentifier
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] {
        try await ensureFullAccess()
        guard case .eventKit(let identifier) = destination,
              let calendar = store.calendar(withIdentifier: identifier) else {
            throw CalendarDestinationError.calendarUnavailable
        }
        guard let start = draft.startDate, let end = draft.endDate, end > start else { return [] }
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-60),
                                                end: end.addingTimeInterval(60), calendars: [calendar])
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.events(matching: predicate).filter {
            ($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title &&
            abs($0.startDate.timeIntervalSince(start)) < 60 && abs($0.endDate.timeIntervalSince(end)) < 60 &&
            $0.isAllDay == draft.isAllDay
        }.map { $0.eventIdentifier ?? $0.calendarItemIdentifier }
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
        if draft.isTaskDeadline == true { event.availability = .free }
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

    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] {
        try await ensureFullAccess()
        guard case .eventKit(let identifier) = destination, let calendar = store.calendar(withIdentifier: identifier) else {
            throw CalendarDestinationError.calendarUnavailable
        }
        guard end > start, end.timeIntervalSince(start) <= 366 * 24 * 3600 else {
            throw CalendarDestinationError.invalidDraft("search range must be positive and at most one year")
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        let text = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return store.events(matching: predicate).filter {
            text.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(text) || ($0.notes ?? "").localizedCaseInsensitiveContains(text)
        }.sorted { $0.startDate < $1.startDate }.prefix(40).map(snapshot)
    }

    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? {
        try await ensureFullAccess()
        let calendar = try writableCalendar(destination)
        guard let event = store.event(withIdentifier: identifier), event.calendar.calendarIdentifier == calendar.calendarIdentifier else { return nil }
        return snapshot(event)
    }

    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String {
        try await ensureFullAccess()
        let calendar = try writableCalendar(destination)
        guard let event = store.event(withIdentifier: identifier), event.calendar.calendarIdentifier == calendar.calendarIdentifier else {
            throw CalendarDestinationError.calendarUnavailable
        }
        let (start, end) = try validatedDates(draft)
        // Preserve unrelated fields even if another client changes them after review.
        let fields = Set(draft.changedFieldNames ?? ["title", "date", "startTime", "endTime", "allDay", "timeZone", "location", "url", "notes"])
        if fields.contains("title") { event.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !fields.isDisjoint(with: ["date", "allDay", "timeZone"]) { event.startDate = start; event.endDate = end }
        else {
            if fields.contains("startTime") { event.startDate = start }
            if fields.contains("endTime") { event.endDate = end }
        }
        if draft.isTaskDeadline == true { event.availability = .free }
        if fields.contains("allDay") || fields.contains("startTime") { event.isAllDay = draft.isAllDay }
        if fields.contains("timeZone") { event.timeZone = draft.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) }
        if fields.contains("location") { event.location = draft.location }
        if fields.contains("url") { event.url = draft.url }
        if fields.contains("notes") { event.notes = draft.notes }
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? event.calendarItemIdentifier
    }

    func delete(identifier: String, in destination: CalendarDestination) async throws {
        try await ensureFullAccess()
        let calendar = try writableCalendar(destination)
        guard let event = store.event(withIdentifier: identifier), event.calendar.calendarIdentifier == calendar.calendarIdentifier else {
            throw CalendarDestinationError.calendarUnavailable
        }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    private func writableCalendar(_ destination: CalendarDestination) throws -> EKCalendar {
        guard case .eventKit(let identifier) = destination, let calendar = store.calendar(withIdentifier: identifier) else {
            throw CalendarDestinationError.calendarUnavailable
        }
        guard calendar.allowsContentModifications else { throw CalendarDestinationError.calendarReadOnly }
        return calendar
    }

    private func snapshot(_ event: EKEvent) -> CalendarEventSnapshot {
        CalendarEventSnapshot(eventIdentifier: event.eventIdentifier ?? event.calendarItemIdentifier,
                              title: event.title ?? "", start: event.startDate, end: event.endDate,
                              isAllDay: event.isAllDay, timeZone: event.timeZone?.identifier,
                              location: event.location, calendarName: event.calendar.title, url: event.url, notes: event.notes, externalEventIdentifier: event.calendarItemExternalIdentifier, isFree: event.availability == .notSupported ? nil : event.availability == .free)
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
        let issues = CalendarDraftValidation.issues(draft)
        guard issues.isEmpty else { throw CalendarDestinationError.invalidDraft(issues.joined(separator: " ")) }
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
