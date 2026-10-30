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
        return store.events(matching: predicate).filter {
            CalendarSearchMatch.matches(query, title: $0.title, notes: $0.notes, location: $0.location)
        }.sorted { $0.startDate < $1.startDate }.prefix(CalendarSearchMatch.resultLimit).map(snapshot)
    }

    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? {
        try await ensureFullAccess()
        let calendar = try readableCalendar(destination)
        guard let event = store.event(withIdentifier: identifier), Self.belongsToCalendar(event, calendar: calendar) else { return nil }
        return snapshot(event)
    }

    func event(matching selected: CalendarEventSnapshot, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? {
        guard selected.isRecurring == true else { return try await event(identifier: selected.eventIdentifier, in: destination) }
        try await ensureFullAccess()
        let calendar = try readableCalendar(destination)
        guard selected.start.timeIntervalSince1970.isFinite, selected.end.timeIntervalSince1970.isFinite,
              selected.end > selected.start, selected.end.timeIntervalSince(selected.start) <= 366 * 86400 else {
            throw CalendarDestinationError.invalidDraft("The selected occurrence has an invalid date range.")
        }
        // EventKit's identifier lookup resolves the first occurrence. Search the selected interval
        // instead, with no title or duration inference and no search presentation cap.
        let predicate = store.predicateForEvents(withStart: selected.start.addingTimeInterval(-1),
                                                end: selected.end.addingTimeInterval(1), calendars: [calendar])
        let candidates = store.events(matching: predicate).filter { Self.belongsToCalendar($0, calendar: calendar) }.map(snapshot)
        return Self.exactOccurrence(selected, candidates: candidates)
    }

    nonisolated static func exactOccurrence(_ selected: CalendarEventSnapshot, candidates: [CalendarEventSnapshot]) -> CalendarEventSnapshot? {
        guard selected.isRecurring == true,
              (selected.recurrenceDate != nil) != (selected.originalOccurrenceStart != nil) else { return nil }
        let matches = candidates.filter {
            $0.eventIdentifier == selected.eventIdentifier && $0.isRecurring == true &&
            $0.recurrenceDate == selected.recurrenceDate && $0.originalOccurrenceStart == selected.originalOccurrenceStart
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String {
        try await ensureFullAccess()
        let calendar = try writableCalendar(destination)
        guard let event = store.event(withIdentifier: identifier), Self.belongsToCalendar(event, calendar: calendar) else {
            throw CalendarDestinationError.calendarUnavailable
        }
        try apply(draft, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? event.calendarItemIdentifier
    }

    func update(_ draft: EventDraft, matching selected: CalendarEventSnapshot, in destination: CalendarDestination) async throws -> String {
        guard selected.isRecurring == true else { return try await update(draft, identifier: selected.eventIdentifier, in: destination) }
        try await ensureFullAccess()
        let event = try occurrenceEvent(matching: selected, in: destination)
        try apply(draft, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? event.calendarItemIdentifier
    }

    func delete(matching selected: CalendarEventSnapshot, in destination: CalendarDestination) async throws {
        guard selected.isRecurring == true else { return try await delete(identifier: selected.eventIdentifier, in: destination) }
        try await ensureFullAccess()
        let event = try occurrenceEvent(matching: selected, in: destination)
        try store.remove(event, span: .thisEvent, commit: true)
    }

    func delete(identifier: String, in destination: CalendarDestination) async throws {
        try await ensureFullAccess()
        let calendar = try writableCalendar(destination)
        guard let event = store.event(withIdentifier: identifier), Self.belongsToCalendar(event, calendar: calendar) else {
            throw CalendarDestinationError.calendarUnavailable
        }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    /// Finds the opened date. Saving uses this occurrence, so other dates in a series stay unchanged.
    private func occurrenceEvent(matching selected: CalendarEventSnapshot, in destination: CalendarDestination) throws -> EKEvent {
        let calendar = try writableCalendar(destination)
        guard selected.start.timeIntervalSince1970.isFinite, selected.end.timeIntervalSince1970.isFinite,
              selected.end > selected.start, selected.end.timeIntervalSince(selected.start) <= 366 * 86400 else {
            throw CalendarDestinationError.invalidDraft("The selected occurrence has an invalid date range.")
        }
        let predicate = store.predicateForEvents(withStart: selected.start.addingTimeInterval(-1),
                                                end: selected.end.addingTimeInterval(1), calendars: [calendar])
        let events = store.events(matching: predicate).filter { Self.belongsToCalendar($0, calendar: calendar) }
        let snapshots = events.map(snapshot)
        let chosen = Self.exactOccurrence(selected, candidates: snapshots) ?? {
            let same = snapshots.filter { $0.eventIdentifier == selected.eventIdentifier && $0.start == selected.start && $0.end == selected.end }
            return same.count == 1 ? same[0] : nil
        }()
        guard let chosen else { throw CalendarDestinationError.calendarUnavailable }
        let matches = events.filter {
            let item = snapshot($0)
            return item.eventIdentifier == chosen.eventIdentifier && item.start == chosen.start && item.end == chosen.end &&
            item.recurrenceDate == chosen.recurrenceDate && item.originalOccurrenceStart == chosen.originalOccurrenceStart
        }
        guard matches.count == 1, let event = matches.first else { throw CalendarDestinationError.calendarUnavailable }
        return event
    }

    private func apply(_ draft: EventDraft, to event: EKEvent) throws {
        let (start, end) = try validatedDates(draft)
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
    }

    private func readableCalendar(_ destination: CalendarDestination) throws -> EKCalendar {
        guard case .eventKit(let identifier) = destination, let calendar = store.calendar(withIdentifier: identifier) else {
            throw CalendarDestinationError.calendarUnavailable
        }
        return calendar
    }

    private func writableCalendar(_ destination: CalendarDestination) throws -> EKCalendar {
        let calendar = try readableCalendar(destination)
        guard calendar.allowsContentModifications else { throw CalendarDestinationError.calendarReadOnly }
        return calendar
    }

    /// Compare native identifiers, never titles or transport aliases.
    static func belongsToCalendar(_ event: EKEvent, calendar: EKCalendar) -> Bool {
        event.calendar?.calendarIdentifier == calendar.calendarIdentifier &&
        event.calendar?.source?.sourceIdentifier == calendar.source?.sourceIdentifier
    }

    private func snapshot(_ event: EKEvent) -> CalendarEventSnapshot {
        var result = CalendarEventSnapshot(eventIdentifier: event.eventIdentifier ?? event.calendarItemIdentifier,
                              title: event.title ?? "", start: event.startDate, end: event.endDate,
                              isAllDay: event.isAllDay, timeZone: event.timeZone?.identifier,
                              location: event.location, calendarName: event.calendar.title, url: event.url, notes: event.notes, externalEventIdentifier: event.calendarItemExternalIdentifier, isFree: event.availability == .notSupported ? nil : event.availability == .free)
        result.isRecurring = event.hasRecurrenceRules || event.isDetached || event.occurrenceDate != nil
        result.hasAttendees = event.hasAttendees
        result.modifiedAt = event.lastModifiedDate
        if let original = event.occurrenceDate {
            if event.isAllDay {
                // A detached exception may have changed from timed to all-day.
                // EventKit does not expose the original value type in that case.
                if !event.isDetached {
                    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                    // EventKit documents floating/all-day occurrenceDate in the
                    // process default timezone, even when event.timeZone is nil.
                    formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = NSTimeZone.default
                    formatter.dateFormat = "yyyy-MM-dd"
                    result.recurrenceDate = formatter.string(from: original)
                }
            } else if !event.isDetached, event.timeZone != nil {
                result.originalOccurrenceStart = original
            }
            // Detached exceptions do not expose the original all-day/timed type.
            // Leave their typed anchor unknown rather than reinterpret a floating date.
        }
        return result
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
