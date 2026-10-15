import Foundation

public struct SourceRegion: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}

public struct CalendarActionReceipt: Codable, Sendable {
    public var destinationID: String
    public var calendarName: String
    public var eventIdentifier: String
    public var savedAt: Date
}

public struct CalendarActionProposal: Codable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case pending, saving, added, updated, deleted, moved, failed }
    public enum Operation: String, Codable, Sendable { case create, update, delete, move }
    public var sourceDestinationID: String?
    public var sourceCalendarName: String?
    public var moveCopyReceipt: CalendarActionReceipt?
    public var moveDestinationBefore: EventDraft?
    public var operation: Operation = .create
    public var targetDestinationID: String?
    public var targetCalendarName: String?
    public var targetEventIdentifier: String?
    public var before: EventDraft?
    public var id: UUID { draft.id }
    public var draft: EventDraft
    public var isSelected: Bool
    public var state: State = .pending
    public var error: String?
    public var sourceCaptureID: UUID?
    public var receipt: CalendarActionReceipt?
    public var duplicateDestinationID: String?
    public var duplicateIdentifiers: [String] = []
    public var allowDuplicate = false
    /// Written before calling the calendar service to reconcile interrupted writes.
    public var attemptedDestinationID: String?
    public var attemptedCalendarName: String?

    public init(draft: EventDraft) { self.init(draft: draft, operation: .create) }

    public init(draft: EventDraft, operation: Operation, targetEventIdentifier: String? = nil, before: EventDraft? = nil) {
        self.draft = draft
        self.operation = operation
        self.targetEventIdentifier = targetEventIdentifier
        self.before = before
        isSelected = operation != .delete && CalendarDraftValidation.issues(draft).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case sourceDestinationID, sourceCalendarName, moveCopyReceipt, moveDestinationBefore
        case draft, operation, targetDestinationID, targetCalendarName, targetEventIdentifier, before, isSelected, state, error, sourceCaptureID, receipt
        case duplicateDestinationID, duplicateIdentifiers, allowDuplicate, attemptedDestinationID, attemptedCalendarName
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        draft = try values.decode(EventDraft.self, forKey: .draft)
        operation = try values.decodeIfPresent(Operation.self, forKey: .operation) ?? .create
        sourceDestinationID = try values.decodeIfPresent(String.self, forKey: .sourceDestinationID)
        sourceCalendarName = try values.decodeIfPresent(String.self, forKey: .sourceCalendarName)
        moveCopyReceipt = try values.decodeIfPresent(CalendarActionReceipt.self, forKey: .moveCopyReceipt)
        moveDestinationBefore = try values.decodeIfPresent(EventDraft.self, forKey: .moveDestinationBefore)
        targetDestinationID = try values.decodeIfPresent(String.self, forKey: .targetDestinationID)
        targetCalendarName = try values.decodeIfPresent(String.self, forKey: .targetCalendarName)
        targetEventIdentifier = try values.decodeIfPresent(String.self, forKey: .targetEventIdentifier)
        before = try values.decodeIfPresent(EventDraft.self, forKey: .before)
        isSelected = try values.decodeIfPresent(Bool.self, forKey: .isSelected) ?? (operation != .delete && CalendarDraftValidation.issues(draft).isEmpty)
        state = try values.decodeIfPresent(State.self, forKey: .state) ?? .pending
        error = try values.decodeIfPresent(String.self, forKey: .error)
        sourceCaptureID = try values.decodeIfPresent(UUID.self, forKey: .sourceCaptureID)
        receipt = try values.decodeIfPresent(CalendarActionReceipt.self, forKey: .receipt)
        duplicateDestinationID = try values.decodeIfPresent(String.self, forKey: .duplicateDestinationID)
        duplicateIdentifiers = try values.decodeIfPresent([String].self, forKey: .duplicateIdentifiers) ?? []
        allowDuplicate = try values.decodeIfPresent(Bool.self, forKey: .allowDuplicate) ?? false
        attemptedDestinationID = try values.decodeIfPresent(String.self, forKey: .attemptedDestinationID)
        attemptedCalendarName = try values.decodeIfPresent(String.self, forKey: .attemptedCalendarName)
    }
    public var isFinished: Bool { [.added, .updated, .deleted, .moved].contains(state) }
    public var isApprovable: Bool {
        guard !isFinished, state != .saving else { return false }
        if operation == .delete { return isSelected && !(targetEventIdentifier?.isEmpty ?? true) }
        return canAdd && (operation == .create || !(targetEventIdentifier?.isEmpty ?? true))
    }

    public var kind: String {
        let title = draft.title.lowercased()
        if title.range(of: #"\b(exam|test|quiz|midterm|final)\b"#, options: .regularExpression) != nil { return "Test" }
        if title.range(of: #"\b(assignment|homework|due|deadline|submission|project|essay|lab|report)\b"#, options: .regularExpression) != nil { return "Deadline" }
        return "Event"
    }
    public var issues: [String] { operation == .delete ? [] : CalendarDraftValidation.issues(draft) }
    public var canAdd: Bool {
        !isFinished && state != .saving && issues.isEmpty && (duplicateIdentifiers.isEmpty || allowDuplicate)
    }
    public var status: String {
        switch state {
        case .added: return "Added"
        case .updated: return "Updated"
        case .deleted: return "Deleted"
        case .moved: return "Moved"
        case .saving: return "Saving…"
        case .failed: return "Failed"
        case .pending:
            if !issues.isEmpty { return "Needs review" }
            if !duplicateIdentifiers.isEmpty && !allowDuplicate { return "Possible duplicate" }
            return isSelected ? "Ready" : "Skipped"
        }
    }
}

public enum CalendarDraftValidation {
    public static func sameEvent(_ lhs: EventDraft, _ rhs: EventDraft) -> Bool {
        lhs.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == rhs.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() &&
        lhs.startDate == rhs.startDate && lhs.endDate == rhs.endDate && lhs.isAllDay == rhs.isAllDay
    }

    public static func issues(_ draft: EventDraft) -> [String] {
        var issues = draft.ambiguities.map { issue in
            switch issue {
            case .invalidURL: return "Enter a valid http or https link."
            case .missingTitle: return "Enter a title."
            case .missingDate: return "Choose a date."
            case .missingYear: return "Confirm the year."
            case .missingTime: return "Choose a time or confirm all-day."
            case .ambiguousDate: return "Confirm the date."
            case .ambiguousTime: return "Confirm the time."
            case .ambiguousTimeZone: return "Choose a valid timezone."
            case .missingEndTime: return "Confirm the event duration."
            case .multipleEvents: return "Multiple dates were found; verify which one belongs to this item."
            }
        }
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Enter a title.") }
        if draft.startDate == nil { issues.append("Choose a date and time.") }
        if draft.endDate == nil { issues.append("Choose an end date and time.") }
        if let start = draft.startDate, let end = draft.endDate, end <= start { issues.append("The end must be after the start.") }
        if let url = draft.url, !["http", "https"].contains(url.scheme?.lowercased() ?? "") { issues.append("Enter a valid http or https link.") }
        if let zone = draft.timeZoneIdentifier, TimeZone(identifier: zone) == nil { issues.append("Choose a valid timezone.") }
        return Array(Set(issues)).sorted()
    }

    public static func calendar(for draft: EventDraft) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = draft.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        return calendar
    }

    public static func setAllDay(_ draft: inout EventDraft, enabled: Bool) {
        draft.isAllDay = enabled
        if enabled, let start = draft.startDate {
            let calendar = calendar(for: draft)
            draft.startDate = calendar.startOfDay(for: start)
            draft.endDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
            draft.ambiguities.removeAll { [.missingTime, .ambiguousTime, .missingEndTime].contains($0) }
        } else if let start = draft.startDate {
            draft.endDate = start.addingTimeInterval(3600)
            if !draft.ambiguities.contains(.missingTime) { draft.ambiguities.append(.missingTime) }
            if !draft.ambiguities.contains(.missingEndTime) { draft.ambiguities.append(.missingEndTime) }
        }
    }
}
