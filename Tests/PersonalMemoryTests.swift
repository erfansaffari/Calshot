import XCTest
@testable import Calshot

final class PersonalMemoryTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("PersonalMemoryTests-" + UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
    func testRoundTripAndPermissions() throws {
        let owner = UUID(), store = PersonalMemoryStore(directory: directory, ownerID: nil)
        let item = try store.add(kind: .preference, text: "  Quiet mornings  ", now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(item.text, "Quiet mornings")
        XCTAssertEqual(PersonalMemoryStore(directory: directory).items, [item])
        XCTAssertNotNil(PersonalMemoryStore(directory: directory, ownerID: owner).error)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testClearHistoryPreservesEverySiblingStore() throws {
        let history = MemoryStore(directoryURL: directory)
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let record = try history.recordCapture(imageData: png)
        let appended = try XCTUnwrap(history.appendScreenshot(for: record.id, imageData: png, recognizedText: "Fictional screenshot", proposals: []))
        let command = try history.recordCommand("Fictional request")
        let memory = PersonalMemoryStore(directory: directory)
        let item = try memory.add(kind: .preference, text: "Fictional preference")
        try memory.remove(id: item.id, expectedVersion: item.version)
        let siblingNames = ["tasks-v1.json", "calendar-direct-journal.json", "agent-permissions.json", "agent-permissions.lock", ".calshot-account", "AgentPermissions/agent-permissions.json", "AgentPermissions/nested/retained.json", "unrelated.txt"]
        for name in siblingNames {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Fictional sibling: \(name)".utf8).write(to: url)
        }
        let memoryBytes = try Data(contentsOf: memory.url)
        try history.deleteAll()
        XCTAssertTrue(history.listRecords().isEmpty)
        for name in [record.id.uuidString + ".json", command.id.uuidString + ".json", record.screenshotFileName] + (appended.additionalScreenshots ?? []).map(\.fileName) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), name)
        }
        for name in siblingNames { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), Data("Fictional sibling: \(name)".utf8)) }
        XCTAssertEqual(try Data(contentsOf: memory.url), memoryBytes)
        XCTAssertThrowsError(try PersonalMemoryStore(directory: directory).suggest(kind: .preference, text: "Fictional preference"))
    }
    func testCorruptFileKeptAndWritesBlocked() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("personal-memory-v1.json"), bytes = Data("broken fictional file".utf8)
        try bytes.write(to: url)
        let store = PersonalMemoryStore(directory: directory)
        XCTAssertNotNil(store.error)
        XCTAssertThrowsError(try store.add(kind: .fact, text: "Fictional fact"))
        XCTAssertThrowsError(try store.clear(confirmed: true))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testDedupePerKindAndValidation() throws {
        let store = PersonalMemoryStore(directory: directory)
        try store.add(kind: .fact, text: "Quiet   Mornings")
        XCTAssertThrowsError(try store.suggest(kind: .fact, text: "quiet mornings"))
        try store.add(kind: .preference, text: "quiet mornings")
        XCTAssertThrowsError(try store.add(kind: .fact, text: "  \n"))
        XCTAssertThrowsError(try store.add(kind: .fact, text: String(repeating: "x", count: 501)))
        XCTAssertEqual(store.items.count, 2)
    }
    func testSuggestionApprovalAndStaleEdit() throws {
        let store = PersonalMemoryStore(directory: directory)
        let item = try store.suggest(kind: .routine, text: "Read on Sundays")
        XCTAssertEqual(item.status, .pendingApproval)
        XCTAssertEqual(MemoryContextBuilder.build(request: "read", items: store.items), "")
        try store.change(id: item.id, expectedVersion: item.version, approve: true)
        XCTAssertEqual(store.items.first?.status, .active)
        XCTAssertThrowsError(try store.change(id: item.id, expectedVersion: item.version, text: "stale"))
        XCTAssertThrowsError(try store.remove(id: item.id, expectedVersion: item.version))
    }
    func testForgetAndRejectTombstonesSurviveRestart() throws {
        var store = PersonalMemoryStore(directory: directory)
        let item = try store.add(kind: .fact, text: "Lives in Fictionville")
        try store.remove(id: item.id, expectedVersion: item.version)
        store = PersonalMemoryStore(directory: directory)
        XCTAssertThrowsError(try store.suggest(kind: .person, text: " LIVES IN Fictionville "))
        XCTAssertThrowsError(try store.add(kind: .fact, text: "Lives in Fictionville"))
        let rejected = try store.suggest(kind: .routine, text: "Read at noon")
        try store.remove(id: rejected.id, expectedVersion: rejected.version, forget: false)
        XCTAssertNoThrow(try store.suggest(kind: .routine, text: "Read at noon"))
    }
    func testClearRequiresConfirmationAndSuppressesAll() throws {
        let store = PersonalMemoryStore(directory: directory)
        try store.add(kind: .fact, text: "Fictional fact")
        XCTAssertThrowsError(try store.clear(confirmed: false)); XCTAssertEqual(store.items.count, 1)
        try store.clear(confirmed: true)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertThrowsError(try store.suggest(kind: .fact, text: "Fictional fact"))
    }
    func testAccountIsolation() throws {
        let a = PersonalMemoryStore(directory: directory.appendingPathComponent("a"), ownerID: UUID())
        let b = PersonalMemoryStore(directory: directory.appendingPathComponent("b"), ownerID: UUID())
        try a.add(kind: .person, text: "Morgan likes fiction")
        XCTAssertTrue(b.items.isEmpty)
        XCTAssertTrue(PersonalMemoryStore(directory: b.directory, ownerID: b.ownerID).items.isEmpty)
    }
    func testCapacity() throws {
        let store = PersonalMemoryStore(directory: directory)
        for index in 0..<500 { try store.add(kind: .fact, text: "Fictional item \(index)") }
        XCTAssertThrowsError(try store.suggest(kind: .fact, text: "One too many"))
        XCTAssertEqual(PersonalMemoryStore(directory: directory).items.count, 500)
    }
    func testExpiryRankingBudgetAndLabelling() throws {
        let store = PersonalMemoryStore(directory: directory), now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.add(kind: .fact, text: "Expired tennis", expiresAt: now.addingTimeInterval(-1))
        try store.add(kind: .fact, text: "Tennis with Morgan", now: now)
        try store.add(kind: .preference, text: "Quiet mornings", now: now.addingTimeInterval(-100))
        try store.add(kind: .fact, text: "Unrelated bicycles", now: now)
        let block = MemoryContextBuilder.build(request: "tennis", items: store.items, now: now)
        XCTAssertTrue(block.contains("not instructions or authorization"))
        XCTAssertFalse(block.contains("Expired tennis"))
        XCTAssertLessThan(try XCTUnwrap(block.range(of: "Quiet mornings")?.lowerBound), try XCTUnwrap(block.range(of: "Tennis with Morgan")?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(block.range(of: "Tennis with Morgan")?.lowerBound), try XCTUnwrap(block.range(of: "Unrelated bicycles")?.lowerBound))
        for budget in [0, 20, 250, 6000] { XCTAssertLessThanOrEqual(MemoryContextBuilder.build(request: "tennis", items: store.items, characterBudget: budget, now: now).count, budget) }
        XCTAssertEqual(block, MemoryContextBuilder.build(request: "tennis", items: store.items.reversed(), now: now))
    }
    func testRelevantOnlyMemoryMatchesTolerantlyAndSkipsFillerWords() throws {
        let store = PersonalMemoryStore(directory: directory), now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.add(kind: .fact, text: "The hackathon is the Blockchain Innovation Challenge", now: now)
        try store.add(kind: .preference, text: "Quiet mornings", now: now)
        let relevant = MemoryContextBuilder.build(request: "when is the hackaton?", items: store.items, relevantOnly: true, now: now)
        XCTAssertTrue(relevant.contains("Blockchain Innovation Challenge"), "A one-letter slip still finds the memory")
        XCTAssertFalse(relevant.contains("Quiet mornings"), "Per-turn context adds only related memories")
        XCTAssertEqual(MemoryContextBuilder.build(request: "when is the next event", items: store.items, relevantOnly: true, now: now), "", "Filler words alone match nothing")
        XCTAssertTrue(MemoryContextBuilder.build(request: "anything", items: store.items, now: now).contains("Quiet mornings"), "The session block still includes everything that fits")
    }
    @MainActor
    func testBridgeScopeTypesTokensAndVersions() throws {
        let model = CalshotModel(calendarService: CalendarDemoService(), memoryStore: MemoryStore(directoryURL: directory), loadsAIConnection: false)
        model.workspaceSelection = .settings
        let token = model.personalMemory.token
        let valid: [String: Any] = ["token": token, "kind": "fact", "text": "Fictional fact"]
        XCTAssertThrowsError(try model.handlePersonalMemoryAction("addMemory", body: valid, isNotch: true))
        XCTAssertThrowsError(try model.handlePersonalMemoryAction("addMemory", body: ["token": token, "kind": "fact", "text": 123], isNotch: false))
        XCTAssertThrowsError(try model.handlePersonalMemoryAction("clearMemory", body: ["token": token, "confirmed": 1], isNotch: false))
        try model.handlePersonalMemoryAction("addMemory", body: valid, isNotch: false)
        XCTAssertThrowsError(try model.handlePersonalMemoryAction("addMemory", body: valid, isNotch: false))
        let item = try XCTUnwrap(model.personalMemory.items.first)
        try model.handlePersonalMemoryAction("editMemory", body: ["token": model.personalMemory.token, "memoryID": item.id.uuidString, "expectedVersion": item.version.uuidString, "kind": "person", "text": "Fictional Morgan"], isNotch: false)
        XCTAssertThrowsError(try model.handlePersonalMemoryAction("forgetMemory", body: ["token": model.personalMemory.token, "memoryID": item.id.uuidString, "expectedVersion": item.version.uuidString], isNotch: false))
        model.workspaceSelection = .library
        XCTAssertThrowsError(try model.handlePersonalMemoryAction("clearMemory", body: ["token": model.personalMemory.token, "confirmed": true], isNotch: false))
    }
    @MainActor
    func testContextIsSentButNeverPersistedInTranscript() async throws {
        let client = MemoryFixtureClient()
        let executor = MemoryFixtureExecutor()
        let agent = CalendarAgent(client: client, executor: executor)
        try await agent.start(userMessage: "Recall my preference", imageDataURL: nil, personalMemoryContext: "PRIVATE_MEMORY_FIXTURE")
        XCTAssertTrue(client.receivedInstructions.contains("PRIVATE_MEMORY_FIXTURE"))
        let persisted = String(data: try JSONEncoder().encode(agent.transcript), encoding: .utf8)!
        XCTAssertFalse(persisted.contains("PRIVATE_MEMORY_FIXTURE"))
        XCTAssertFalse(persisted.contains("PRIVATE_RECALL_FIXTURE"))
    }
    @MainActor
    func testToolsPendingOnlyValidationAndSharedContext() async throws {
        let store = PersonalMemoryStore(directory: directory)
        let executor = CalendarAgentToolExecutor(service: CalendarDemoService(), coordinator: CalendarActionCoordinator(service: CalendarDemoService()), destination: { nil }, screenText: { "" })
        executor.remember = { kind, text, _ in try store.suggest(kind: kind, text: text); return "pendingApproval" }
        executor.recall = { MemoryContextBuilder.build(request: $0, items: store.items) }
        let run = UUID(); executor.activate(sessionID: run)
        let args: JSONValue = .object(["kind": .string("fact"), "text": .string("Fictional fact")])
        let result = await executor.execute(name: "remember", arguments: args, sessionID: run)
        XCTAssertTrue(result.contains("pendingApproval")); XCTAssertEqual(store.items.first?.status, .pendingApproval)
        let bad = await executor.execute(name: "remember", arguments: .object(["kind": .string("fact"), "text": .number(2)]), sessionID: run)
        XCTAssertTrue(bad.contains("error")); XCTAssertEqual(store.items.count, 1)
        _ = await executor.execute(name: "list_friends", arguments: .object([:]), sessionID: run)
        let blocked = await executor.execute(name: "remember", arguments: args, sessionID: run)
        XCTAssertTrue(blocked.contains("error"))
        XCTAssertTrue(CalendarAgent.tools.contains { $0.objectValue?["name"] == .string("remember") })
    }
}

@MainActor
private final class MemoryFixtureClient: CalendarAgentModelClient {
    var receivedInstructions = ""
    var turns = 0
    func turn(conversation: [AgentMessage], imageDataURL: String?, instructions: String, tools: [JSONValue], onText: @escaping @MainActor (String) -> Void) async throws -> AgentModelResponse {
        receivedInstructions = instructions; turns += 1
        if turns == 1 { return .init(calls: [.init(name: "recall", callID: "fixture", arguments: "{\"query\":\"preference\"}")]) }
        return .init(text: "Done")
    }
}
@MainActor
private final class MemoryFixtureExecutor: CalendarAgentToolExecuting {
    func execute(name: String, arguments: JSONValue, sessionID: UUID) async -> String { "PRIVATE_RECALL_FIXTURE" }
    func cancelPending(sessionID: UUID) {}
}

/// Context engine: learned knowledge, behavior signals, calendar profile, reflection and spoken dates.
final class ContextEngineTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("ContextEngineTests-" + UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }

    func testVersionOneFilesStillLoadAndSaveAsVersionTwo() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = #"{"schemaVersion":1,"items":[{"id":"2F9A6B7C-1D2E-4F30-8A9B-0C1D2E3F4A5B","version":"3A9A6B7C-1D2E-4F30-8A9B-0C1D2E3F4A5B","kind":"preference","text":"Fictional quiet mornings","origin":"explicit","status":"active","createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-01T00:00:00Z"}],"tombstones":[]}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("personal-memory-v1.json"))
        let store = PersonalMemoryStore(directory: directory)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.items.first?.text, "Fictional quiet mornings")
        XCTAssertNil(store.items.first?.source)
        try store.learn(kind: .fact, text: "Fictional fact", source: .user)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
        XCTAssertEqual(saved?["schemaVersion"] as? Int, 2)
        XCTAssertEqual(PersonalMemoryStore(directory: directory).items.count, 2)
    }

    func testLearningSavesAtOnceReinforcesSupersedesAndNeverRelearnsForgottenText() throws {
        let store = PersonalMemoryStore(directory: directory), now = Date(timeIntervalSince1970: 1_800_000_000)
        guard case .added(let first) = try store.learn(kind: .routine, text: "Fictional gym on Mondays", source: .conversation, confidence: 0.6, now: now) else { return XCTFail("Not added") }
        XCTAssertEqual(first.status, .active); XCTAssertEqual(first.origin, .learned)
        XCTAssertNotNil(first.expiresAt, "An unconfirmed inference expires unless it is seen again")
        guard case .reinforced(let again) = try store.learn(kind: .routine, text: "fictional GYM on mondays", source: .user, now: now) else { return XCTFail("Not reinforced") }
        XCTAssertEqual(again.evidenceCount, 2); XCTAssertEqual(again.source, .user); XCTAssertNil(again.expiresAt)
        guard case .updated(let moved) = try store.learn(kind: .routine, text: "Fictional gym on Tuesdays", source: .user, replacing: first.id, now: now) else { return XCTFail("Not updated") }
        XCTAssertEqual(moved.id, first.id); XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(try store.learn(kind: .routine, text: "Fictional gym on Mondays", source: .conversation, now: now), .forgottenBefore, "Superseded text is never re-learned")
        try store.forget(id: moved.id)
        XCTAssertEqual(try store.learn(kind: .fact, text: "Fictional gym on Tuesdays", source: .user), .forgottenBefore)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRepeatedInterruptionsBecomeAShortReplyStyleThatLeadsContext() throws {
        let store = PersonalMemoryStore(directory: directory), now = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<4 { try store.recordVoiceReply(interrupted: false, now: now) }
        XCTAssertFalse(try store.recordVoiceReply(interrupted: true, now: now))
        XCTAssertFalse(try store.recordVoiceReply(interrupted: true, now: now))
        XCTAssertTrue(try store.recordVoiceReply(interrupted: true, now: now), "Third interruption in a quarter of replies")
        let style = try XCTUnwrap(store.items.first { $0.kind == .style })
        XCTAssertEqual(style.text, PersonalMemoryStore.shortRepliesText); XCTAssertEqual(style.source, .behavior)
        try store.add(kind: .fact, text: "Fictional fact about lunch")
        let context = MemoryContextBuilder.build(request: "lunch", items: store.items, relevantOnly: true, now: now)
        XCTAssertTrue(context.contains("Keep spoken replies short"), "Style is sent even when it shares no words with the request")
        XCTAssertLessThan(try XCTUnwrap(context.range(of: "[style")).lowerBound, try XCTUnwrap(context.range(of: "[fact")).lowerBound)
        // A forgotten style is not brought back by more interruptions.
        try store.forget(id: style.id)
        XCTAssertFalse(try store.recordVoiceReply(interrupted: true, now: now))
        XCTAssertFalse(store.items.contains { $0.kind == .style })
    }

    private func event(_ title: String, _ start: Date, minutes: Int, location: String? = nil) -> CalendarEventSnapshot {
        CalendarEventSnapshot(eventIdentifier: UUID().uuidString, title: title, start: start, end: start.addingTimeInterval(Double(minutes) * 60), isAllDay: false,
                              timeZone: "UTC", location: location, calendarName: "Fictional", url: nil, notes: nil)
    }

    func testCalendarProfileFindsRoutinesLengthsAndPlaces() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9, minute: 30)))
        var events: [CalendarEventSnapshot] = []
        for week in 0..<6 {
            let day = monday.addingTimeInterval(Double(week) * 7 * 86_400)
            events.append(event("Fictional Stats Lecture", day, minutes: 80, location: "Fictional Hall 2"))
            events.append(event("Fictional standup", day.addingTimeInterval(2 * 86_400 - 1800), minutes: 15))
        }
        events.append(event("Fictional dentist", monday.addingTimeInterval(86_400), minutes: 45))
        events.append(event("Fictional dentist", monday.addingTimeInterval(20 * 86_400), minutes: 45))
        let profile = CalendarProfile.build(events: events, now: monday.addingTimeInterval(21 * 86_400), calendar: calendar)
        let lecture = try XCTUnwrap(profile.routines.first { $0.title == "Fictional Stats Lecture" })
        XCTAssertEqual(lecture.weekdays, [2]); XCTAssertEqual(lecture.startMinute, 9 * 60 + 30); XCTAssertEqual(lecture.durationMinutes, 80)
        XCTAssertEqual(profile.typicalDuration(for: "fictional dentist"), 45)
        XCTAssertEqual(profile.typicalDuration(for: "Fictional stats lecture 7"), 80, "Numbers in a title do not change what it is")
        XCTAssertNil(profile.typicalDuration(for: "Something unrelated"))
        XCTAssertEqual(profile.places.first?.name, "Fictional Hall 2")
        let context = profile.context(calendar: calendar)
        XCTAssertTrue(context.contains("routine: \"Fictional Stats Lecture\" on Mon around 09:30"))
        XCTAssertTrue(context.contains("Never use them to fill a date or time"))
        XCTAssertEqual(CalendarProfile.build(events: [], now: monday).context(), "")
    }

    func testReflectionAddsUpdatesAndOnlyForgetsWhatCalshotInferred() throws {
        let store = PersonalMemoryStore(directory: directory)
        guard case .added(let said) = try store.learn(kind: .preference, text: "Fictional meetings after 10", source: .user),
              case .added(let guessed) = try store.learn(kind: .fact, text: "Fictional guess about chess", source: .conversation, confidence: 0.5) else { return XCTFail() }
        let arguments = JSONValue.object(["operations": .array([
            .object(["op": .string("add"), "kind": .string("person"), "text": .string("Has a fictional sister named Mira"), "memoryID": .null, "confidence": .number(0.95), "userAskedToForget": .bool(false)]),
            .object(["op": .string("forget"), "kind": .null, "text": .null, "memoryID": .string(said.id.uuidString), "confidence": .number(0.7), "userAskedToForget": .bool(false)]),
            .object(["op": .string("update"), "kind": .string("preference"), "text": .string("Fictional meetings after 11"), "memoryID": .string(said.id.uuidString), "confidence": .number(0.6), "userAskedToForget": .bool(false)]),
            .object(["op": .string("forget"), "kind": .null, "text": .null, "memoryID": .string(guessed.id.uuidString), "confidence": .number(0.7), "userAskedToForget": .bool(false)]),
            .object(["op": .string("add"), "kind": .string("fact"), "text": .string("Weak"), "memoryID": .null, "confidence": .number(0.2), "userAskedToForget": .bool(false)])])]).jsonString()
        let operations = ContextReflection.parse(arguments)
        XCTAssertEqual(operations.count, 5)
        XCTAssertEqual(ContextReflection.apply(operations, to: store), 2)
        XCTAssertTrue(store.items.contains { $0.text == "Has a fictional sister named Mira" && $0.source == .user })
        XCTAssertTrue(store.items.contains { $0.id == said.id && $0.text == "Fictional meetings after 10" }, "What the user said is kept unless they asked or a confident update replaces it")
        XCTAssertFalse(store.items.contains { $0.id == guessed.id })
        XCTAssertFalse(store.items.contains { $0.text == "Weak" })
        XCTAssertTrue(ContextReflection.parse("not json").isEmpty)
    }

    func testSpokenDatesNeverAskForAYearAndUseTheUsualLength() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15
        func draft(_ fields: [String: JSONValue], evidence: String = "") throws -> EventDraft {
            var row: [String: JSONValue] = ["title": .string("Fictional dentist"), "date": .string("2026-03-04"), "startTime": .string("15:00"), "endTime": .null,
                "allDay": .bool(false), "timeZone": .string("UTC"), "location": .null, "url": .null, "notes": .null, "evidence": .string(evidence), "yearInferred": .bool(true), "dateAmbiguous": .bool(false)]
            for (key, value) in fields { row[key] = value }
            return try CalendarToolDraftMapper.create(.object(row), context: evidence, now: now, spoken: true, typicalMinutes: { _ in 30 })
        }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let next = try draft([:], evidence: "Dentist March 4 3pm")
        XCTAssertTrue(next.ambiguities.isEmpty, "\(next.ambiguities)")
        XCTAssertEqual(next.startDate.map { utc.component(.year, from: $0) }, 2027)
        XCTAssertEqual(next.endDate?.timeIntervalSince(next.startDate!), 1800)
        let shown = try draft(["date": .string("2029-03-04")], evidence: "Dentist March 4 2029 3pm")
        XCTAssertEqual(shown.startDate.map { utc.component(.year, from: $0) }, 2029)
        let untimed = try draft(["startTime": .null])
        XCTAssertTrue(untimed.ambiguities.contains(.missingTime), "A missing time stays open so the agent asks aloud")
        let birthday = try draft(["startTime": .null, "allDay": .bool(true)])
        XCTAssertFalse(birthday.ambiguities.contains(.missingTime))
        let late = try draft(["startTime": .string("22:00"), "endTime": .string("01:00")])
        XCTAssertEqual(late.endDate?.timeIntervalSince(late.startDate!), 3 * 3600, "An end before the start is the next day")
        // Typed requests keep the existing review rules.
        let typed = try CalendarToolDraftMapper.create(.object(["title": .string("Fictional dentist"), "date": .string("2026-03-04"), "startTime": .string("15:00"), "endTime": .null,
            "allDay": .bool(false), "timeZone": .string("UTC"), "location": .null, "url": .null, "notes": .null, "evidence": .string(""), "yearInferred": .bool(true), "dateAmbiguous": .bool(false)]), context: "", now: now)
        XCTAssertTrue(typed.ambiguities.contains(.missingYear)); XCTAssertTrue(typed.ambiguities.contains(.missingEndTime))
    }

    @MainActor
    func testRememberSavesImmediatelyAndForgetMemoryRemoves() async throws {
        let store = PersonalMemoryStore(directory: directory)
        let executor = CalendarAgentToolExecutor(service: CalendarDemoService(), coordinator: CalendarActionCoordinator(service: CalendarDemoService()), destination: { nil }, screenText: { "" })
        executor.remember = { kind, text, replacing in
            switch try store.learn(kind: kind, text: text, source: .user, replacing: replacing) {
            case .added: return "saved"; case .updated: return "updated"; case .reinforced: return "alreadyKnown"; case .forgottenBefore: return "forgotten"
            }
        }
        executor.forgetMemory = { id in try store.forget(id: id); return "forgotten" }
        executor.recall = { MemoryContextBuilder.build(request: $0, items: store.items, withIDs: true) }
        let run = UUID(); executor.activate(sessionID: run)
        let saved = await executor.execute(name: "remember", arguments: .object(["kind": .string("preference"), "text": .string("Fictional tea not coffee"), "replacesMemoryID": .null]), sessionID: run)
        XCTAssertTrue(saved.contains("\"saved\"")); XCTAssertEqual(store.items.first?.status, .active)
        let id = try XCTUnwrap(store.items.first?.id)
        let recalled = await executor.execute(name: "recall", arguments: .object(["query": .string("tea")]), sessionID: run)
        XCTAssertTrue(recalled.contains(id.uuidString))
        let bad = await executor.execute(name: "remember", arguments: .object(["kind": .string("fact"), "text": .string("x"), "replacesMemoryID": .string("not-an-id")]), sessionID: run)
        XCTAssertTrue(bad.contains("error"))
        _ = await executor.execute(name: "forget_memory", arguments: .object(["memoryID": .string(id.uuidString)]), sessionID: run)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(CalendarAgent.tools.contains { $0.objectValue?["name"] == .string("forget_memory") })
    }
}

/// Knowledge sync merge rules. No network: the store's outgoing/apply logic the sync loop uses.
final class KnowledgeSyncTests: XCTestCase {
    var directory: URL!
    let owner = UUID()
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeSyncTests-" + UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
    private func remote(_ text: String, id: UUID = UUID(), kind: MemoryItem.Kind = .fact, at: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> PersonalMemoryStore.RemoteItem {
        let item = MemoryItem(id: id, ownerID: owner, kind: kind, text: text, origin: .learned, status: .active, createdAt: at, updatedAt: at, source: .conversation, confidence: 0.8, evidenceCount: 1, lastSeenAt: at)
        return .init(id: id, item: item, deleted: false, updatedAt: at)
    }

    func testLocalChangesGoOutOnceAndForgetsTravelAsDeletesAndTombstones() throws {
        let store = PersonalMemoryStore(directory: directory, ownerID: owner)
        guard case .added(let item) = try store.learn(kind: .fact, text: "Fictional fact", source: .user) else { return XCTFail() }
        var out = store.outgoingChanges()
        XCTAssertEqual(out.items.map(\.id), [item.id]); XCTAssertTrue(out.deletes.isEmpty)
        try store.markSent(out)
        XCTAssertTrue(store.outgoingChanges().isEmpty)
        try store.learn(kind: .fact, text: "Fictional fact", source: .user) // reinforced: new version goes out again
        XCTAssertEqual(store.outgoingChanges().items.count, 1); try store.markSent(store.outgoingChanges())
        try store.forget(id: item.id)
        out = store.outgoingChanges()
        XCTAssertEqual(out.deletes.map(\.id), [item.id]); XCTAssertEqual(out.tombstones.count, 1)
        try store.markSent(out)
        XCTAssertTrue(store.outgoingChanges().isEmpty)
        // Behavior counters are never part of what is sent.
        try store.recordVoiceReply(interrupted: false)
        XCTAssertTrue(store.outgoingChanges().isEmpty)
    }

    func testRemoteChangesMergeNewerWinsAndForgottenTextIsRemovedEverywhere() throws {
        let store = PersonalMemoryStore(directory: directory, ownerID: owner)
        let incoming = remote("Fictional sister named Mira", kind: .person)
        XCTAssertEqual(try store.applyRemote(items: [incoming], tombstones: [], cursor: Date()), 1)
        XCTAssertEqual(store.items.first?.text, "Fictional sister named Mira")
        XCTAssertTrue(store.outgoingChanges().isEmpty, "What came from the account is not sent back")
        // An older remote copy does not replace a newer unsent local edit.
        let id = incoming.id, version = try XCTUnwrap(store.items.first?.version)
        try store.change(id: id, expectedVersion: version, text: "Fictional sister named Mira, lives nearby")
        var older = incoming.item!; older.version = UUID(); older.text = "Older fictional text"
        try store.applyRemote(items: [.init(id: id, item: older, deleted: false, updatedAt: incoming.updatedAt)], tombstones: [], cursor: Date())
        XCTAssertEqual(store.items.first?.text, "Fictional sister named Mira, lives nearby")
        // Text forgotten on another Mac is removed here and can't be learned again.
        try store.learn(kind: .routine, text: "Fictional gym on Mondays", source: .conversation)
        let hash = PersonalMemoryStore.hash("Fictional gym on Mondays")
        try store.applyRemote(items: [], tombstones: [.init(normalizedTextHash: hash, forgottenAt: Date())], cursor: Date())
        XCTAssertFalse(store.items.contains { $0.text == "Fictional gym on Mondays" })
        XCTAssertEqual(try store.learn(kind: .routine, text: "fictional gym on mondays", source: .conversation), .forgottenBefore)
        // A delete from another Mac removes the item without sending a delete back.
        try store.markSent(store.outgoingChanges())
        try store.applyRemote(items: [.init(id: id, item: nil, deleted: true, updatedAt: Date().addingTimeInterval(60))], tombstones: [], cursor: Date())
        XCTAssertFalse(store.items.contains { $0.id == id })
        XCTAssertTrue(store.outgoingChanges().deletes.isEmpty)
        XCTAssertNotNil(store.document.sync?.cursor)
    }

    func testTheSameKnowledgeLearnedOnTwoMacsKeepsOneCopyEverywhere() throws {
        let a = PersonalMemoryStore(directory: directory.appendingPathComponent("a"), ownerID: owner)
        let b = PersonalMemoryStore(directory: directory.appendingPathComponent("b"), ownerID: owner)
        guard case .added(let onA) = try a.learn(kind: .preference, text: "Fictional tea not coffee", source: .user),
              case .added(let onB) = try b.learn(kind: .preference, text: "fictional tea NOT coffee", source: .user) else { return XCTFail() }
        func asRemote(_ item: MemoryItem) -> PersonalMemoryStore.RemoteItem { .init(id: item.id, item: item, deleted: false, updatedAt: item.updatedAt) }
        try a.applyRemote(items: [asRemote(onB)], tombstones: [], cursor: Date())
        try b.applyRemote(items: [asRemote(onA)], tombstones: [], cursor: Date())
        let keep = min(onA.id.uuidString, onB.id.uuidString)
        XCTAssertEqual(a.items.map(\.id.uuidString), [keep]); XCTAssertEqual(b.items.map(\.id.uuidString), [keep])
        let drop = keep == onA.id.uuidString ? onB.id : onA.id
        XCTAssertTrue(a.outgoingChanges().deletes.contains { $0.id == drop } || b.outgoingChanges().deletes.contains { $0.id == drop })
    }

    func testRemoteItemsForAnotherOwnerAreIgnored() throws {
        let store = PersonalMemoryStore(directory: directory, ownerID: owner)
        var row = remote("Fictional other owner"); var item = row.item!; item.ownerID = UUID(); row = .init(id: row.id, item: item, deleted: false, updatedAt: row.updatedAt)
        XCTAssertEqual(try store.applyRemote(items: [row], tombstones: [], cursor: Date()), 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    @MainActor
    func testServerTimestampsWithMicrosecondsParse() {
        XCTAssertNotNil(CalshotModel.syncDate(.string("2026-11-12T05:30:00.123456+00:00")))
        XCTAssertNotNil(CalshotModel.syncDate(.string("2026-11-12T05:30:00Z")))
        XCTAssertNotNil(CalshotModel.syncDate(.string("2026-11-12T05:30:00.5+00:00")))
        XCTAssertNil(CalshotModel.syncDate(.string("not a date")))
    }
}
