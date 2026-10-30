import XCTest
@testable import Calshot

private actor TestCalendarService: CalendarDestinationService {
    var saved: [EventDraft] = []
    var failingTitles: Set<String> = []
    var pause = false
    var saveContinuation: CheckedContinuation<Void, Never>?
    var startContinuation: CheckedContinuation<Void, Never>?
    var didStart = false

    func availableDestinations() async throws -> [CalendarDestinationInfo] { [] }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] {
        saved.filter { $0.title == draft.title && $0.startDate == draft.startDate && $0.endDate == draft.endDate }.map { $0.id.uuidString }
    }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String {
        didStart = true
        startContinuation?.resume(); startContinuation = nil
        if pause { await withCheckedContinuation { saveContinuation = $0 } }
        if failingTitles.contains(draft.title) { throw CalendarDestinationError.calendarUnavailable }
        saved.append(draft)
        return draft.id.uuidString
    }
    func fail(_ titles: Set<String>) { failingTitles = titles }
    func setPause() { pause = true }
    func waitForSave() async {
        if didStart { return }
        await withCheckedContinuation { startContinuation = $0 }
    }
    func resumeSave() { pause = false; saveContinuation?.resume(); saveContinuation = nil }
    func count() -> Int { saved.count }
    func seed(_ draft: EventDraft) { saved.append(draft) }
}

@MainActor
final class CalendarActionTests: XCTestCase {
    private func draft(_ title: String, day: Int = 1) -> EventDraft {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 10))!
        return EventDraft(title: title, startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false,
                          timeZoneIdentifier: calendar.timeZone.identifier, location: nil, url: nil, notes: nil,
                          sourceText: title, confidence: 0.9, ambiguities: [])
    }

    func testSyllabusRowsRetainTenAssociationsAndDoNotInventConfirmedTimes() {
        let text = "BIO 101 — Fall 2026\n" + (1...8).map { "Assignment \($0) | November \($0), 2026" }.joined(separator: "\n") +
            "\nMidterm | November 12, 2026 | 10:00 AM - 11:30 AM\nFinal exam | December 15, 2026 | 2:00 PM - 4:00 PM"
        let drafts = EventDraftParser.parse(text, timeZone: TimeZone(identifier: "America/Toronto")!)
        XCTAssertEqual(drafts.count, 10)
        XCTAssertEqual(drafts.prefix(8).map(\.title), (1...8).map { "Assignment \($0)" })
        XCTAssertTrue(drafts.prefix(8).allSatisfy { $0.ambiguities.contains(.missingTime) })
        XCTAssertFalse(drafts.last!.ambiguities.contains(.multipleEvents))
        for (index, item) in drafts.prefix(8).enumerated() {
            XCTAssertEqual(CalendarDraftValidation.calendar(for: item).component(.day, from: item.startDate!), index + 1)
        }
    }

    func testPartialFailureRetryAndRepeatedApprovalNeverRepeatSuccesses() async {
        let service = TestCalendarService()
        await service.fail(["Quiz"])
        let coordinator = CalendarActionCoordinator(service: service)
        var history: [CalendarActionProposal] = []
        coordinator.persist = { history = $0 }
        coordinator.replace(with: [CalendarActionProposal(draft: draft("Assignment")), CalendarActionProposal(draft: draft("Quiz", day: 2))])
        await coordinator.checkDuplicates(destinationID: "school")
        await coordinator.execute(destinationID: "school", calendarName: "School")
        XCTAssertEqual(coordinator.addedCount, 1)
        XCTAssertEqual(history.filter { $0.receipt != nil }.count, 1)
        XCTAssertEqual(coordinator.proposals.last?.state, .failed)
        await service.fail([])
        await coordinator.execute(destinationID: "school", calendarName: "School")
        await coordinator.execute(destinationID: "school", calendarName: "School")
        let count = await service.count()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(coordinator.addedCount, 2)
    }

    func testStopCompletesInFlightWriteAndLeavesRemainingPending() async {
        let service = TestCalendarService()
        await service.setPause()
        let coordinator = CalendarActionCoordinator(service: service)
        coordinator.replace(with: [CalendarActionProposal(draft: draft("A")), CalendarActionProposal(draft: draft("B", day: 2))])
        await coordinator.checkDuplicates(destinationID: "school")
        let execution = Task { await coordinator.execute(destinationID: "school", calendarName: "School") }
        await service.waitForSave()
        coordinator.requestStop()
        await coordinator.execute(destinationID: "school", calendarName: "School") // Concurrent approval is ignored.
        await service.resumeSave()
        await execution.value
        let count = await service.count()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(coordinator.proposals.last?.state, .pending)
    }

    func testInvalidDraftAndFailedJournalPreventWrites() async {
        let service = TestCalendarService()
        let coordinator = CalendarActionCoordinator(service: service)
        var uncertain = draft("Exam")
        uncertain.ambiguities = [.missingYear, .missingTime]
        var proposal = CalendarActionProposal(draft: uncertain)
        proposal.isSelected = true
        coordinator.replace(with: [proposal])
        await coordinator.execute(destinationID: "school", calendarName: "School")
        XCTAssertFalse(coordinator.canApprove)
        coordinator.replace(with: [CalendarActionProposal(draft: draft("Valid"))])
        await coordinator.checkDuplicates(destinationID: "school")
        coordinator.persist = { _ in throw CocoaError(.fileWriteNoPermission) }
        await coordinator.execute(destinationID: "school", calendarName: "School")
        let count = await service.count()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(coordinator.stopRequested)
    }

    func testDuplicatesRequireExplicitDecisionAndCanBeSkipped() async {
        let service = TestCalendarService()
        let event = draft("Exam")
        await service.seed(event)
        let coordinator = CalendarActionCoordinator(service: service)
        coordinator.replace(with: [CalendarActionProposal(draft: event)])
        await coordinator.checkDuplicates(destinationID: "school")
        XCTAssertFalse(coordinator.canApprove)
        coordinator.update(event.id) { $0.isSelected = false }
        XCTAssertEqual(coordinator.selectedCount, 0)
        coordinator.update(event.id) { $0.allowDuplicate = true; $0.isSelected = true }
        await coordinator.execute(destinationID: "school", calendarName: "School")
        let count = await service.count()
        XCTAssertEqual(count, 2)
    }

    func testInterruptedSaveIsReconciledBeforeRetry() async {
        let service = TestCalendarService()
        let event = draft("Exam")
        await service.seed(event)
        var proposal = CalendarActionProposal(draft: event)
        proposal.state = .saving
        proposal.attemptedDestinationID = "school"
        proposal.attemptedCalendarName = "School"
        let coordinator = CalendarActionCoordinator(service: service)
        coordinator.replace(with: [proposal])
        await coordinator.checkDuplicates(destinationID: "school")
        XCTAssertEqual(coordinator.addedCount, 1)
        XCTAssertEqual(coordinator.proposals.first?.receipt?.destinationID, "school")
        await coordinator.execute(destinationID: "school", calendarName: "School")
        let count = await service.count()
        XCTAssertEqual(count, 1)
    }

    func testStructuredExtractionPreservesEvidenceAndUncertaintyForEveryCandidate() throws {
        let json = Data("""
        {"events":[
          {"title":"Assignment 1","date":"2026-11-01","startTime":null,"endTime":null,"allDay":null,"evidence":"Assignment 1 — Nov 1","yearInferred":true,"dateAmbiguous":false},
          {"title":"Final exam","date":"2026-12-15","startTime":"14:00","endTime":"16:00","allDay":false,"evidence":"Final exam Dec 15, 2026 2-4 PM","yearInferred":false,"dateAmbiguous":false},
          {"title":"Quiz","date":null,"startTime":null,"endTime":null,"allDay":null,"evidence":"Quiz TBD","yearInferred":false,"dateAmbiguous":false}
        ]}
        """.utf8)
        let drafts = try OpenAIEventAnalyzer.drafts(from: json, sourceText: "Full page text")
        XCTAssertEqual(drafts.count, 3)
        XCTAssertEqual(drafts[0].sourceText, "Assignment 1 — Nov 1")
        XCTAssertTrue(drafts[0].ambiguities.contains(.missingYear))
        XCTAssertTrue(drafts[0].ambiguities.contains(.missingTime))
        XCTAssertTrue(drafts[0].isAllDay)
        XCTAssertTrue(CalendarDraftValidation.issues(drafts[1]).isEmpty)
        XCTAssertNil(drafts[2].startDate)
    }

    func testSkippingAnIdenticalBatchItemUnblocksTheOther() async {
        let coordinator = CalendarActionCoordinator(service: TestCalendarService())
        let first = draft("Exam")
        let second = draft("Exam")
        coordinator.replace(with: [CalendarActionProposal(draft: first), CalendarActionProposal(draft: second)])
        XCTAssertFalse(coordinator.proposals[1].canAdd)
        coordinator.update(first.id) { $0.isSelected = false }
        XCTAssertTrue(coordinator.proposals[1].canAdd)
        await coordinator.checkDuplicates(destinationID: "school")
        XCTAssertTrue(coordinator.canApprove)
    }

    func testAllDayUsesCalendarDayAcrossDaylightSaving() {
        var event = draft("Assignment", day: 1) // Toronto DST ends November 1, 2026.
        CalendarDraftValidation.setAllDay(&event, enabled: true)
        XCTAssertEqual(event.endDate!.timeIntervalSince(event.startDate!), 25 * 3600, accuracy: 1)
    }

    func testAdditionalScreenshotsMergeOverlapAndRetainSourceUntilDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(directoryURL: root)
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let first = CalendarActionProposal(draft: draft("A"))
        let record = try store.recordCapture(imageData: png, proposals: [first])
        let updated = try XCTUnwrap(store.appendScreenshot(for: record.id, imageData: png, recognizedText: "Page two",
            proposals: [CalendarActionProposal(draft: draft("A")), CalendarActionProposal(draft: draft("B", day: 2))]))
        XCTAssertEqual(updated.calendarProposals.count, 2)
        XCTAssertEqual(updated.calendarProposals.first?.id, first.id)
        let sourceID = try XCTUnwrap(updated.calendarProposals.last?.sourceCaptureID)
        XCTAssertEqual(store.imageData(for: updated, sourceID: sourceID), png)
        XCTAssertEqual(updated.additionalScreenshots?.first?.recognizedText, "Page two")
        try store.deleteRecord(id: record.id)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testGroupYearAndAllDayDoNotConfirmUnknownExamTimes() {
        let service = TestCalendarService()
        let coordinator = CalendarActionCoordinator(service: service)
        var assignment = draft("Assignment")
        assignment.ambiguities = [.missingYear, .missingTime]
        var exam = draft("Exam", day: 2)
        exam.ambiguities = [.missingYear, .missingTime]
        coordinator.replace(with: [CalendarActionProposal(draft: assignment), CalendarActionProposal(draft: exam)])
        coordinator.applyYear(2027)
        coordinator.confirmDateOnlyDeadlines()
        XCTAssertTrue(coordinator.proposals.first!.issues.isEmpty)
        XCTAssertTrue(coordinator.proposals.first!.draft.isAllDay)
        XCTAssertTrue(coordinator.proposals.last!.issues.contains("Choose a time or confirm all-day."))
        XCTAssertEqual(CalendarDraftValidation.calendar(for: assignment).component(.year, from: coordinator.proposals.first!.draft.startDate!), 2027)
    }
    func testConfirmYearPreservesAllDaySpanAndRejectsInvalidLeapDate() throws {
        let coordinator = CalendarActionCoordinator(service: TestCalendarService())
        var trip = draft("Fictional multi-day trip")
        let calendar = CalendarDraftValidation.calendar(for: trip)
        trip.startDate = calendar.startOfDay(for: trip.startDate!)
        trip.endDate = calendar.date(byAdding: .day, value: 3, to: trip.startDate!)
        trip.isAllDay = true; trip.ambiguities = [.missingYear]
        var leap = draft("Fictional leap day")
        leap.startDate = calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 10))
        leap.endDate = leap.startDate?.addingTimeInterval(3600); leap.ambiguities = [.missingYear]
        coordinator.replace(with: [CalendarActionProposal(draft: trip), CalendarActionProposal(draft: leap)])
        coordinator.applyYear(2027)
        let changed = try XCTUnwrap(coordinator.proposals.first { $0.id == trip.id }?.draft)
        XCTAssertFalse(changed.ambiguities.contains(.missingYear))
        XCTAssertEqual(calendar.dateComponents([.day], from: try XCTUnwrap(changed.startDate), to: try XCTUnwrap(changed.endDate)).day, 3)
        XCTAssertTrue(coordinator.proposals.first { $0.id == leap.id }?.draft.ambiguities.contains(.missingYear) == true)
        XCTAssertTrue(coordinator.proposals.allSatisfy { $0.receipt == nil })
    }

    func testLegacyAndBatchHistoryRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(directoryURL: root)
        let record = try store.recordCapture(imageData: Data([137, 80, 78, 71, 13, 10, 26, 10]), draft: draft("Legacy"))
        try store.markSavedToCalendar(for: record.id, calendarName: "School", eventIdentifier: "old-id")
        let legacy = try XCTUnwrap(store.listRecords().first)
        XCTAssertEqual(legacy.calendarProposals.first?.state, .added)
        var batch = [CalendarActionProposal(draft: draft("A")), CalendarActionProposal(draft: draft("B", day: 2))]
        batch[1].isSelected = false
        try store.updateProposals(for: record.id, proposals: batch)
        let restored = try XCTUnwrap(MemoryStore(directoryURL: root).listRecords().first)
        XCTAssertEqual(restored.calendarProposals.count, 2)
        XCTAssertFalse(restored.calendarProposals[1].isSelected)
        XCTAssertEqual(restored.schemaVersion, 3)
        // A genuinely old file has neither of the optional version/batch fields.
        let metadata = root.appendingPathComponent(record.id.uuidString + ".json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        json.removeValue(forKey: "schemaVersion"); json.removeValue(forKey: "proposals")
        try JSONSerialization.data(withJSONObject: json).write(to: metadata)
        XCTAssertEqual(store.listRecords().first?.calendarProposals.count, 1)
    }
}
