import XCTest
@testable import Calshot

@MainActor
private final class ToolSignal {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?
    func reset() { fired = false }
    func send() { fired = true; continuation?.resume(); continuation = nil }
    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor ToolCalendarService: CalendarDestinationService {
    var events: [CalendarEventSnapshot]
    var failingTitles: Set<String> = []
    var savedTitles: [String] = []
    init(events: [CalendarEventSnapshot] = []) { self.events = events }
    func availableDestinations() async throws -> [CalendarDestinationInfo] { [] }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] { [] }
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] { events }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? { events.first { $0.eventIdentifier == identifier } }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String {
        if failingTitles.contains(draft.title) { throw CalendarDestinationError.calendarUnavailable }
        savedTitles.append(draft.title)
        return "saved-" + draft.title
    }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String { identifier }
    func delete(identifier: String, in destination: CalendarDestination) async throws { events.removeAll { $0.eventIdentifier == identifier } }
    func fail(_ titles: Set<String>) { failingTitles = titles }
    func count() -> Int { savedTitles.count }
}

@MainActor
final class CalendarAgentToolTests: XCTestCase {
    private func snapshot(_ identifier: String, title: String) -> CalendarEventSnapshot {
        CalendarEventSnapshot(eventIdentifier: identifier, title: title,
            start: ISO8601DateFormatter().date(from: "2026-11-01T15:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-11-01T16:00:00Z")!,
            isAllDay: false, timeZone: "America/Toronto", location: nil, calendarName: "School", url: nil, notes: nil)
    }
    private func payload(_ index: Int) -> JSONValue {
        .object(["title": .string("Assignment \(index)"), "date": .string(String(format: "2026-11-%02d", index)),
                 "startTime": .string("10:00"), "endTime": .string("11:00"), "allDay": .bool(false),
                 "timeZone": .string("America/Toronto"), "location": .null, "url": .null, "notes": .null,
                 "evidence": .string("Assignment \(index) November \(index), 2026 10:00 AM - 11:00 AM")])
    }
    private func decode(_ value: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }
    private func executor(_ service: ToolCalendarService, _ coordinator: CalendarActionCoordinator,
                          approval: ToolSignal? = nil, question: ToolSignal? = nil) -> CalendarAgentToolExecutor {
        CalendarAgentToolExecutor(service: service, coordinator: coordinator, destination: { (id: "school", name: "School") },
                                  screenText: { "Syllabus Fall 2026" }, sourceContext: { "Syllabus Fall 2026" },
                                  onApproval: { if $0 { approval?.send() } },
                                  onQuestion: { if $0 != nil { question?.send() } })
    }

    func testEmptySearchNamesTheCalendarAndExactRange() async throws {
        let service = ToolCalendarService()
        let tools = executor(service, CalendarActionCoordinator(service: service))
        let session = UUID(); tools.activate(sessionID: session)
        let result = try decode(await tools.execute(name: "search_events", arguments: .object([
            "start": .string("2026-10-15T00:00:00-04:00"), "end": .string("2026-10-16T00:00:00-04:00")]), sessionID: session))
        XCTAssertEqual(result["calendarName"] as? String, "School")
        XCTAssertEqual(result["calendarIdentifier"] as? String, "school")
        XCTAssertEqual(result["start"] as? String, "2026-10-15T04:00:00Z")
        XCTAssertEqual(result["end"] as? String, "2026-10-16T04:00:00Z")
        XCTAssertTrue((result["scope"] as? String)?.contains("other calendars were not checked") == true)
        XCTAssertEqual((result["events"] as? [Any])?.count, 0)
    }
    func testUnavailableCalendarIsAnErrorRatherThanEmptyEvents() async throws {
        let service = ToolCalendarService()
        let tools = CalendarAgentToolExecutor(service: service, coordinator: CalendarActionCoordinator(service: service),
                                              destination: { nil }, screenText: { "" })
        let session = UUID(); tools.activate(sessionID: session)
        let result = try decode(await tools.execute(name: "search_events", arguments: .object([:]), sessionID: session))
        XCTAssertNotNil(result["error"])
        XCTAssertNil(result["events"])
    }

    func testTwoMatchesRequireQuestionBeforeUpdateAndCancellationKeepsTargetsBlocked() async throws {
        let service = ToolCalendarService(events: [snapshot("a", title: "Midterm A"), snapshot("b", title: "Midterm B")])
        let coordinator = CalendarActionCoordinator(service: service)
        let approval = ToolSignal(), question = ToolSignal()
        let tools = executor(service, coordinator, approval: approval, question: question)
        let session = UUID(); tools.activate(sessionID: session)
        _ = await tools.execute(name: "search_events", arguments: .object(["query": .string("Midterm")]), sessionID: session)
        let change: JSONValue = .object(["eventIdentifier": .string("a"), "title": .string("New Midterm")])
        let blocked = try decode(await tools.execute(name: "update_event", arguments: change, sessionID: session))
        XCTAssertNotNil(blocked["error"])
        let asking = Task { await tools.execute(name: "ask_user", arguments: .object(["question": .string("Which midterm?"), "choices": .array([.string("Midterm A"), .string("Midterm B")])]), sessionID: session) }
        await question.wait()
        tools.answerQuestion(nil)
        let cancelled = try decode(await asking.value)
        XCTAssertEqual(cancelled["cancelled"] as? Bool, true)
        let stillBlocked = try decode(await tools.execute(name: "update_event", arguments: change, sessionID: session))
        XCTAssertEqual(stillBlocked["skipped"] as? Bool, true)
        tools.cancelPending(sessionID: session)
    }

    func testAnsweredQuestionAllowsUpdateApproval() async throws {
        let service = ToolCalendarService(events: [snapshot("a", title: "Midterm A"), snapshot("b", title: "Midterm B")])
        let coordinator = CalendarActionCoordinator(service: service)
        let approval = ToolSignal(), question = ToolSignal()
        let tools = executor(service, coordinator, approval: approval, question: question)
        let session = UUID(); tools.activate(sessionID: session)
        _ = await tools.execute(name: "search_events", arguments: .object(["query": .string("Midterm")]), sessionID: session)
        let asking = Task { await tools.execute(name: "ask_user", arguments: .object(["question": .string("Which midterm?"), "choices": .array([.string("Midterm A"), .string("Midterm B")])]), sessionID: session) }
        await question.wait()
        tools.answerQuestion("Midterm A")
        let answer = try decode(await asking.value)
        XCTAssertEqual(answer["answer"] as? String, "Midterm A")
        let updating = Task { await tools.execute(name: "update_event", arguments: .object(["eventIdentifier": .string("a"), "title": .string("New Midterm")]), sessionID: session) }
        await approval.wait()
        XCTAssertEqual(coordinator.proposals.first?.operation, .update)
        XCTAssertEqual(coordinator.proposals.first?.before?.title, "Midterm A")
        tools.skipApproval()
        let result = try decode(await updating.value)
        XCTAssertEqual(result["skipped"] as? Bool, true)
    }

    func testSyllabusBatchReturnsFailuresAndRetryReusesOnlyFailedProposals() async throws {
        let service = ToolCalendarService()
        await service.fail(["Assignment 2", "Assignment 5", "Assignment 8"])
        let coordinator = CalendarActionCoordinator(service: service)
        let approval = ToolSignal()
        let tools = executor(service, coordinator, approval: approval)
        coordinator.onExecutionFinished = tools.finishApproval
        let session = UUID(); tools.activate(sessionID: session)
        let creating = Task { await tools.execute(name: "create_events", arguments: .object(["events": .array((1...12).map(payload))]), sessionID: session) }
        await approval.wait()
        XCTAssertEqual(coordinator.proposals.count, 12)
        await coordinator.checkDuplicates(destinationID: "school")
        XCTAssertTrue(coordinator.canApprove)
        await coordinator.execute(destinationID: "school", calendarName: "School")
        let result = try decode(await creating.value)
        XCTAssertEqual((result["added"] as? [[String: Any]])?.count, 9)
        XCTAssertEqual((result["failed"] as? [[String: Any]])?.count, 3)
        let failedIDs = Set(coordinator.proposals.filter { $0.state == .failed }.map(\.id))
        approval.reset()
        // Keep the same executor/session so its receipt history guards repeated writes.
        let retry = Task { await tools.execute(name: "create_events", arguments: .object(["events": .array([2, 5, 8].map(payload))]), sessionID: session) }
        await approval.wait()
        XCTAssertEqual(Set(coordinator.proposals.filter { !$0.isFinished }.map(\.id)), failedIDs)
        await service.fail([])
        await coordinator.checkDuplicates(destinationID: "school")
        await coordinator.execute(destinationID: "school", calendarName: "School")
        let retried = try decode(await retry.value)
        XCTAssertEqual((retried["added"] as? [[String: Any]])?.count, 3)
        let saved = await service.count()
        XCTAssertEqual(saved, 12)
    }

    func testRejectingDeleteReturnsSkipped() async throws {
        let service = ToolCalendarService(events: [snapshot("a", title: "Old Midterm")])
        let coordinator = CalendarActionCoordinator(service: service)
        let approval = ToolSignal()
        let tools = executor(service, coordinator, approval: approval)
        let session = UUID(); tools.activate(sessionID: session)
        _ = await tools.execute(name: "search_events", arguments: .object(["query": .string("Midterm")]), sessionID: session)
        let deleting = Task { await tools.execute(name: "delete_event", arguments: .object(["eventIdentifier": .string("a"), "reason": .string("Replaced by new date")]), sessionID: session) }
        await approval.wait()
        XCTAssertFalse(coordinator.proposals.first!.isSelected)
        tools.skipApproval()
        let result = try decode(await deleting.value)
        XCTAssertEqual(result["skipped"] as? Bool, true)
        let current = try await service.event(identifier: "a", in: .eventKit(calendarIdentifier: "school"))
        XCTAssertNotNil(current)
    }

    func testTitleOnlyUpdatePreservesMultidayAllDayFields() throws {
        var existing = snapshot("a", title: "Conference").draft
        existing.isAllDay = true
        existing.endDate = existing.startDate!.addingTimeInterval(3 * 86400)
        let changed = try CalendarToolDraftMapper.update(["title": .string("Conference renamed")], before: existing)
        XCTAssertEqual(changed.startDate, existing.startDate)
        XCTAssertEqual(changed.endDate, existing.endDate)
        XCTAssertEqual(changed.isAllDay, existing.isAllDay)
        XCTAssertEqual(changed.timeZoneIdentifier, existing.timeZoneIdentifier)
        XCTAssertEqual(changed.location, existing.location)
        XCTAssertEqual(changed.notes, existing.notes)
    }

    func testUnknownArgumentsAndMalformedInputAreRejected() async throws {
        let service = ToolCalendarService()
        let tools = executor(service, CalendarActionCoordinator(service: service))
        let session = UUID(); tools.activate(sessionID: session)
        for (name, arguments) in [("search_events", JSONValue.object(["unknown": .bool(true)])),
                                  ("create_events", .object(["events": .string("not an array")])),
                                  ("delete_event", .object(["eventIdentifier": .number(5), "reason": .string("test")])),
                                  ("not_a_tool", .object([:]))] {
            let result = try decode(await tools.execute(name: name, arguments: arguments, sessionID: session))
            XCTAssertNotNil(result["error"], name)
        }
        let count = await service.count()
        XCTAssertEqual(count, 0)
    }
}
