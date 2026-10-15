import XCTest
@testable import Calshot

final class AgentMemoryTests: XCTestCase {
    private func store() -> (MemoryStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (MemoryStore(directoryURL: root), root)
    }
    private func draft() -> EventDraft {
        EventDraft(title: "Midterm", startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_003_600), isAllDay: false, timeZoneIdentifier: "America/Toronto",
            location: nil, url: nil, notes: nil, sourceText: "Midterm evidence", confidence: 1, ambiguities: [])
    }
    func testActionReceiptsAndTranscriptAreAvailableToNextCallAfterReopen() throws {
        let (memory, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try memory.recordCommand("Move the midterm")
        var item = CalendarActionProposal(draft: draft(), operation: .update, targetEventIdentifier: "event-1", before: draft())
        item.state = .updated; item.isSelected = false
        item.receipt = CalendarActionReceipt(destinationID: "school", calendarName: "School", eventIdentifier: "event-1", savedAt: .now)
        try memory.updateProposals(for: record.id, proposals: [item])
        let turns = [AgentTurn(role: "user", content: "Move the midterm"), AgentTurn(role: "tool", toolName: "update_event", result: #"{"updated":true,"eventIdentifier":"event-1"}"#)]
        try memory.updateAgentContext(for: record.id, transcript: turns)
        let reopened = MemoryStore(directoryURL: root)
        let restored = try XCTUnwrap(reopened.listRecords().first)
        XCTAssertEqual(restored.agentTranscript, turns)
        XCTAssertEqual(restored.schemaVersion, 3)
        let context = reopened.agentMemory().compactMap(\.content).joined()
        XCTAssertTrue(context.contains("event-1"))
        XCTAssertTrue(context.contains("updated"))
        XCTAssertTrue(context.contains("School"))
        XCTAssertTrue(reopened.agentMemory(excluding: record.id).isEmpty)
        XCTAssertFalse(context.contains("data:image"))
    }
    func testTypedSessionNeedsNoFabricatedScreenshot() throws {
        let (memory, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try memory.recordCommand("Find next week's exams", transcript: [AgentTurn(role: "user", content: "Find exams")])
        XCTAssertEqual(record.screenshotFileName, "")
        XCTAssertNil(memory.imageData(for: record))
        XCTAssertEqual(memory.listRecords().count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    }
    func testUnfinishedProposalsAreNotRememberedAsSuccessfulActions() throws {
        let (memory, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try memory.recordCommand("Add a midterm")
        XCTAssertEqual(record.agentTranscript?.first?.content, "Add a midterm")
        try memory.updateProposals(for: record.id, proposals: [CalendarActionProposal(draft: draft())])
        let context = memory.agentMemory().compactMap(\.content).joined()
        XCTAssertFalse(context.contains("savedAt"))
        XCTAssertFalse(context.contains("eventIdentifier"))
    }
    func testChangingMultiDayAllDayDatePreservesDayCount() throws {
        var before = draft()
        before.isAllDay = true
        let calendar = CalendarDraftValidation.calendar(for: before)
        before.startDate = calendar.startOfDay(for: before.startDate!)
        before.endDate = calendar.date(byAdding: .day, value: 3, to: before.startDate!)
        let moved = try CalendarToolDraftMapper.update(["date": .string("2027-07-20")], before: before)
        XCTAssertEqual(calendar.dateComponents([.day], from: moved.startDate!, to: moved.endDate!).day, 3)
        XCTAssertEqual(moved.changedFieldNames, ["date"])
    }
    @MainActor
    func testApprovalScopeNeverExecutesAnEarlierPendingProposal() async {
        let coordinator = CalendarActionCoordinator(service: CalendarDemoService())
        let old = CalendarActionProposal(draft: draft())
        var newDraft = draft(); newDraft.id = UUID(); newDraft.title = "New request"
        let new = CalendarActionProposal(draft: newDraft)
        coordinator.replace(with: [old, new])
        coordinator.approvalScope = [new.id]
        coordinator.selectReady()
        XCTAssertEqual(coordinator.selectedCount, 1)
        XCTAssertFalse(coordinator.proposals.first(where: { $0.id == old.id })!.isSelected)
        await coordinator.checkDuplicates(destinationID: "demo")
        await coordinator.execute(destinationID: "demo", calendarName: "Demo")
        XCTAssertEqual(coordinator.proposals.first(where: { $0.id == old.id })?.state, .pending)
        XCTAssertEqual(coordinator.proposals.first(where: { $0.id == new.id })?.state, .added)
    }
    func testMissingYearDateOnlyAndInvalidURLStayUnresolved() throws {
        let value: JSONValue = .object(["title": .string("Assignment"), "date": .string("2026-11-03"), "startTime": .null,
            "endTime": .null, "allDay": .bool(true), "evidence": .string("Assignment Nov 3"), "url": .string("javascript:alert(1)")])
        let proposed = try CalendarToolDraftMapper.create(value, context: "Some unrelated all-day class")
        XCTAssertTrue(proposed.ambiguities.contains(.missingYear))
        XCTAssertTrue(proposed.ambiguities.contains(.missingTime))
        XCTAssertTrue(proposed.ambiguities.contains(.invalidURL))
        XCTAssertFalse(CalendarActionProposal(draft: proposed).isSelected)
    }
}
