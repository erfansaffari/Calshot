import Foundation
import Combine

@MainActor
final class CalendarActionCoordinator: ObservableObject {
    @Published private(set) var proposals: [CalendarActionProposal] = []
    @Published private(set) var isExecuting = false
    @Published private(set) var isCheckingDuplicates = false
    @Published private(set) var stopRequested = false
    @Published var message: String?
    var onExecutionFinished: (([CalendarActionProposal]) -> Void)?
    @Published var approvalScope: Set<UUID>?
    var persist: (([CalendarActionProposal]) throws -> Void)?
    private let service: any CalendarDestinationService
    private var revision = UUID()
    private var checkedDestinationID: String?

    init(service: any CalendarDestinationService) { self.service = service }

    var selectedCount: Int { proposals.filter { $0.isSelected && !$0.isFinished && isInApprovalScope($0.id) }.count }
    var unresolvedCount: Int { proposals.filter { !$0.issues.isEmpty && !$0.isFinished && isInApprovalScope($0.id) }.count }
    var addedCount: Int { proposals.filter { $0.state == .added }.count }
    var updatedCount: Int { proposals.filter { $0.state == .updated }.count }
    var deletedCount: Int { proposals.filter { $0.state == .deleted }.count }
    var movedCount: Int { proposals.filter { $0.state == .moved }.count }
    var approvalSummary: String {
        let selected = proposals.filter { $0.isSelected && !$0.isFinished && isInApprovalScope($0.id) }
        return "Add \(selected.filter { $0.operation == .create }.count) · Change \(selected.filter { $0.operation == .update }.count) · Remove \(selected.filter { $0.operation == .delete }.count) · Move \(selected.filter { $0.operation == .move }.count)"
    }
    var canApprove: Bool {
        !isExecuting && !isCheckingDuplicates && selectedCount > 0 &&
        proposals.filter { $0.isSelected && !$0.isFinished && isInApprovalScope($0.id) }.allSatisfy(\.isApprovable)
    }

    func isInApprovalScope(_ id: UUID) -> Bool { approvalScope?.contains(id) ?? true }

    func needsDuplicateCheck(destinationID: String) -> Bool { checkedDestinationID != destinationID }

    func replace(with items: [CalendarActionProposal]) {
        guard !isExecuting else { return }
        revision = UUID()
        checkedDestinationID = nil
        isCheckingDuplicates = false
        approvalScope = nil
        proposals = items.sorted { ($0.draft.startDate ?? .distantFuture) < ($1.draft.startDate ?? .distantFuture) }
        message = nil
        stopRequested = false
        refreshBatchDuplicates()
    }

    func update(_ id: UUID, change: (inout CalendarActionProposal) -> Void) {
        guard !isExecuting, let index = proposals.firstIndex(where: { $0.id == id }),
              !proposals[index].isFinished, proposals[index].state != .saving else { return }
        guard isInApprovalScope(id) else { return }
        change(&proposals[index])
        revision = UUID()
        isCheckingDuplicates = false
        refreshBatchDuplicates()
        storeChanges()
    }

    func edit(_ id: UUID, change: (inout EventDraft) -> Void) {
        checkedDestinationID = nil
        update(id) { item in
            let old = item.draft
            change(&item.draft)
            if item.operation == .update {
                var fields = Set(item.draft.changedFieldNames ?? [])
                if old.title != item.draft.title { fields.insert("title") }
                if old.startDate != item.draft.startDate { fields.insert("startTime") }
                if old.endDate != item.draft.endDate { fields.insert("endTime") }
                if old.isAllDay != item.draft.isAllDay { fields.insert("allDay") }
                if old.timeZoneIdentifier != item.draft.timeZoneIdentifier { fields.insert("timeZone") }
                if old.location != item.draft.location { fields.insert("location") }
                if old.url != item.draft.url { fields.insert("url") }
                if old.notes != item.draft.notes { fields.insert("notes") }
                item.draft.changedFieldNames = fields.sorted()
            }
            item.duplicateIdentifiers = []
            item.allowDuplicate = false
            item.error = nil
            item.state = .pending
        }
    }

    func selectReady() {
        guard !isExecuting else { return }
        for index in proposals.indices {
            proposals[index].isSelected = isInApprovalScope(proposals[index].id) && proposals[index].operation != .delete && proposals[index].canAdd
        }
        refreshBatchDuplicates()
        storeChanges()
    }

    func skipAll() {
        guard !isExecuting else { return }
        for index in proposals.indices { proposals[index].isSelected = false }
        refreshBatchDuplicates()
        storeChanges()
    }

    func addManual() {
        guard !isExecuting else { return }
        let draft = EventDraft(title: "", startDate: nil, endDate: nil, isAllDay: false,
                               timeZoneIdentifier: TimeZone.current.identifier, location: nil, url: nil,
                               notes: nil, sourceText: "Manually entered", confidence: 0,
                               ambiguities: [.missingDate, .missingTime, .missingEndTime])
        proposals.append(CalendarActionProposal(draft: draft))
        isCheckingDuplicates = false
        checkedDestinationID = nil
        revision = UUID()
        storeChanges()
    }

    func applyPrefix(_ prefix: String) {
        let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, !isExecuting else { return }
        for index in proposals.indices where isInApprovalScope(proposals[index].id) && proposals[index].operation != .delete && (proposals[index].state == .pending || proposals[index].state == .failed) {
            if !proposals[index].draft.title.hasPrefix(prefix + " · ") {
                proposals[index].draft.title = prefix + " · " + proposals[index].draft.title
                proposals[index].duplicateIdentifiers = []
                proposals[index].allowDuplicate = false
            }
        }
        isCheckingDuplicates = false
        revision = UUID(); checkedDestinationID = nil
        storeChanges()
    }

    func applyYear(_ year: Int) {
        guard (1900...2200).contains(year), !isExecuting else { return }
        for index in proposals.indices where isInApprovalScope(proposals[index].id) && proposals[index].operation != .delete && (proposals[index].state == .pending || proposals[index].state == .failed) {
            guard proposals[index].draft.ambiguities.contains(.missingYear), let start = proposals[index].draft.startDate else { continue }
            let calendar = CalendarDraftValidation.calendar(for: proposals[index].draft)
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
            parts.year = year
            guard let changed = calendar.date(from: parts), calendar.component(.month, from: changed) == parts.month,
                  calendar.component(.day, from: changed) == parts.day else { continue }
            let duration = proposals[index].draft.endDate?.timeIntervalSince(start)
            proposals[index].draft.startDate = changed
            if proposals[index].draft.isAllDay {
                proposals[index].draft.endDate = calendar.date(byAdding: .day, value: 1, to: changed)
            } else { proposals[index].draft.endDate = duration.map { changed.addingTimeInterval($0) } }
            proposals[index].draft.ambiguities.removeAll { $0 == .missingYear }
            proposals[index].duplicateIdentifiers = []
            proposals[index].allowDuplicate = false
        }
        isCheckingDuplicates = false
        revision = UUID(); checkedDestinationID = nil
        storeChanges()
    }

    func confirmDateOnlyDeadlines() {
        guard !isExecuting else { return }
        for index in proposals.indices where isInApprovalScope(proposals[index].id) && proposals[index].operation != .delete && (proposals[index].state == .pending || proposals[index].state == .failed) {
            if proposals[index].kind == "Deadline", proposals[index].draft.ambiguities.contains(.missingTime) {
                CalendarDraftValidation.setAllDay(&proposals[index].draft, enabled: true)
                proposals[index].duplicateIdentifiers = []
                proposals[index].allowDuplicate = false
            }
        }
        isCheckingDuplicates = false
        revision = UUID(); checkedDestinationID = nil
        storeChanges()
    }

    func checkDuplicates(destinationID: String) async {
        guard !isExecuting else { return }
        let token = UUID()
        checkedDestinationID = nil
        message = nil
        revision = token
        isCheckingDuplicates = true
        defer { if revision == token { isCheckingDuplicates = false } }
        do {
            for item in proposals where !item.isFinished {
                if item.operation == .move {
                    if item.state == .saving { try await recoverMove(item) }
                    guard revision == token else { return }
                    continue
                }
                if item.operation != .create {
                    guard let index = proposals.firstIndex(where: { $0.id == item.id }) else { continue }
                    if item.state == .saving {
                        let originalDestination = item.attemptedDestinationID ?? item.targetDestinationID ?? destinationID
                        guard let target = item.targetEventIdentifier, !target.isEmpty else {
                            proposals[index].state = .failed
                            proposals[index].isSelected = false
                            proposals[index].error = "The interrupted change has no target identifier."
                            continue
                        }
                        let existing = try await resolvedEvent(item, identifier: target, in: .resolve(identifier: originalDestination))
                        guard revision == token else { return }
                        let recovered = item.operation == .delete ? existing == nil : existing.map { Self.exactDraft($0.draft, item.draft) } == true
                        proposals[index].state = recovered ? (item.operation == .delete ? .deleted : .updated) : .failed
                        proposals[index].isSelected = false
                        if recovered {
                            proposals[index].receipt = CalendarActionReceipt(destinationID: originalDestination, calendarName: item.attemptedCalendarName ?? "Calendar", eventIdentifier: item.targetEventIdentifier ?? "", savedAt: .now)
                            proposals[index].error = nil
                        } else { proposals[index].error = "The interrupted change could not be confirmed. Review before retrying." }
                    }
                    continue
                }
                let matches = try await service.matchingEvents(item.draft, in: .resolve(identifier: destinationID))
                guard revision == token, !isExecuting,
                      let index = proposals.firstIndex(where: { $0.id == item.id }) else { return }
                let precedingDuplicate = proposals.prefix(index).contains { $0.operation == .create && Self.sameEvent($0.draft, item.draft) && ($0.isSelected || $0.state == .added) }
                if proposals[index].duplicateDestinationID != destinationID { proposals[index].allowDuplicate = false }
                proposals[index].duplicateDestinationID = destinationID
                proposals[index].duplicateIdentifiers = matches + (precedingDuplicate ? ["batch"] : [])
                // A durable pre-write journal entry must be reconciled before it can be retried.
                if item.state == .saving {
                    let originalDestination = item.attemptedDestinationID ?? item.targetDestinationID ?? destinationID
                    let originalMatches = originalDestination == destinationID ? matches :
                        try await service.matchingEvents(item.draft, in: .resolve(identifier: originalDestination))
                    guard revision == token else { return }
                    if !item.allowDuplicate, originalMatches.count == 1, let identifier = originalMatches.first {
                        proposals[index].state = .added
                        proposals[index].isSelected = false
                        proposals[index].receipt = CalendarActionReceipt(destinationID: originalDestination,
                            calendarName: item.attemptedCalendarName ?? "Calendar", eventIdentifier: identifier, savedAt: .now)
                        proposals[index].error = "Recovered an interrupted save by matching the calendar event."
                    } else {
                        proposals[index].state = .failed
                        proposals[index].isSelected = false
                        proposals[index].error = originalMatches.isEmpty ? "Interrupted before a matching event was found. Review before retrying." :
                            "Several matching events exist after an interrupted save. Check your calendar before retrying."
                    }
                }
            }
            guard revision == token else { return }
            checkedDestinationID = destinationID
            try persist?(proposals)
        } catch {
            guard revision == token else { return }
            checkedDestinationID = nil
            message = "Couldn’t check calendar items: \(error.localizedDescription)"
        }
    }

    func requestStop() { stopRequested = true }

    func execute(destinationID: String, calendarName: String) async {
        guard canApprove else { return }
        if checkedDestinationID != destinationID {
            await checkDuplicates(destinationID: destinationID)
            message = "Calendar checked. Review the results, then approve the selected items."
            return
        }
        // Freeze the exact approved drafts. All edits and capture replacement are disabled until done.
        let snapshot = proposals.filter { $0.isSelected && !$0.isFinished && isInApprovalScope($0.id) }
        isExecuting = true
        stopRequested = false
        message = nil
        defer { isExecuting = false; onExecutionFinished?(proposals) }
        for item in snapshot {
            if stopRequested { break }
            guard let index = proposals.firstIndex(where: { $0.id == item.id }) else { break }
            do {
                if item.operation == .move {
                    try await executeMove(item, index: index)
                    continue
                }
                let writeDestinationID = item.targetDestinationID ?? destinationID
                let writeCalendarName = item.targetCalendarName ?? calendarName
                let destination = CalendarDestination.resolve(identifier: writeDestinationID)
                if item.operation == .create {
                    let matches = try await service.matchingEvents(item.draft, in: destination)
                    if stopRequested { break }
                    if !matches.isEmpty && !item.allowDuplicate {
                        proposals[index].duplicateIdentifiers = matches
                        proposals[index].error = "A matching event appeared before saving. Review the possible duplicate."
                        try persist?(proposals)
                        continue
                    }
                    let batchDuplicate = proposals.contains { other in
                        other.id != item.id && other.state == .added && other.receipt?.destinationID == destinationID && Self.sameEvent(other.draft, item.draft)
                    }
                    if batchDuplicate && !item.allowDuplicate {
                        proposals[index].duplicateIdentifiers = ["batch"]
                        try persist?(proposals)
                        continue
                    }
                } else {
                    guard let identifier = item.targetEventIdentifier,
                          let current = try await resolvedEvent(item, identifier: identifier, in: destination) else {
                        throw CalendarDestinationError.calendarUnavailable
                    }
                    guard let before = item.before, Self.exactDraft(current.draft, before) else {
                        throw CalendarDestinationError.invalidDraft("the event changed after review; search again before approving")
                    }
                    if stopRequested { break }
                }
                proposals[index].state = .saving
                proposals[index].attemptedDestinationID = writeDestinationID
                proposals[index].attemptedCalendarName = writeCalendarName
                try persist?(proposals)
                let identifier: String
                switch item.operation {
                case .move: throw CalendarDestinationError.invalidDraft("transfer must use the move journal")
                case .create: identifier = try await service.save(item.draft, to: destination)
                case .update:
                    if let selected = item.targetOccurrence {
                        identifier = try await service.update(item.draft, matching: selected, in: destination)
                    } else {
                        identifier = try await service.update(item.draft, identifier: item.targetEventIdentifier!, in: destination)
                    }
                case .delete:
                    identifier = item.targetEventIdentifier!
                    if let selected = item.targetOccurrence {
                        try await service.delete(matching: selected, in: destination)
                    } else {
                        try await service.delete(identifier: identifier, in: destination)
                    }
                }
                proposals[index].receipt = CalendarActionReceipt(destinationID: writeDestinationID, calendarName: writeCalendarName,
                                                                eventIdentifier: identifier, savedAt: .now)
                proposals[index].state = item.operation == .create ? .added : (item.operation == .update ? .updated : .deleted)
                proposals[index].isSelected = false
                proposals[index].error = nil
                try persist?(proposals)
            } catch {
                // Preserve a successful calendar write even when its local receipt could not be persisted.
                if !proposals[index].isFinished { proposals[index].state = .failed }
                proposals[index].error = error.localizedDescription
                do { try persist?(proposals) } catch {
                    message = "Stopped because capture history could not be saved. Added items remain in your calendar. \(error.localizedDescription)"
                    stopRequested = true
                }
            }
        }
        let failed = proposals.filter { $0.state == .failed }.count
        message = message ?? "\(addedCount) added · \(updatedCount) updated · \(deletedCount) deleted · \(movedCount) moved · \(failed) failed\(stopRequested ? " · Remaining items stopped" : "")"
    }

    private func resolvedEvent(_ item: CalendarActionProposal, identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? {
        if let selected = item.targetOccurrence {
            return try await service.event(matching: selected, in: destination)
        }
        return try await service.event(identifier: identifier, in: destination)
    }

    private func executeMove(_ item: CalendarActionProposal, index: Int) async throws {
        guard let sourceID = item.sourceDestinationID, let destinationID = item.targetDestinationID,
              let target = item.targetEventIdentifier, let before = item.before, sourceID != destinationID else {
            throw CalendarDestinationError.invalidDraft("transfer needs distinct source and destination calendars")
        }
        let source = CalendarDestination.resolve(identifier: sourceID)
        let destination = CalendarDestination.resolve(identifier: destinationID)
        guard let current = try await service.event(identifier: target, in: source), Self.exactDraft(current.draft, before) else {
            throw CalendarDestinationError.invalidDraft("the original event changed or disappeared; search again")
        }
        proposals[index].state = .saving
        proposals[index].attemptedDestinationID = destinationID
        proposals[index].attemptedCalendarName = item.targetCalendarName
        try persist?(proposals)
        if proposals[index].moveCopyReceipt == nil {
            let matches = try await service.matchingEvents(item.draft, in: destination)
            guard matches.isEmpty else { throw CalendarDestinationError.invalidDraft("a destination copy already exists; search and explicitly reuse that event") }
            let copied = try await service.save(item.draft, to: destination)
            proposals[index].moveCopyReceipt = CalendarActionReceipt(destinationID: destinationID,
                calendarName: item.targetCalendarName ?? "Calendar", eventIdentifier: copied, savedAt: .now)
            // The copied identifier is durable before any original is removed.
            try persist?(proposals)
        }
        guard let copy = proposals[index].moveCopyReceipt,
              let verified = try await service.event(identifier: copy.eventIdentifier, in: destination),
              CalendarDraftValidation.sameEvent(verified.draft, item.draft) else {
            throw CalendarDestinationError.invalidDraft("the destination copy could not be verified; the original is retained")
        }
        if !Self.exactDraft(verified.draft, item.draft) {
            guard let reviewedCopy = item.moveDestinationBefore, Self.exactDraft(verified.draft, reviewedCopy) else {
                throw CalendarDestinationError.invalidDraft("the destination copy changed after review; the original is retained")
            }
            var corrected = item.draft
            var fields: [String] = []
            if verified.timeZone != corrected.timeZoneIdentifier { fields.append("timeZone") }
            if verified.location != corrected.location { fields.append("location") }
            if verified.notes != corrected.notes { fields.append("notes") }
            if verified.url != corrected.url { fields.append("url") }
            corrected.changedFieldNames = fields
            _ = try await service.update(corrected, identifier: copy.eventIdentifier, in: destination)
            guard let updated = try await service.event(identifier: copy.eventIdentifier, in: destination), Self.exactDraft(updated.draft, item.draft) else {
                throw CalendarDestinationError.invalidDraft("destination details could not be verified; the original is retained")
            }
        }
        if stopRequested { proposals[index].state = .failed; proposals[index].error = "Copy saved; original retained after Stop."; try persist?(proposals); return }
        guard let latest = try await service.event(identifier: target, in: source), Self.exactDraft(latest.draft, before) else {
            throw CalendarDestinationError.invalidDraft("the original changed while copying; it was retained")
        }
        try await service.delete(identifier: target, in: source)
        proposals[index].receipt = copy
        proposals[index].state = .moved
        proposals[index].isSelected = false
        proposals[index].error = nil
        try persist?(proposals)
    }

    private func recoverMove(_ item: CalendarActionProposal) async throws {
        guard let index = proposals.firstIndex(where: { $0.id == item.id }), let sourceID = item.sourceDestinationID,
              let target = item.targetEventIdentifier, let destinationID = item.targetDestinationID else { return }
        let destination = CalendarDestination.resolve(identifier: destinationID)
        var copy = item.moveCopyReceipt
        if copy == nil {
            let matches = try await service.matchingEvents(item.draft, in: destination)
            var exact: [String] = []
            for id in matches {
                if let event = try await service.event(identifier: id, in: destination), Self.exactDraft(event.draft, item.draft) { exact.append(id) }
            }
            if exact.count == 1 { copy = CalendarActionReceipt(destinationID: destinationID, calendarName: item.targetCalendarName ?? "Calendar", eventIdentifier: exact[0], savedAt: .now) }
        }
        let original = try await service.event(identifier: target, in: .resolve(identifier: sourceID))
        let verifiedCopy: Bool
        if let copy, let event = try await service.event(identifier: copy.eventIdentifier, in: destination) {
            verifiedCopy = Self.exactDraft(event.draft, item.draft)
        } else { verifiedCopy = false }
        proposals[index].moveCopyReceipt = copy
        proposals[index].isSelected = false
        if original == nil && verifiedCopy {
            proposals[index].state = .moved; proposals[index].receipt = copy; proposals[index].error = nil
        } else {
            proposals[index].state = .failed
            proposals[index].error = verifiedCopy ? "Destination copy saved; original retained. Approve to finish moving." : "The interrupted transfer could not be confirmed. Review both calendars."
        }
    }

    static func exactDraft(_ lhs: EventDraft, _ rhs: EventDraft) -> Bool {
        lhs.title == rhs.title && lhs.startDate == rhs.startDate && lhs.endDate == rhs.endDate && lhs.isAllDay == rhs.isAllDay && lhs.timeZoneIdentifier == rhs.timeZoneIdentifier && lhs.location == rhs.location && lhs.url == rhs.url && lhs.notes == rhs.notes
    }

    static func sameEvent(_ lhs: EventDraft, _ rhs: EventDraft) -> Bool { CalendarDraftValidation.sameEvent(lhs, rhs) }

    private func refreshBatchDuplicates() {
        for index in proposals.indices where !proposals[index].isFinished && proposals[index].operation == .create {
            proposals[index].duplicateIdentifiers.removeAll { $0 == "batch" }
            if proposals.prefix(index).contains(where: {  $0.operation == .create && ($0.isSelected || $0.state == .added) && Self.sameEvent($0.draft, proposals[index].draft) }) {
                proposals[index].duplicateIdentifiers.append("batch")
            }
        }
    }

    private func storeChanges() {
        do { try persist?(proposals) }
        catch { message = "Couldn’t save your edits: \(error.localizedDescription)" }
    }
}

/// One change the user typed and confirmed in Calendar or Tasks. There is no agent, conversation or
/// History record, but the write runs through a private coordinator: it re-reads the event, rejects a
/// stale change, journals the row before calling the provider and returns the provider receipt.
@MainActor
final class DirectCalendarWriter {
    /// Shared with the WebUI, which offers "Add anyway" only for this error.
    static let duplicatePrefix = "A matching event is already in "
    enum WriteError: LocalizedError {
        case duplicate(calendarName: String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .duplicate(let name): return DirectCalendarWriter.duplicatePrefix + name + "."
            case .failed(let message): return message
            }
        }
    }
    private let service: any CalendarDestinationService
    private let journalURL: () -> URL
    private(set) var isWriting = false

    init(service: any CalendarDestinationService, journalURL: @escaping () -> URL) {
        self.service = service; self.journalURL = journalURL
    }

    /// Writes exactly this row and returns it with its receipt. Nothing is written when the event
    /// changed, the calendar is unavailable, or a matching event exists without `allowDuplicate`.
    func apply(_ proposal: CalendarActionProposal, destinationID: String, calendarName: String) async throws -> CalendarActionProposal {
        guard !isWriting else { throw WriteError.failed("Another calendar change is still saving.") }
        isWriting = true
        defer { isWriting = false }
        let url = journalURL()
        var row = proposal
        row.isSelected = true
        let coordinator = CalendarActionCoordinator(service: service)
        coordinator.persist = { rows in try Self.writeJournal(rows, to: url) }
        coordinator.replace(with: [row])
        await coordinator.checkDuplicates(destinationID: destinationID)
        if let message = coordinator.message { throw WriteError.failed(message) }
        // The check resets the choice for a new destination; apply "Add anyway" after it, as Assistant does.
        if proposal.allowDuplicate { coordinator.update(row.id) { $0.allowDuplicate = true; $0.isSelected = true } }
        guard let checked = coordinator.proposals.first else { throw WriteError.failed("This change is no longer available.") }
        if checked.operation == .create, !checked.duplicateIdentifiers.isEmpty, !checked.allowDuplicate {
            throw WriteError.duplicate(calendarName: calendarName)
        }
        guard coordinator.canApprove else {
            throw WriteError.failed(checked.issues.first ?? "This change can’t be saved. Check its details and try again.")
        }
        await coordinator.execute(destinationID: destinationID, calendarName: calendarName)
        guard let result = coordinator.proposals.first, result.isFinished, result.receipt != nil else {
            let failed = coordinator.proposals.first
            throw WriteError.failed(failed?.error.map { "Couldn’t save to \(calendarName): \($0)" } ?? coordinator.message ?? "Couldn’t save to \(calendarName).")
        }
        return result
    }

    /// Confirms changes interrupted mid-write (for example by a crash or quit). Never retries them.
    /// Rows that still can't be checked stay in the journal for the next attempt.
    func recoverInterrupted() async -> [CalendarActionProposal] {
        let url = journalURL()
        guard !isWriting, let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([CalendarActionProposal].self, from: data), !rows.isEmpty else { return [] }
        isWriting = true
        defer { isWriting = false }
        var settled: [CalendarActionProposal] = [], unresolved: [CalendarActionProposal] = []
        for row in rows {
            let coordinator = CalendarActionCoordinator(service: service)
            coordinator.replace(with: [row])
            await coordinator.checkDuplicates(destinationID: row.attemptedDestinationID ?? row.targetDestinationID ?? "")
            let result = coordinator.proposals.first ?? row
            if result.state == .saving { unresolved.append(row) } else { settled.append(result) }
        }
        try? Self.writeJournal(unresolved, to: url)
        return settled
    }

    private static func writeJournal(_ rows: [CalendarActionProposal], to url: URL) throws {
        let pending = rows.filter { $0.state == .saving }
        let files = FileManager.default
        guard !pending.isEmpty else {
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            return
        }
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(pending).write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
