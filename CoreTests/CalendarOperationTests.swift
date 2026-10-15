import XCTest
@testable import Calshot

private actor OperationCalendarService: CalendarDestinationService {
    var current: CalendarEventSnapshot?
    var writeCount = 0
    var lookupDestinations: [String] = []
    init(_ current: CalendarEventSnapshot?) { self.current = current }
    func availableDestinations() async throws -> [CalendarDestinationInfo] { [] }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] { [] }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String { writeCount += 1; return "new" }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? {
        lookupDestinations.append(destination.id)
        return current?.eventIdentifier == identifier ? current : nil
    }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String {
        writeCount += 1
        current = CalendarEventSnapshot(eventIdentifier: identifier, title: draft.title, start: draft.startDate!, end: draft.endDate!,
                                        isAllDay: draft.isAllDay, timeZone: draft.timeZoneIdentifier, location: draft.location,
                                        calendarName: "School", url: draft.url, notes: draft.notes)
        return identifier
    }
    func delete(identifier: String, in destination: CalendarDestination) async throws { writeCount += 1; current = nil }
    func count() -> Int { writeCount }
    func lookups() -> [String] { lookupDestinations }
}

@MainActor
final class CalendarOperationTests: XCTestCase {
    private func event(title: String = "Midterm") -> CalendarEventSnapshot {
        CalendarEventSnapshot(eventIdentifier: "midterm", title: title, start: Date(timeIntervalSince1970: 1_800_000_000),
                              end: Date(timeIntervalSince1970: 1_800_003_600), isAllDay: false, timeZone: "America/Toronto",
                              location: "Room 4", calendarName: "School", url: nil, notes: "Bring ID")
    }

    func testUpdateUsesOriginalCalendarEvenWhenDefaultChanges() async {
        let existing = event()
        let service = OperationCalendarService(existing)
        var changed = existing.draft; changed.title = "Moved midterm"
        var item = CalendarActionProposal(draft: changed, operation: .update, targetEventIdentifier: "midterm", before: existing.draft)
        item.targetDestinationID = "original"; item.targetCalendarName = "Original school calendar"
        let coordinator = CalendarActionCoordinator(service: service)
        coordinator.replace(with: [item])
        await coordinator.checkDuplicates(destinationID: "new-default")
        await coordinator.execute(destinationID: "new-default", calendarName: "Different calendar")
        let lookups = await service.lookups()
        XCTAssertEqual(lookups, ["eventkit:original"])
        XCTAssertEqual(coordinator.proposals.first?.receipt?.destinationID, "original")
        XCTAssertEqual(coordinator.proposals.first?.receipt?.calendarName, "Original school calendar")
    }

    func testOldProposalDecodesAsCreate() throws {
        let encoded = try JSONEncoder().encode(CalendarActionProposal(draft: event().draft))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "operation")
        let restored = try JSONDecoder().decode(CalendarActionProposal.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.operation, .create)
        XCTAssertNil(restored.before)
        XCTAssertTrue(restored.isSelected)
    }

    func testDeleteStartsUncheckedAndRequiresSelection() async {
        let existing = event()
        let service = OperationCalendarService(existing)
        let proposal = CalendarActionProposal(draft: existing.draft, operation: .delete, targetEventIdentifier: existing.eventIdentifier, before: existing.draft)
        let coordinator = CalendarActionCoordinator(service: service)
        coordinator.replace(with: [proposal])
        XCTAssertFalse(coordinator.canApprove)
        coordinator.selectReady()
        XCTAssertFalse(coordinator.canApprove) // Bulk selection never opts in to removal.
        coordinator.update(proposal.id) { $0.isSelected = true }
        await coordinator.checkDuplicates(destinationID: "school")
        await coordinator.execute(destinationID: "school", calendarName: "School")
        XCTAssertEqual(coordinator.deletedCount, 1)
        XCTAssertEqual(coordinator.proposals.first?.receipt?.eventIdentifier, "midterm")
        XCTAssertFalse(coordinator.canApprove)
    }

    func testInterruptedSuccessfulUpdateRecoversByIdentifierAndExactValues() async {
        let before = event()
        let after = event(title: "Rescheduled Midterm")
        let service = OperationCalendarService(after)
        var proposal = CalendarActionProposal(draft: after.draft, operation: .update, targetEventIdentifier: "midterm", before: before.draft)
        proposal.state = .saving
        proposal.attemptedDestinationID = "school"
        let coordinator = CalendarActionCoordinator(service: service)
        coordinator.replace(with: [proposal])
        await coordinator.checkDuplicates(destinationID: "school")
        XCTAssertEqual(coordinator.updatedCount, 1)
        XCTAssertEqual(coordinator.proposals.first?.receipt?.eventIdentifier, "midterm")
        await coordinator.execute(destinationID: "school", calendarName: "School")
        let count = await service.count()
        XCTAssertEqual(count, 0)
    }

    func testUpdateWritesMergedDraftAndTerminalReceipt() async {
        let existing = event()
        let service = OperationCalendarService(existing)
        var changed = existing.draft
        changed.startDate = changed.startDate!.addingTimeInterval(86400)
        changed.endDate = changed.endDate!.addingTimeInterval(86400)
        let coordinator = CalendarActionCoordinator(service: service)
        coordinator.replace(with: [CalendarActionProposal(draft: changed, operation: .update, targetEventIdentifier: "midterm", before: existing.draft)])
        await coordinator.checkDuplicates(destinationID: "school")
        await coordinator.execute(destinationID: "school", calendarName: "School")
        XCTAssertEqual(coordinator.updatedCount, 1)
        let updated = try? await service.event(identifier: "midterm", in: .eventKit(calendarIdentifier: "school"))
        XCTAssertEqual(updated?.start, changed.startDate)
        XCTAssertEqual(updated?.location, "Room 4")
        XCTAssertEqual(updated?.notes, "Bring ID")
        await coordinator.execute(destinationID: "school", calendarName: "School")
        let count = await service.count()
        XCTAssertEqual(count, 1)
    }

    func testInterruptedUpdateDoesNotRecoverDifferentValues() async {
        let existing = event()
        var proposal = CalendarActionProposal(draft: event(title: "Requested title").draft, operation: .update,
                                               targetEventIdentifier: "midterm", before: existing.draft)
        proposal.state = .saving
        proposal.attemptedDestinationID = "school"
        let coordinator = CalendarActionCoordinator(service: OperationCalendarService(existing))
        coordinator.replace(with: [proposal])
        await coordinator.checkDuplicates(destinationID: "school")
        XCTAssertEqual(coordinator.updatedCount, 0)
        XCTAssertEqual(coordinator.proposals.first?.state, .failed)
        XCTAssertFalse(coordinator.proposals.first!.isSelected)
    }

    func testRecoveryUsesOriginalAttemptedCalendarAfterDestinationChanges() async {
        let existing = event()
        let service = OperationCalendarService(existing)
        var proposal = CalendarActionProposal(draft: existing.draft, operation: .update, targetEventIdentifier: "midterm", before: existing.draft)
        proposal.state = .saving
        proposal.attemptedDestinationID = "school"
        proposal.attemptedCalendarName = "School"
        let coordinator = CalendarActionCoordinator(service: service)
        coordinator.replace(with: [proposal])
        await coordinator.checkDuplicates(destinationID: "personal")
        let lookups = await service.lookups()
        XCTAssertEqual(lookups, ["eventkit:school"])
        XCTAssertEqual(coordinator.proposals.first?.receipt?.destinationID, "school")
        XCTAssertEqual(coordinator.proposals.first?.receipt?.calendarName, "School")
        XCTAssertEqual(coordinator.updatedCount, 1)
    }

    func testInterruptedDeleteRecoversAbsence() async {
        let existing = event()
        var proposal = CalendarActionProposal(draft: existing.draft, operation: .delete, targetEventIdentifier: "midterm", before: existing.draft)
        proposal.state = .saving
        proposal.attemptedDestinationID = "school"
        let coordinator = CalendarActionCoordinator(service: OperationCalendarService(nil))
        coordinator.replace(with: [proposal])
        await coordinator.checkDuplicates(destinationID: "school")
        XCTAssertEqual(coordinator.deletedCount, 1)
    }

    func testChangedTargetFailsWithoutWritingAndCompletionOnlyRunsAfterExecution() async {
        let original = event()
        let service = OperationCalendarService(event(title: "Changed outside Calshot"))
        var draft = original.draft
        draft.title = "New title"
        let coordinator = CalendarActionCoordinator(service: service)
        coordinator.replace(with: [CalendarActionProposal(draft: draft, operation: .update, targetEventIdentifier: "midterm", before: original.draft)])
        var completions = 0
        coordinator.onExecutionFinished = { _ in completions += 1 }
        await coordinator.execute(destinationID: "school", calendarName: "School")
        XCTAssertEqual(completions, 0)
        await coordinator.execute(destinationID: "school", calendarName: "School")
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(coordinator.proposals.first?.state, .failed)
        let count = await service.count()
        XCTAssertEqual(count, 0)
    }
}

private actor TransferCalendarFixture: CalendarDestinationService {
    var storage: [String: [CalendarEventSnapshot]]
    var writes: [String] = []
    var failCopy = false
    var failDelete = false
    init(_ originals: [CalendarEventSnapshot], copies: [CalendarEventSnapshot] = []) {
        storage = ["eventkit:source": originals, "eventkit:destination": copies]
    }
    func availableDestinations() async throws -> [CalendarDestinationInfo] { [] }
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] { storage[destination.id] ?? [] }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? { storage[destination.id]?.first { $0.eventIdentifier == identifier } }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] {
        (storage[destination.id] ?? []).filter { CalendarDraftValidation.sameEvent($0.draft, draft) }.map(\.eventIdentifier)
    }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String {
        if failCopy { throw CalendarDestinationError.calendarUnavailable }
        let id = "copy-" + draft.id.uuidString
        storage[destination.id, default: []].append(.init(eventIdentifier: id, title: draft.title, start: draft.startDate!, end: draft.endDate!,
            isAllDay: draft.isAllDay, timeZone: draft.timeZoneIdentifier, location: draft.location, calendarName: "Destination", url: draft.url, notes: draft.notes))
        writes.append("copy"); return id
    }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String {
        guard let index = storage[destination.id]?.firstIndex(where: { $0.eventIdentifier == identifier }) else { throw CalendarDestinationError.calendarUnavailable }
        storage[destination.id]?[index] = .init(eventIdentifier: identifier, title: draft.title, start: draft.startDate!, end: draft.endDate!, isAllDay: draft.isAllDay,
            timeZone: draft.timeZoneIdentifier, location: draft.location, calendarName: "Destination", url: draft.url, notes: draft.notes)
        writes.append("update"); return identifier
    }
    func delete(identifier: String, in destination: CalendarDestination) async throws {
        if failDelete { throw CalendarDestinationError.calendarUnavailable }
        storage[destination.id]?.removeAll { $0.eventIdentifier == identifier }; writes.append("delete")
    }
    func configure(copy: Bool = false, delete: Bool = false) { failCopy = copy; failDelete = delete }
    func log() -> [String] { writes }
}

extension CalendarOperationTests {
    private func moveProposal(_ original: CalendarEventSnapshot) -> CalendarActionProposal {
        var draft = original.draft; draft.id = UUID()
        var proposal = CalendarActionProposal(draft: draft, operation: .move, targetEventIdentifier: original.eventIdentifier, before: original.draft)
        proposal.sourceDestinationID = "source"; proposal.sourceCalendarName = "Source"
        proposal.targetDestinationID = "destination"; proposal.targetCalendarName = "Destination"
        return proposal
    }
    func testTwoEventTransferHasOneApprovalAndCopiesBeforeEachRemoval() async throws {
        var second = event(); second.eventIdentifier = "second"; second.start = second.start.addingTimeInterval(86400); second.end = second.end.addingTimeInterval(86400)
        let service = TransferCalendarFixture([event(), second])
        let coordinator = CalendarActionCoordinator(service: service)
        var approvalCompletions = 0
        var journalCopies = 0
        coordinator.onExecutionFinished = { _ in approvalCompletions += 1 }
        coordinator.persist = { rows in journalCopies = max(journalCopies, rows.filter { $0.moveCopyReceipt != nil }.count) }
        coordinator.replace(with: [moveProposal(event()), moveProposal(second)])
        await coordinator.checkDuplicates(destinationID: "destination")
        await coordinator.execute(destinationID: "destination", calendarName: "Destination")
        XCTAssertEqual(coordinator.movedCount, 2)
        XCTAssertEqual(approvalCompletions, 1)
        XCTAssertEqual(journalCopies, 2)
        let log = await service.log()
        XCTAssertEqual(log, ["copy", "delete", "copy", "delete"])
        XCTAssertTrue(coordinator.proposals.allSatisfy { $0.receipt?.destinationID == "destination" })
    }
    func testCopyFailureKeepsOriginalAndDeleteFailureRetriesWithoutAnotherCopy() async throws {
        let service = TransferCalendarFixture([event()])
        let coordinator = CalendarActionCoordinator(service: service)
        coordinator.replace(with: [moveProposal(event())])
        await coordinator.checkDuplicates(destinationID: "destination")
        await service.configure(copy: true)
        await coordinator.execute(destinationID: "destination", calendarName: "Destination")
        var log = await service.log(); XCTAssertEqual(log, [])
        var original = try await service.event(identifier: "midterm", in: .eventKit(calendarIdentifier: "source"))
        XCTAssertNotNil(original)
        await service.configure(delete: true)
        coordinator.selectReady()
        await coordinator.execute(destinationID: "destination", calendarName: "Destination")
        XCTAssertNotNil(coordinator.proposals.first?.moveCopyReceipt)
        XCTAssertEqual(coordinator.proposals.first?.state, .failed)
        await service.configure()
        coordinator.selectReady()
        await coordinator.execute(destinationID: "destination", calendarName: "Destination")
        log = await service.log(); XCTAssertEqual(log, ["copy", "delete"])
        original = try await service.event(identifier: "midterm", in: .eventKit(calendarIdentifier: "source"))
        XCTAssertNil(original)
        XCTAssertEqual(coordinator.movedCount, 1)
    }
    func testInterruptedCopyRecoversWithoutRemovingOriginalUntilReapproved() async throws {
        let service = TransferCalendarFixture([event()])
        let coordinator = CalendarActionCoordinator(service: service)
        var durable: [CalendarActionProposal] = []
        coordinator.persist = { rows in
            if rows.contains(where: { $0.moveCopyReceipt != nil }) { throw CalendarDestinationError.calendarUnavailable }
            durable = rows
        }
        coordinator.replace(with: [moveProposal(event())])
        await coordinator.checkDuplicates(destinationID: "destination")
        await coordinator.execute(destinationID: "destination", calendarName: "Destination")
        XCTAssertEqual(durable.first?.state, .saving)
        let reopened = CalendarActionCoordinator(service: service)
        reopened.replace(with: durable)
        await reopened.checkDuplicates(destinationID: "destination")
        XCTAssertEqual(reopened.proposals.first?.state, .failed)
        XCTAssertNotNil(reopened.proposals.first?.moveCopyReceipt)
        var log = await service.log(); XCTAssertEqual(log, ["copy"])
        reopened.selectReady()
        await reopened.execute(destinationID: "destination", calendarName: "Destination")
        log = await service.log(); XCTAssertEqual(log, ["copy", "delete"])
        XCTAssertEqual(reopened.movedCount, 1)
    }
    func testMoveToolReusesSearchedDestinationCopyAndLocksDestination() async throws {
        var copy = event(); copy.eventIdentifier = "existing-copy"
        let service = TransferCalendarFixture([event()], copies: [copy])
        let coordinator = CalendarActionCoordinator(service: service)
        let calendars = [CalendarDestinationInfo(id: "source", title: "Source", provider: .apple, isReadOnly: false),
                         CalendarDestinationInfo(id: "destination", title: "Destination", provider: .google, isReadOnly: false)]
        var waiting = false
        var bound: String?
        let tools = CalendarAgentToolExecutor(service: service, coordinator: coordinator, destination: { ("source", "Source") },
            searchDestinations: { calendars }, onTargetDestination: { bound = $0 }, screenText: { "" }, onApproval: { waiting = $0 })
        coordinator.onExecutionFinished = { tools.finishApproval($0) }
        let id = UUID(); tools.activate(sessionID: id)
        _ = await tools.execute(name: "search_events", arguments: .object([:]), sessionID: id)
        let task = Task { await tools.execute(name: "move_events", arguments: .object([
            "calendarIdentifier": .string("destination"), "events": .array([.object([
                "eventIdentifier": .string("midterm"), "existingDestinationEventIdentifier": .string("existing-copy")])])]), sessionID: id) }
        while !waiting { await Task.yield() }
        XCTAssertEqual(bound, "destination")
        XCTAssertEqual(coordinator.proposals.first?.operation, .move)
        await coordinator.checkDuplicates(destinationID: "destination")
        await coordinator.execute(destinationID: "destination", calendarName: "Destination")
        let result = try JSONDecoder().decode(JSONValue.self, from: Data((await task.value).utf8))
        XCTAssertEqual(result.objectValue?["moved"]?.arrayValue?.count, 1)
        let log = await service.log(); XCTAssertEqual(log, ["delete"])
    }
}

extension CalendarOperationTests {
    func testExistingCopyRestoresOriginalNotesBeforeRemoval() async {
        let original = event()
        var existing = original; existing.eventIdentifier = "copy"; existing.notes = nil
        let service = TransferCalendarFixture([original], copies: [existing])
        let coordinator = CalendarActionCoordinator(service: service)
        var proposal = moveProposal(original)
        proposal.moveDestinationBefore = existing.draft
        proposal.moveCopyReceipt = CalendarActionReceipt(destinationID: "destination", calendarName: "Destination", eventIdentifier: "copy", savedAt: .now)
        coordinator.replace(with: [proposal])
        await coordinator.checkDuplicates(destinationID: "destination")
        await coordinator.execute(destinationID: "destination", calendarName: "Destination")
        let log = await service.log()
        XCTAssertEqual(log, ["update", "delete"])
        XCTAssertEqual(coordinator.movedCount, 1)
        let copy = try? await service.event(identifier: "copy", in: .eventKit(calendarIdentifier: "destination"))
        XCTAssertEqual(copy?.notes, "Bring ID")
    }
    func testStopAfterCopyRetainsOriginal() async {
        let service = TransferCalendarFixture([event()])
        let coordinator = CalendarActionCoordinator(service: service)
        coordinator.replace(with: [moveProposal(event())])
        coordinator.persist = { rows in if rows.contains(where: { $0.moveCopyReceipt != nil }) { coordinator.requestStop() } }
        await coordinator.checkDuplicates(destinationID: "destination")
        await coordinator.execute(destinationID: "destination", calendarName: "Destination")
        let log = await service.log()
        XCTAssertEqual(log, ["copy"])
        let original = try? await service.event(identifier: "midterm", in: .eventKit(calendarIdentifier: "source"))
        XCTAssertNotNil(original)
        XCTAssertEqual(coordinator.proposals.first?.state, .failed)
    }
}
