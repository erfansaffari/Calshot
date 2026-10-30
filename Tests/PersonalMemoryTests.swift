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
        executor.remember = { kind, text in try store.suggest(kind: kind, text: text) }
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
