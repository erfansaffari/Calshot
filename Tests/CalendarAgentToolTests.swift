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
    var filtersQueries = false
    var failingCalendars = Set<String>()
    init(events: [CalendarEventSnapshot] = []) { self.events = events }
    func availableDestinations() async throws -> [CalendarDestinationInfo] { [] }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] { [] }
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] {
        searches += 1
        if failingCalendars.contains(destination.id) { throw CalendarDestinationError.calendarUnavailable }
        guard filtersQueries else { return events }
        return events.filter { $0.start < end && $0.end > start && (query == nil || query == "" || $0.title.localizedCaseInsensitiveContains(query!)) }
    }
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
    func configureSearch(events: [CalendarEventSnapshot]? = nil, filtering: Bool = true, failures: Set<String> = []) {
        if let events { self.events = events }
        filtersQueries = filtering; failingCalendars = failures
    }
}

@MainActor
final class CalendarAgentToolTests: XCTestCase {
    func testSearchMatchesEveryWordInAnyOrderAcrossTitleNotesAndLocation() {
        let title = "Blockchain Innovation Challenge Kick-off"
        XCTAssertTrue(CalendarSearchMatch.matches("Blockchain Challenge", title: title, notes: nil))
        XCTAssertTrue(CalendarSearchMatch.matches("challenge blockchain", title: title, notes: nil))
        XCTAssertTrue(CalendarSearchMatch.matches("kick-off SLC", title: title, notes: nil, location: "SLC Black & Gold room"))
        XCTAssertTrue(CalendarSearchMatch.matches("café", title: "Cafe meetup", notes: nil))
        XCTAssertTrue(CalendarSearchMatch.matches(nil, title: title, notes: nil)); XCTAssertTrue(CalendarSearchMatch.matches("  ", title: title, notes: nil))
        XCTAssertFalse(CalendarSearchMatch.matches("Blockchain hackathon", title: title, notes: nil), "Every word must appear")
    }
    func testSearchToleratesPunctuationAndSmallTyposInLongerWordsOnly() {
        let title = "Blockchain Innovation Challenge Kick-off"
        XCTAssertTrue(CalendarSearchMatch.matches("kickoff", title: title, notes: nil))
        XCTAssertTrue(CalendarSearchMatch.matches("blockchian", title: title, notes: nil), "Swapped letters")
        XCTAssertTrue(CalendarSearchMatch.matches("inovation", title: title, notes: nil), "Missing letter")
        XCTAssertFalse(CalendarSearchMatch.matches("quit", title: "Stat quiz", notes: nil), "Short words need an exact match")
        XCTAssertFalse(CalendarSearchMatch.matches("hackathon", title: title, notes: nil))
    }
    func testUnmatchedSearchListsTheWholeRangeSoAForgottenNameCanStillBeFound() async throws {
        let service = ToolCalendarService()
        await service.configureSearch(events: [snapshot("chain", title: "Blockchain Innovation Challenge Kick-off"), snapshot("quiz", title: "Stat quiz")])
        let tools = executor(service, CalendarActionCoordinator(service: service))
        let session = UUID(); tools.activate(sessionID: session)
        let range: [String: JSONValue] = ["start": .string("2026-10-30T00:00:00Z"), "end": .string("2026-11-30T00:00:00Z")]
        let result = try decode(await tools.execute(name: "search_events", arguments: .object(range.merging(["query": .string("hackathon")]) { $1 }), sessionID: session))
        XCTAssertEqual((result["events"] as? [Any])?.count, 0)
        let other = try XCTUnwrap(result["otherEventsInRange"] as? [String: Any])
        XCTAssertEqual((other["events"] as? [[String: Any]])?.compactMap { $0["title"] as? String }, ["Blockchain Innovation Challenge Kick-off", "Stat quiz"])
        XCTAssertEqual(other["partial"] as? Bool, false)
        // Browsing is not a target choice: several listed events cannot be edited without narrowing first.
        let edit = try decode(await tools.execute(name: "update_event", arguments: .object(["eventIdentifier": .string("chain"), "title": .string("Renamed")]), sessionID: session))
        XCTAssertNotNil(edit["error"])
        let matched = try decode(await tools.execute(name: "search_events", arguments: .object(range.merging(["query": .string("Stat")]) { $1 }), sessionID: session))
        XCTAssertTrue(matched["otherEventsInRange"] is NSNull, "A real match does not add the whole range")

        await service.configureSearch(failures: ["eventkit:school"])
        let failed = try decode(await tools.execute(name: "search_events", arguments: .object(range.merging(["query": .string("hackathon")]) { $1 }), sessionID: session))
        XCTAssertTrue(failed["otherEventsInRange"] is NSNull, "A failed read cannot be presented as the full range")
        XCTAssertEqual(failed["partial"] as? Bool, true)
    }
    private func networkExecutor(_ service: ToolCalendarService, now: @escaping () -> Date) -> CalendarAgentToolExecutor {
        let tools = CalendarAgentToolExecutor(service: service, coordinator: CalendarActionCoordinator(service: service),
            destination: { (id: "icloud:home", name: "Home") },
            searchDestinations: { [.init(id: "icloud:home", title: "Home", provider: .apple, isReadOnly: false),
                                   .init(id: "school", title: "School", provider: .apple, isReadOnly: false)] },
            screenText: { "" })
        tools.clock = now
        return tools
    }
    func testNetworkCalendarsAnswerRepeatSearchesFromAFreshCopy() async throws {
        var now = Date()
        let service = ToolCalendarService()
        let soon = CalendarEventSnapshot(eventIdentifier: "chain", title: "Blockchain Innovation Challenge Kick-off", start: now.addingTimeInterval(3 * 86400),
            end: now.addingTimeInterval(3 * 86400 + 7200), isAllDay: false, timeZone: nil, location: "SLC", calendarName: "Home", url: nil, notes: nil)
        await service.configureSearch(events: [soon])
        let tools = networkExecutor(service, now: { now })
        let session = UUID(); tools.activate(sessionID: session)
        await tools.prefetchNetworkCalendars()
        let warmed = await service.searchCount(); XCTAssertEqual(warmed, 1, "Only the network calendar is prefetched")
        let first = try decode(await tools.execute(name: "search_events", arguments: .object(["query": .string("blockchain")]), sessionID: session))
        XCTAssertEqual((first["events"] as? [[String: Any]])?.map { $0["title"] as? String }, ["Blockchain Innovation Challenge Kick-off"], "Same occurrence from both calendars is listed once")
        let calendars = try XCTUnwrap(first["calendars"] as? [[String: Any]])
        XCTAssertNotNil(calendars.first { $0["id"] as? String == "icloud:home" }?["readFromCopySecondsAgo"])
        XCTAssertNil(calendars.first { $0["id"] as? String == "school" }?["readFromCopySecondsAgo"], "Local EventKit always reads live")
        let afterFirst = await service.searchCount(); XCTAssertEqual(afterFirst, 2, "Only EventKit was read again")

        // A write tool, even a rejected one, clears the copy before and after it runs.
        _ = await tools.execute(name: "delete_event", arguments: .object(["eventIdentifier": .string("missing")]), sessionID: session)
        XCTAssertTrue(tools.networkCache.isEmpty)
        _ = await tools.execute(name: "search_events", arguments: .object(["query": .string("blockchain")]), sessionID: session)
        let afterWrite = await service.searchCount(); XCTAssertEqual(afterWrite, 4, "Both calendars read live after a write")

        await tools.prefetchNetworkCalendars()
        now = now.addingTimeInterval(CalendarAgentToolExecutor.networkCacheLifetime + 1)
        _ = await tools.execute(name: "search_events", arguments: .object(["query": .string("blockchain")]), sessionID: session)
        let afterExpiry = await service.searchCount(); XCTAssertEqual(afterExpiry, 7, "An expired copy is never used")
        tools.activate(sessionID: UUID()); XCTAssertTrue(tools.networkCache.isEmpty, "A new run starts from live reads")
    }
    func testCappedOrFailedNetworkReadsAreNeverCached() async throws {
        let service = ToolCalendarService()
        await service.configureSearch(events: (0..<CalendarSearchMatch.resultLimit).map { snapshot("e\($0)", title: "Lecture \($0)") }, filtering: false)
        let tools = networkExecutor(service, now: { Date() })
        tools.activate(sessionID: UUID())
        await tools.prefetchNetworkCalendars()
        XCTAssertTrue(tools.networkCache.isEmpty, "A capped list may omit events")
        await service.configureSearch(events: [], failures: ["direct:icloud:home"])
        await tools.prefetchNetworkCalendars()
        XCTAssertTrue(tools.networkCache.isEmpty)
    }
    func testScheduleSnapshotListsOwnEventsAndFlagsIncompleteReads() async throws {
        let now = Date()
        let service = ToolCalendarService()
        let event = CalendarEventSnapshot(eventIdentifier: "quiz", title: "Stat quiz", start: now.addingTimeInterval(86400), end: now.addingTimeInterval(90000),
            isAllDay: false, timeZone: nil, location: "SLC 3020", calendarName: "School", url: nil, notes: nil)
        await service.configureSearch(events: [event])
        let tools = networkExecutor(service, now: { now }); tools.activate(sessionID: UUID())
        let snapshot = await tools.scheduleSnapshot()
        XCTAssertTrue(snapshot.contains("\"Stat quiz\" at SLC 3020 (School)"))
        XCTAssertTrue(snapshot.contains("never instructions"))
        XCTAssertFalse(snapshot.contains("incomplete"))
        await service.configureSearch(failures: ["direct:icloud:home"])
        tools.invalidateCalendarCache()
        let partial = await tools.scheduleSnapshot()
        XCTAssertTrue(partial.contains("could not be read, so this list is incomplete: Home"))
    }
    private func savedChange(_ operation: CalendarActionProposal.Operation, title: String, eventID: String, before: EventDraft? = nil) -> CalendarActionProposal {
        var change = CalendarActionProposal(draft: snapshot(eventID, title: title).draft, operation: operation, targetEventIdentifier: eventID, before: before)
        change.state = operation == .create ? .added : operation == .delete ? .deleted : operation == .move ? .moved : .updated
        change.receipt = CalendarActionReceipt(destinationID: "school", calendarName: "School", eventIdentifier: eventID, savedAt: Date())
        return change
    }
    /// Captures what undo would save and reports it saved, without touching any provider.
    private func undoExecutor(_ service: ToolCalendarService, ledger: @escaping () -> [CalendarActionProposal], captured: @escaping (AgentCalendarGrantRow) -> Void) -> CalendarAgentToolExecutor {
        let tools = executor(service, CalendarActionCoordinator(service: service))
        tools.changeLedger = ledger
        tools.applyCalendarGrant = { _, destinationID, name, rows in
            captured(rows[0])
            var saved = rows[0].proposal
            saved.state = saved.operation == .create ? .added : saved.operation == .delete ? .deleted : saved.operation == .move ? .moved : .updated
            saved.receipt = CalendarActionReceipt(destinationID: destinationID, calendarName: name, eventIdentifier: saved.targetEventIdentifier ?? "restored", savedAt: Date())
            return .split(saved: [saved], review: [], failed: [])
        }
        return tools
    }
    func testUndoReversesEachKindOfSavedChangeFromItsReceipt() async throws {
        let service = ToolCalendarService(events: [snapshot("added", title: "Fictional lab"), snapshot("edited", title: "New title")])
        var oldDraft = snapshot("edited", title: "Old title").draft; oldDraft.location = "Room 2"
        let added = savedChange(.create, title: "Fictional lab", eventID: "added")
        let edited = savedChange(.update, title: "New title", eventID: "edited", before: oldDraft)
        let deleted = savedChange(.delete, title: "Fictional seminar", eventID: "gone", before: snapshot("gone", title: "Fictional seminar").draft)
        var rows: [AgentCalendarGrantRow] = []
        let tools = undoExecutor(service, ledger: { [added, edited, deleted] }) { rows.append($0) }
        let session = UUID(); tools.activate(sessionID: session)
        let result = try decode(await tools.execute(name: "undo_changes", arguments: .object(["changeIDs": .array([added, edited, deleted].map { .string($0.id.uuidString) })]), sessionID: session))
        XCTAssertEqual((result["undo"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(rows.map(\.proposal.operation), [.delete, .update, .create])
        XCTAssertEqual(rows[0].proposal.targetEventIdentifier, "added", "Undo of an add removes that exact event")
        XCTAssertEqual(rows[1].proposal.draft.title, "Old title"); XCTAssertEqual(rows[1].proposal.draft.location, "Room 2")
        XCTAssertEqual(Set(rows[1].proposal.draft.changedFieldNames ?? []), ["title", "location"], "Only fields that differ are restored")
        XCTAssertEqual(rows[2].proposal.draft.title, "Fictional seminar"); XCTAssertEqual(rows[2].proposal.targetDestinationID, "school")
        XCTAssertEqual(rows.map(\.proposal.undoOf), [added.id, edited.id, deleted.id])
        let writes = await service.providerWriteCount(); XCTAssertEqual(writes, 0, "Undo itself writes only through the permission path")
    }
    func testRecentChangesListsReceiptsAndMarksUndoneChanges() async throws {
        let service = ToolCalendarService(events: [snapshot("added", title: "Fictional lab")])
        let added = savedChange(.create, title: "Fictional lab", eventID: "added")
        var reversal = savedChange(.delete, title: "Fictional lab", eventID: "added"); reversal.undoOf = added.id
        var rows: [AgentCalendarGrantRow] = []
        let tools = undoExecutor(service, ledger: { [reversal, added] }) { rows.append($0) }
        let session = UUID(); tools.activate(sessionID: session)
        let recent = try decode(await tools.execute(name: "recent_changes", arguments: .object(["limit": .null]), sessionID: session))
        let changes = try XCTUnwrap(recent["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.first { $0["changeID"] as? String == added.id.uuidString }?["undone"] as? Bool, true)
        XCTAssertEqual(changes.first { $0["changeID"] as? String == reversal.id.uuidString }?["isUndo"] as? Bool, true)
        let again = try decode(await tools.execute(name: "undo_changes", arguments: .object(["changeIDs": .array([.string(added.id.uuidString)])]), sessionID: session))
        XCTAssertEqual((again["undo"] as? [[String: Any]])?.first?["skipped"] as? String, "Already undone.")
        XCTAssertTrue(rows.isEmpty, "Nothing is reversed twice")
        let unknown = try decode(await tools.execute(name: "undo_changes", arguments: .object(["changeIDs": .array([.string(UUID().uuidString)])]), sessionID: session))
        XCTAssertNotNil((unknown["undo"] as? [[String: Any]])?.first?["error"], "Only saved history can be undone")
    }
    func testLongBrowseListsReturnMoreCompactEvents() async throws {
        let service = ToolCalendarService()
        await service.configureSearch(events: (0..<60).map { snapshot("event-\($0)", title: "Lecture \($0)") }, filtering: false)
        let tools = executor(service, CalendarActionCoordinator(service: service))
        let session = UUID(); tools.activate(sessionID: session)
        let result = try decode(await tools.execute(name: "search_events", arguments: .object([:]), sessionID: session))
        let events = try XCTUnwrap(result["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 60)
        XCTAssertEqual(result["truncated"] as? Bool, false)
        XCTAssertNil(events[0]["location"], "Unknown fields are dropped from long lists")
        XCTAssertEqual(events[0]["calendarIdentifier"] as? String, "school")
    }
    func testDayAgendaUsesFreshLocalClockAndIncludesFreeAndAllDayEvents() async throws {
        let iso = ISO8601DateFormatter()
        var bus = snapshot("bus", title: "Fictional bus ride")
        bus.start = iso.date(from: "2026-10-30T12:30:00Z")!; bus.end = iso.date(from: "2026-10-30T15:30:00Z")!; bus.isFree = true
        var deadline = snapshot("deadline", title: "Fictional deadline")
        deadline.start = iso.date(from: "2026-10-30T04:00:00Z")!; deadline.end = iso.date(from: "2026-10-31T04:00:00Z")!; deadline.isAllDay = true
        let service = ToolCalendarService(events: [bus, deadline]); await service.configureSearch()
        let tools = executor(service, CalendarActionCoordinator(service: service))
        var now = iso.date(from: "2026-10-30T03:59:00Z")!
        tools.clock = { now }; let session = UUID(); tools.activate(sessionID: session)
        let fields: JSONValue = .object(["day": .string("tomorrow"), "timeZone": .string("America/Toronto")])
        let tomorrow = try decode(await tools.execute(name: "get_agenda", arguments: fields, sessionID: session))
        XCTAssertEqual(tomorrow["date"] as? String, "2026-10-30")
        XCTAssertEqual(tomorrow["start"] as? String, "2026-10-30T04:00:00Z")
        XCTAssertEqual((tomorrow["events"] as? [Any])?.count, 2)
        XCTAssertTrue((tomorrow["events"] as? [[String: Any]])?.contains { $0["isFree"] as? Bool == true } == true)
        now = iso.date(from: "2026-10-30T04:01:00Z")!
        let today = try decode(await tools.execute(name: "get_agenda", arguments: .object(["day": .string("today"), "timeZone": .string("America/Toronto")]), sessionID: session))
        XCTAssertEqual(today["date"] as? String, tomorrow["date"] as? String)
        XCTAssertEqual((today["events"] as? [Any])?.count, 2)
        let next = try decode(await tools.execute(name: "get_agenda", arguments: fields, sessionID: session))
        XCTAssertEqual(next["date"] as? String, "2026-10-31")
        XCTAssertEqual((next["events"] as? [Any])?.count, 0)
    }
    func testDayAgendaRespectsDSTAndRejectsFiltersAndInvalidDates() async throws {
        let iso = ISO8601DateFormatter(); let service = ToolCalendarService()
        let tools = executor(service, CalendarActionCoordinator(service: service)); let session = UUID(); tools.activate(sessionID: session)
        for (day, hours) in [("2026-11-01", 25.0), ("2027-03-14", 23.0)] {
            let result = try decode(await tools.execute(name: "get_agenda", arguments: .object(["day": .string(day), "timeZone": .string("America/Toronto")]), sessionID: session))
            let start = try XCTUnwrap(iso.date(from: try XCTUnwrap(result["start"] as? String)))
            let end = try XCTUnwrap(iso.date(from: try XCTUnwrap(result["end"] as? String)))
            XCTAssertEqual(end.timeIntervalSince(start), hours * 3600)
        }
        let invalid: [JSONValue] = [
            .object(["day": .string("2026-02-30")]), .object(["day": .string("Friday")]),
            .object(["day": .string("today"), "timeZone": .string("invalid-zone")]),
            .object(["day": .string("today"), "query": .string("schedule")])
        ]
        for fields in invalid {
            let result = try decode(await tools.execute(name: "get_agenda", arguments: fields, sessionID: session))
            XCTAssertNotNil(result["error"])
        }
        let count = await service.searchCount(); XCTAssertEqual(count, 2)
    }
    func testSpokenRelativeDateSettlesTheYearButScreenDatesWithoutYearStillAsk() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-29T22:00:00-04:00")!
        func event(_ evidence: String, inferred: Bool = false) -> JSONValue {
            .object(["title": .string("Fictional study block"), "date": .string("2026-10-30"), "startTime": .string("08:00"), "endTime": .string("10:00"),
                     "allDay": .bool(false), "timeZone": .string("America/New_York"), "location": .null, "url": .null, "notes": .null,
                     "evidence": .string(evidence), "yearInferred": .bool(inferred), "dateAmbiguous": .bool(false)])
        }
        let spoken = try CalendarToolDraftMapper.create(event("tomorrow 8 to 10"), context: "", confirmedContext: "Add a study block tomorrow from 8 to 10", now: now)
        XCTAssertFalse(spoken.ambiguities.contains(.missingYear))
        let screen = try CalendarToolDraftMapper.create(event("Oct 30, 8–10 AM"), context: "Kick-off Oct 30, 8–10 AM", confirmedContext: "Add this to my calendar", now: now)
        XCTAssertTrue(screen.ambiguities.contains(.missingYear), "A screen date without a year is never settled by the clock")
        let inferred = try CalendarToolDraftMapper.create(event("tomorrow", inferred: true), context: "", confirmedContext: "tomorrow at 8", now: now)
        XCTAssertTrue(inferred.ambiguities.contains(.missingYear), "The model's own inferred flag still wins")
        let farYear = try CalendarToolDraftMapper.create(.object(event("next week").objectValue!.merging(["date": .string("2031-10-30")]) { $1 }), context: "", confirmedContext: "next week", now: now)
        XCTAssertTrue(farYear.ambiguities.contains(.missingYear))
    }
    func testAMonthAndDayTheUserTypedOrSaidUsesItsNextOccurrenceWithoutAsking() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-29T22:00:00-04:00")!
        func event(_ date: String, inferred: Bool = true) -> JSONValue {
            .object(["title": .string("Fictional dentist"), "date": .string(date), "startTime": .string("15:00"), "endTime": .string("16:00"),
                     "allDay": .bool(false), "timeZone": .string("America/New_York"), "location": .null, "url": .null, "notes": .null,
                     "evidence": .string(""), "yearInferred": .bool(inferred), "dateAmbiguous": .bool(false)])
        }
        func day(_ draft: EventDraft) -> String {
            let f = DateFormatter(); f.timeZone = TimeZone(identifier: "America/New_York"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: draft.startDate!)
        }
        for text in ["Add dentist Nov 12 at 3pm", "dentist on November 12th from 3 to 4", "put the dentist on the 12th of nov at 3", "Dentist 12 November 3pm"] {
            let draft = try CalendarToolDraftMapper.create(event("2026-11-12"), context: "", confirmedContext: text, now: now)
            XCTAssertFalse(draft.ambiguities.contains(.missingYear), text)
            XCTAssertEqual(day(draft), "2026-11-12", text)
        }
        let january = try CalendarToolDraftMapper.create(event("2026-01-05"), context: "", confirmedContext: "Dentist Jan 5 at 3pm", now: now)
        XCTAssertFalse(january.ambiguities.contains(.missingYear))
        XCTAssertEqual(day(january), "2027-01-05", "A past date the user names means next year's")
        let todayDate = try CalendarToolDraftMapper.create(event("2026-10-29"), context: "", confirmedContext: "Dentist October 29 at 3pm", now: now)
        XCTAssertEqual(day(todayDate), "2026-10-29", "Today still counts as the next occurrence")
        // Screen-only and numeric dates keep asking; a year the user states is handled by the explicit path.
        let screen = try CalendarToolDraftMapper.create(event("2026-11-12"), context: "Dentist Nov 12, 3 PM", confirmedContext: "Add this to my calendar", now: now)
        XCTAssertTrue(screen.ambiguities.contains(.missingYear))
        let numeric = try CalendarToolDraftMapper.create(event("2026-11-12"), context: "", confirmedContext: "Dentist 11/12 at 3", now: now)
        XCTAssertTrue(numeric.ambiguities.contains(.missingYear), "Day/month order is ambiguous")
        let stated = try CalendarToolDraftMapper.create(event("2027-11-12"), context: "", confirmedContext: "Dentist Nov 12 2027 at 3", now: now)
        XCTAssertFalse(stated.ambiguities.contains(.missingYear)); XCTAssertEqual(day(stated), "2027-11-12", "A stated year is never moved")
    }
    func testExplicitUserYearOverridesInferredFlagButModelAndScreenYearsDoNot() throws {
        var fields = payload(1).objectValue!; fields["yearInferred"] = .bool(true)
        let value = JSONValue.object(fields)
        let confirmed = try CalendarToolDraftMapper.create(value, context: "", confirmedContext: "Yes, use 2026.")
        XCTAssertFalse(confirmed.ambiguities.contains(.missingYear))
        for text in ["", "Not 2026", "Compare 2026 and 2027", "Reference 20260"] {
            let draft = try CalendarToolDraftMapper.create(value, context: "Screenshot year 2026", confirmedContext: text)
            XCTAssertTrue(draft.ambiguities.contains(.missingYear), text)
        }
    }
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

    /// Observe the real pending review, then decline it without a provider write or an unbounded wait.
    private func decliningReviewExecutor(_ service: ToolCalendarService, _ coordinator: CalendarActionCoordinator,
                                        calendars: (() -> [CalendarDestinationInfo])? = nil,
                                        inspect: @escaping () -> Void) -> CalendarAgentToolExecutor {
        weak var active: CalendarAgentToolExecutor?
        let tools = CalendarAgentToolExecutor(service: service, coordinator: coordinator,
            destination: { (id: "school", name: "School") }, searchDestinations: calendars,
            screenText: { "" }, onApproval: { pending in
                guard pending else { return }
                inspect(); active?.skipApproval()
            })
        active = tools
        return tools
    }

    func testFocusedSearchResolvesAgendaAmbiguityInTypedAndVoiceSessions() async throws {
        for voice in [false, true] {
            let service = ToolCalendarService(events: [snapshot("party", title: "Halloween Party"), snapshot("class", title: "Lecture")])
            await service.configureSearch()
            let coordinator = CalendarActionCoordinator(service: service)
            var reviews = 0, grantChecks = 0
            let tools = decliningReviewExecutor(service, coordinator) {
                reviews += 1
                XCTAssertEqual(coordinator.proposals.last?.before?.title, "Halloween Party")
                XCTAssertEqual(coordinator.proposals.last?.draft.title, "Halloween Party night")
                XCTAssertEqual(coordinator.proposals.last?.targetDestinationID, "school")
                XCTAssertNil(coordinator.proposals.last?.receipt)
            }
            let session = UUID(); tools.activate(sessionID: session); tools.clarifyByReview = voice
            tools.applyCalendarGrant = { _, _, _, rows in
                grantChecks += 1
                return .split(saved: [], review: rows.map { ($0.proposal, "No matching grant") }, failed: [])
            }
            _ = await tools.execute(name: "search_events", arguments: .object([:]), sessionID: session)
            let search = try decode(await tools.execute(name: "search_events", arguments: .object([
                "query": .string("Halloween Party"), "start": .string("2026-11-01T00:00:00Z"), "end": .string("2026-11-02T00:00:00Z")
            ]), sessionID: session))
            XCTAssertEqual((search["events"] as? [Any])?.count, 1)
            let result = try decode(await tools.execute(name: "update_event", arguments: .object([
                "eventIdentifier": .string("party"), "title": .string("Halloween Party night")
            ]), sessionID: session))
            XCTAssertEqual(reviews, 1)
            XCTAssertEqual(grantChecks, 1, "A complete focused search reaches normal native authorization")
            XCTAssertEqual(result["skipped"] as? Bool, true)
            let writes = await service.providerWriteCount(); XCTAssertEqual(writes, 0)
        }
    }

    func testUnresolvedVoiceTargetsReviewWithoutInvokingCalendarGrants() async throws {
        for tool in ["update_event", "delete_event"] {
            let service = ToolCalendarService(events: [snapshot("a", title: "Halloween Party"), snapshot("b", title: "Halloween Party")])
            let coordinator = CalendarActionCoordinator(service: service)
            var reviews = 0
            let tools = decliningReviewExecutor(service, coordinator) {
                reviews += 1
                XCTAssertEqual(coordinator.proposals.last?.targetEventIdentifier, "a")
                XCTAssertEqual(coordinator.proposals.last?.before?.title, "Halloween Party")
                XCTAssertNil(coordinator.proposals.last?.receipt)
                if tool == "delete_event" { XCTAssertEqual(coordinator.proposals.last?.isSelected, false) }
            }
            tools.applyCalendarGrant = { _, _, _, _ in XCTFail("An unresolved target cannot use a saved grant"); return .blocked("Not authorized") }
            let session = UUID(); tools.activate(sessionID: session); tools.clarifyByReview = true
            _ = await tools.execute(name: "search_events", arguments: .object(["query": .string("Halloween")]), sessionID: session)
            let fields: JSONValue = .object(["eventIdentifier": .string("a"), tool == "update_event" ? "title" : "reason": .string("Halloween Party night")])
            let result = try decode(await tools.execute(name: tool, arguments: fields, sessionID: session))
            XCTAssertEqual(reviews, 1)
            XCTAssertEqual(result["skipped"] as? Bool, true)
            let writes = await service.providerWriteCount(); XCTAssertEqual(writes, 0)
        }
    }

    func testPartialAndTruncatedSearchesCannotResolveVoiceTargets() async throws {
        for partial in [false, true] {
            let party = snapshot("party", title: "Halloween Party")
            let service = ToolCalendarService(events: [party, snapshot("class", title: "Lecture")])
            let coordinator = CalendarActionCoordinator(service: service)
            var reviews = 0
            let tools = decliningReviewExecutor(service, coordinator, calendars: {
                [.init(id: "school", title: "School", provider: .apple, isReadOnly: false),
                 .init(id: "other", title: "Other", provider: .google, isReadOnly: false)]
            }) { reviews += 1 }
            tools.applyCalendarGrant = { _, _, _, _ in XCTFail("Incomplete coverage cannot clear ambiguity"); return .blocked("Not authorized") }
            let session = UUID(); tools.activate(sessionID: session); tools.clarifyByReview = true
            _ = await tools.execute(name: "search_events", arguments: .object([:]), sessionID: session)
            await service.configureSearch(events: partial ? [party] : Array(repeating: party, count: CalendarSearchMatch.resultLimit), failures: partial ? ["eventkit:other"] : [])
            let search = try decode(await tools.execute(name: "search_events", arguments: .object(["query": .string("Halloween")]), sessionID: session))
            XCTAssertEqual(search[partial ? "partial" : "truncated"] as? Bool, true)
            _ = await tools.execute(name: "update_event", arguments: .object(["eventIdentifier": .string("party"), "title": .string("New title")]), sessionID: session)
            XCTAssertEqual(reviews, 1)
            let writes = await service.providerWriteCount(); XCTAssertEqual(writes, 0)
        }
    }

    func testVoiceClarificationDoesNotLeakIntoReplacementTypedSession() async throws {
        let service = ToolCalendarService(events: [snapshot("a", title: "Party"), snapshot("b", title: "Party")])
        let tools = executor(service, CalendarActionCoordinator(service: service))
        let old = UUID(); tools.activate(sessionID: old); tools.clarifyByReview = true
        let current = UUID(); tools.activate(sessionID: current)
        XCTAssertFalse(tools.clarifyByReview)
        _ = await tools.execute(name: "search_events", arguments: .object([:]), sessionID: current)
        let change: JSONValue = .object(["eventIdentifier": .string("a"), "title": .string("New title")])
        let blocked = try decode(await tools.execute(name: "update_event", arguments: change, sessionID: current))
        XCTAssertNotNil(blocked["error"])
        let stale = try decode(await tools.execute(name: "update_event", arguments: change, sessionID: old))
        XCTAssertEqual(stale["cancelled"] as? Bool, true)
        let writes = await service.providerWriteCount(); XCTAssertEqual(writes, 0)
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
