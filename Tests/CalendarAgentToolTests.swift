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
    var otherWrites = 0
    var searches = 0
    init(events: [CalendarEventSnapshot] = []) { self.events = events }
    func availableDestinations() async throws -> [CalendarDestinationInfo] { [] }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] { [] }
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] { searches += 1; return events }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? { events.first { $0.eventIdentifier == identifier } }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String {
        if failingTitles.contains(draft.title) { throw CalendarDestinationError.calendarUnavailable }
        savedTitles.append(draft.title)
        return "saved-" + draft.title
    }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String { otherWrites += 1; return identifier }
    func delete(identifier: String, in destination: CalendarDestination) async throws { otherWrites += 1; events.removeAll { $0.eventIdentifier == identifier } }
    func fail(_ titles: Set<String>) { failingTitles = titles }
    func count() -> Int { savedTitles.count }
    func providerWriteCount() -> Int { savedTitles.count + otherWrites }
    func searchCount() -> Int { searches }
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

    func testTaskMutationToolsRequireBothNativeHooks() async throws {
        let service = ToolCalendarService(); let tools = executor(service, CalendarActionCoordinator(service: service))
        let session = UUID(); tools.activate(sessionID: session)
        XCTAssertFalse(tools.availableToolNames.contains("link_event_to_task"))
        tools.prepareTaskMutation = { _, _ in .object(["status": .string("prepared")]) }
        XCTAssertFalse(tools.availableToolNames.contains("update_tasks"))
        let result = try decode(await tools.execute(name: "link_event_to_task", arguments: .object(["contextReference": .string(UUID().uuidString)]), sessionID: session))
        XCTAssertEqual(result["status"] as? String, "needsAuthorization")
        XCTAssertEqual(result["saved"] as? Bool, false)
        tools.authorizeTaskMutation = { _, _ in .object(["status": .string("cancelled")]) }
        XCTAssertTrue(tools.availableToolNames.contains("update_tasks"))
        XCTAssertTrue(tools.availableToolNames.contains("link_event_to_task"))
    }

    func testExactSelectedEventLinkTraceHasNoCalendarWritesAndNoModelAuthority() async throws {
        let service = ToolCalendarService(events: [snapshot("source", title: "Fictional timed meeting")])
        let coordinator = CalendarActionCoordinator(service: service)
        let tools = executor(service, coordinator)
        let run = UUID(), reference = UUID(), taskID = UUID(); tools.activate(sessionID: run)
        var prepared: AgentPreparedTaskMutation?
        var authorized = 0
        tools.selectedTaskContext = { receivedRun in
            XCTAssertEqual(receivedRun, run)
            return .object(["contextReference": .string(reference.uuidString), "title": .string("Fictional timed meeting"), "isAllDay": .bool(false)])
        }
        tools.prepareTaskMutation = { change, receivedRun in
            XCTAssertEqual(receivedRun, run)
            XCTAssertEqual(change.change, .linkSelectedEvent(contextReference: reference)); prepared = change
            return .object(["status": .string("prepared")])
        }
        tools.authorizeTaskMutation = { change, receivedRun in
            XCTAssertEqual(receivedRun, run); XCTAssertEqual(change, prepared); authorized += 1
            // Fictional native approval hook: no provider is called by task-only linking.
            return .object(["taskReceipts": .array([.object(["taskID": .string(taskID.uuidString), "outcome": .string("saved")])]), "calendarWrites": .number(0)])
        }
        let selected = try decode(await tools.execute(name: "get_selected_event_context", arguments: .object([:]), sessionID: run))
        XCTAssertEqual(selected["isAllDay"] as? Bool, false)
        for key in ["ownerID", "storeURL", "eventIdentifier", "destinationID", "approved"] {
            let rejected = try decode(await tools.execute(name: "link_event_to_task", arguments: .object(["contextReference": .string(reference.uuidString), key: .string("fabricated")]), sessionID: run))
            XCTAssertNotNil(rejected["error"])
        }
        XCTAssertEqual(authorized, 0)
        let result = try decode(await tools.execute(name: "link_event_to_task", arguments: .object(["contextReference": .string(reference.uuidString)]), sessionID: run))
        XCTAssertEqual(authorized, 1); XCTAssertEqual(result["calendarWrites"] as? Int, 0)
        XCTAssertTrue(coordinator.proposals.isEmpty)
        let writes = await service.providerWriteCount(); XCTAssertEqual(writes, 0)
        let searches = await service.searchCount(); XCTAssertEqual(searches, 0)
        let source = try await service.event(identifier: "source", in: .resolve(identifier: "school"))
        XCTAssertEqual(source?.isAllDay, false); XCTAssertEqual(source?.title, "Fictional timed meeting")
    }

    func testTaskReadsIncludeVersionsArchivedRowsAndMissingTargets() async throws {
        let service = ToolCalendarService(), id = UUID(), version = UUID(), archived = UUID(), absent = UUID()
        let tools = executor(service, CalendarActionCoordinator(service: service)), session = UUID(); tools.activate(sessionID: session)
        tools.listTasks = { .array([
            .object(["id": .string(id.uuidString), "version": .string(version.uuidString), "archived": .bool(false)]),
            .object(["id": .string(archived.uuidString), "version": .string(UUID().uuidString), "archived": .bool(true)])]) }
        let active = try decode(await tools.execute(name: "list_tasks", arguments: .object([:]), sessionID: session))
        XCTAssertEqual((active["tasks"] as? [[String: Any]])?.count, 1)
        let all = try decode(await tools.execute(name: "list_tasks", arguments: .object(["includeArchived": .bool(true)]), sessionID: session))
        XCTAssertEqual((all["tasks"] as? [[String: Any]])?.count, 2)
        let exact = try decode(await tools.execute(name: "get_tasks", arguments: .object(["taskIDs": .array([.string(id.uuidString), .string(absent.uuidString)])]), sessionID: session))
        XCTAssertEqual((exact["tasks"] as? [[String: Any]])?.first?["version"] as? String, version.uuidString)
        XCTAssertEqual(exact["missingTaskIDs"] as? [String], [absent.uuidString])
    }

    func testTaskPatchesPreserveOmissionsRequireVersionsAndRejectAuthority() throws {
        let service = ToolCalendarService()
        let tools = executor(service, CalendarActionCoordinator(service: service))
        let id = UUID(), version = UUID()
        let fields: [String: JSONValue] = ["tasks": .array([.object(["taskID": .string(id.uuidString), "expectedVersion": .string(version.uuidString), "patch": .object(["notes": .null])])])]
        let request = try tools.prepareTaskMutationArguments(name: "update_tasks", fields: fields)
        guard case .patches(let patches) = request.change else { return XCTFail("Expected patches") }
        XCTAssertEqual(patches.first?.taskID, id); XCTAssertEqual(patches.first?.expectedVersion, version)
        XCTAssertEqual(patches.first?.fields, ["notes": .null])
        for patch: [String: JSONValue] in [["ownerID": .string("fake")], ["calendarIntent": .string("existing")], ["receipt": .object([:])], ["completed": .bool(true)], ["title": .null], ["dueDate": .string("11-02")], ["dueTime": .string("25:00")]] {
            XCTAssertThrowsError(try tools.prepareTaskMutationArguments(name: "update_tasks", fields: ["tasks": .array([.object(["taskID": .string(id.uuidString), "expectedVersion": .string(version.uuidString), "patch": .object(patch)])])]))
        }
        XCTAssertThrowsError(try tools.prepareTaskMutationArguments(name: "update_tasks", fields: ["tasks": .array([.object(["taskID": .string(id.uuidString), "patch": .object(["title": .string("Fictional")])])])]))
    }

    func testTaskSourcePreflightFailureNeverCallsAuthorization() async throws {
        let service = ToolCalendarService()
        let tools = executor(service, CalendarActionCoordinator(service: service))
        let run = UUID(); tools.activate(sessionID: run)
        var calls = 0
        tools.prepareTaskMutation = { _, _ in throw CalendarToolArgumentError("The source event changed or is unavailable.") }
        tools.authorizeTaskMutation = { _, _ in calls += 1; return .object([:]) }
        let result = try decode(await tools.execute(name: "link_event_to_task", arguments: .object(["contextReference": .string(UUID().uuidString)]), sessionID: run))
        XCTAssertNotNil(result["error"]); XCTAssertEqual(calls, 0)
    }

    func testStopPreventsTaskAuthorizationAfterPreflight() async throws {
        let service = ToolCalendarService()
        let tools = executor(service, CalendarActionCoordinator(service: service))
        let run = UUID(), started = ToolSignal(), finish = ToolSignal(); tools.activate(sessionID: run)
        var calls = 0
        tools.prepareTaskMutation = { _, _ in started.send(); await finish.wait(); return .object([:]) }
        tools.authorizeTaskMutation = { _, _ in calls += 1; return .object([:]) }
        let pending = Task { await tools.execute(name: "link_event_to_task", arguments: .object(["contextReference": .string(UUID().uuidString)]), sessionID: run) }
        await started.wait(); tools.cancelPending(sessionID: run); finish.send()
        let result = await pending.value
        XCTAssertEqual(try decode(result)["cancelled"] as? Bool, true); XCTAssertEqual(calls, 0)
    }

    func testFriendReadsAreBoundedAndNeverAuthorizeWriteTargets() async throws {
        let service = ToolCalendarService(); let coordinator = CalendarActionCoordinator(service: service)
        let tools = executor(service, coordinator); let session = UUID(); tools.activate(sessionID: session)
        var calls = 0
        tools.listFriends = { .object(["friends": .array([])]) }
        tools.searchFriend = { _ in calls += 1; return .object(["events": .array([.object(["key": .string("friend-private"), "title": .string("Fictional class")])])]) }
        let invalid = try decode(await tools.execute(name: "search_friend_events", arguments: .object(["friendID": .string(UUID().uuidString), "start": .string("2026-01-01T00:00:00Z"), "end": .string("2026-12-01T00:00:00Z")]), sessionID: session))
        XCTAssertNotNil(invalid["error"]); XCTAssertEqual(calls, 0)
        let result = try decode(await tools.execute(name: "search_friend_events", arguments: .object(["friendID": .string(UUID().uuidString), "start": .string("2026-10-21T00:00:00Z"), "end": .string("2026-10-22T00:00:00Z")]), sessionID: session))
        XCTAssertEqual((result["events"] as? [[String: Any]])?.count, 1)
        let write = try decode(await tools.execute(name: "delete_event", arguments: .object(["eventIdentifier": .string("friend-private"), "reason": .string("Requested")]), sessionID: session))
        XCTAssertNotNil(write["error"]); XCTAssertTrue(coordinator.proposals.isEmpty)
    }
    func testNewSessionDropsLateFriendReadResults() async throws {
        let service = ToolCalendarService(); let tools = executor(service, CalendarActionCoordinator(service: service))
        let started = ToolSignal(), finish = ToolSignal(); let old = UUID(); tools.activate(sessionID: old)
        tools.searchFriend = { _ in started.send(); await finish.wait(); return .object(["private": .string("Old friend result")]) }
        let request = Task { await tools.execute(name: "search_friend_events", arguments: .object(["friendID": .string(UUID().uuidString), "start": .string("2026-10-21T00:00:00Z"), "end": .string("2026-10-22T00:00:00Z")]), sessionID: old) }
        await started.wait(); tools.activate(sessionID: UUID()); finish.send()
        let completed = await request.value
        XCTAssertEqual(try decode(completed)["cancelled"] as? Bool, true)
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
