import XCTest
@testable import Calshot

final class MemoryStoreTests: XCTestCase {
    private func change(_ title: String, finished: Bool, savedAt: Date = Date()) -> CalendarActionProposal {
        var item = CalendarActionProposal(draft: EventDraft(title: title, startDate: Date(timeIntervalSince1970: 1_800_000_000), endDate: Date(timeIntervalSince1970: 1_800_003_600),
            isAllDay: false, timeZoneIdentifier: "America/Toronto", location: nil, url: nil, notes: nil, sourceText: "Fictional", confidence: 1, ambiguities: []))
        if finished { item.state = .added; item.receipt = CalendarActionReceipt(destinationID: "demo", calendarName: "Demo", eventIdentifier: title, savedAt: savedAt) }
        return item
    }
    func testEarlierConversationsMergeOnceIntoTheOneChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Calshot-MainChat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(directoryURL: root)
        let first = try store.recordCommand("First fictional question")
        let second = try store.recordCommand("Second fictional question")
        _ = try store.updateProposals(for: first.id, proposals: [change("Saved fictional lab", finished: true), change("Unapproved fictional row", finished: false)])
        let main = try store.mainChat()
        XCTAssertEqual(main.isMainChat, true)
        // Records are oldest first; these two share a second, so only membership is checked here.
        XCTAssertEqual(Set(main.agentTranscript?.compactMap(\.content) ?? []), ["First fictional question", "Second fictional question"])
        XCTAssertEqual(main.calendarProposals.map(\.draft.title), ["Saved fictional lab"], "Only receipts carry over, never stale reviews")
        XCTAssertTrue(store.listRecords().filter { [first.id, second.id].contains($0.id) }.allSatisfy { $0.mergedIntoMainChat == true })
        XCTAssertEqual(try store.mainChat().id, main.id)
        XCTAssertEqual(try store.mainChat().agentTranscript?.count, 2, "Merging happens once")
        XCTAssertTrue(store.agentMemory(excluding: main.id).isEmpty, "Merged chats are not repeated as separate memory")

        // The chat keeps its change history when a later run saves only its own rows.
        _ = try store.mergeProposals(for: main.id, proposals: [change("New fictional quiz", finished: true)])
        XCTAssertEqual(Set(store.listRecords().first { $0.id == main.id }?.calendarProposals.map(\.draft.title) ?? []), ["Saved fictional lab", "New fictional quiz"])

        try store.deleteRecord(id: main.id)
        XCTAssertTrue(store.listRecords().isEmpty, "Deleting the chat removes the hidden merged conversations too")
    }
    private func copy(of record: MemoryCaptureRecord, id: UUID = UUID(), transcript: [AgentTurn], provider: String?, createdAt: Date? = nil) throws -> MemoryCaptureRecord {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        object["id"] = id.uuidString; object["analysisProvider"] = provider
        if let createdAt { object["createdAt"] = ISO8601DateFormatter().string(from: createdAt) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var result = try decoder.decode(MemoryCaptureRecord.self, from: JSONSerialization.data(withJSONObject: object))
        result.agentTranscript = transcript
        return result
    }
    func testConcurrentMainChatEditsUniteInsteadOfForkingASecondMainChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Calshot-MainSync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(directoryURL: root)
        let main = try store.mainChat()
        let earlier = [AgentTurn(role: "user", content: "Fictional earlier question"), AgentTurn(role: "assistant", content: "Fictional earlier answer")]
        _ = try store.updateAgentContext(for: main.id, transcript: earlier)
        let synced = try XCTUnwrap(store.listRecords().first { $0.id == main.id })
        let baseline = AccountSyncBaseline(hashes: [main.id.uuidString: try synced.syncHash()])
        var tool = AgentTurn(role: "tool", toolName: "list_tasks", arguments: "{}", result: "{}"); tool.at = AgentTurn.stamp()
        _ = try store.updateAgentContext(for: main.id, transcript: earlier + [AgentTurn(role: "user", content: "Asked on this Mac"), tool])
        let local = try XCTUnwrap(store.listRecords().first { $0.id == main.id })
        var remote = synced; remote.agentTranscript = earlier + [AgentTurn(role: "user", content: "Asked on the other Mac")]
        var cloud = AccountSyncDocument(); cloud.history[main.id.uuidString] = remote.accountSyncCopy()

        let result = try AccountSyncMerge.merge(remote: cloud, local: [local], baseline: baseline)
        XCTAssertEqual(Array(result.history.keys), [main.id.uuidString], "The main chat is never forked")
        XCTAssertEqual(result.history[main.id.uuidString]?.agentTranscript?.compactMap(\.content),
                       ["Fictional earlier question", "Fictional earlier answer", "Asked on the other Mac", "Asked on this Mac"],
                       "The other Mac's turn follows the last turn both share")
        try store.applyAccountSync(result)
        let applied = try XCTUnwrap(store.listRecords().first { $0.id == main.id })
        XCTAssertTrue(applied.agentTranscript?.contains { $0.toolName == "list_tasks" } == true, "Local tool calls survive the synced copy")
        XCTAssertEqual(applied.agentTranscript?.compactMap(\.content), ["Fictional earlier question", "Fictional earlier answer", "Asked on the other Mac", "Asked on this Mac"])
        XCTAssertEqual(store.listRecords().filter { $0.isMainChat == true }.count, 1)
    }
    func testCopiesOfTheMainChatAreUnitedOnceAndRepeatedTurnsRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Calshot-MainRepair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(directoryURL: root)
        let main = try store.mainChat()
        let a = AgentTurn(role: "user", content: "Fictional quiz?"), b = AgentTurn(role: "assistant", content: "Fictional quiz is Friday.")
        var timed = AgentTurn(role: "user", content: "Latest fictional request"); timed.at = AgentTurn.stamp()
        // An earlier conflict appended a copy of the chat to itself.
        _ = try store.updateAgentContext(for: main.id, transcript: [a, b, a, b, timed])
        let original = try XCTUnwrap(store.listRecords().first { $0.id == main.id })
        // Two synced copies that also claim to be the main chat, with the same creation date.
        var forkA = try copy(of: original, transcript: [a, b, AgentTurn(role: "assistant", content: "Only in a copy"), AgentTurn(role: "user", content: "Latest fictional request")], provider: MemoryStore.recoveredProvider)
        forkA.isMainChat = true
        var forkB = try copy(of: original, transcript: [a, b, a, b, AgentTurn(role: "assistant", content: "Only in a copy")], provider: MemoryStore.recoveredProvider); forkB.isMainChat = true
        var document = AccountSyncDocument()
        for fork in [forkA, forkB] { document.history[fork.id.uuidString] = fork }
        try store.applyAccountSync(document)

        let united = try MemoryStore(directoryURL: root).mainChat()
        XCTAssertEqual(united.id, main.id, "The original stays the main chat")
        XCTAssertEqual(united.agentTranscript?.compactMap(\.content), ["Fictional quiz?", "Fictional quiz is Friday.", "Only in a copy", "Latest fictional request"],
                       "A turn found only in a copy goes back where it happened, not after newer turns")
        XCTAssertEqual(store.listRecords().filter { $0.isMainChat == true }.map(\.id), [main.id])
        XCTAssertEqual(try store.mainChat().agentTranscript?.count, 4, "Uniting happens once")
    }
    func testMergedCopiesOfTheMainChatAreFoldedInAndDeletedAndRepeatedChangesKeptOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Calshot-CopyCleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(directoryURL: root)
        let main = try store.mainChat()
        let saved = change("Fictional saved lab", finished: true), older = change("Fictional older shift", finished: true)
        _ = try store.updateAgentContext(for: main.id, transcript: [AgentTurn(role: "user", content: "Fictional question")])
        _ = try store.updateProposals(for: main.id, proposals: [saved, saved, saved])
        let original = try XCTUnwrap(store.listRecords().first { $0.id == main.id })
        // A fork of the main chat marked merged by an earlier build, still holding a turn and a change the chat lost.
        var stale = try copy(of: original, transcript: [AgentTurn(role: "user", content: "Fictional question"), AgentTurn(role: "assistant", content: "Only in an old copy")], provider: MemoryStore.recoveredProvider)
        stale.mergedIntoMainChat = true; stale.proposals = [saved, older]
        // A fork of a separate, later conversation is an earlier conversation, not a copy of the chat.
        let separate = try copy(of: try store.recordCommand("Fictional separate question"), transcript: [AgentTurn(role: "user", content: "Fictional separate question")], provider: "Calendar agent", createdAt: main.createdAt.addingTimeInterval(3600))
        let fork = try copy(of: separate, transcript: separate.agentTranscript ?? [], provider: MemoryStore.recoveredProvider)
        var document = AccountSyncDocument()
        for record in [stale, separate, fork] { document.history[record.id.uuidString] = record }
        try store.applyAccountSync(document)

        let repaired = try MemoryStore(directoryURL: root).mainChat()
        XCTAssertEqual(repaired.agentTranscript?.compactMap(\.content).prefix(2), ["Fictional question", "Only in an old copy"])
        XCTAssertEqual(Set(repaired.calendarProposals.map(\.id)), [saved.id, older.id])
        XCTAssertEqual(repaired.calendarProposals.count, 2, "A repeated saved change is kept once")
        let ids = Set(store.listRecords().map(\.id))
        XCTAssertFalse(ids.contains(stale.id), "The copy is deleted, so it stops syncing")
        XCTAssertTrue(ids.contains(fork.id) && ids.contains(separate.id), "Other conversations stay on disk")
        XCTAssertEqual(store.listRecords().filter { $0.isMainChat == true }.map(\.id), [main.id])
    }
    func testChangeHistoryDropsOnlyTheOldestFinishedRows() {
        let old = (0..<MemoryStore.mainChatChangeLimit).map { change("Old \($0)", finished: true, savedAt: Date(timeIntervalSince1970: Double($0))) }
        let merged = MemoryStore.mergedChanges(existing: old + [change("Waiting", finished: false)], incoming: [change("Newest", finished: true)])
        XCTAssertEqual(merged.filter(\.isFinished).count, MemoryStore.mainChatChangeLimit)
        XCTAssertFalse(merged.contains { $0.draft.title == "Old 0" })
        XCTAssertTrue(merged.contains { $0.draft.title == "Waiting" }); XCTAssertTrue(merged.contains { $0.draft.title == "Newest" })
    }
    func testChangingLocationMovesHistoryAndPersistsNewPath() throws {
        let suiteName = "Calshot.MemoryStoreTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Calshot-MemoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("Original", isDirectory: true)
        let destinationURL = root.appendingPathComponent("External/Calshot/Memory", isDirectory: true)
        let imageData = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let store = MemoryStore(directoryURL: originalURL, preferences: preferences)
        let record = try store.recordCapture(imageData: imageData, recognizedText: "Event details")

        try store.move(to: destinationURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(store.locationURL, destinationURL)
        XCTAssertEqual(store.listRecords().map(\.id), [record.id])
        XCTAssertEqual(store.imageData(for: record), imageData)

        let reopenedStore = MemoryStore(preferences: preferences)
        XCTAssertEqual(reopenedStore.locationURL, destinationURL)
        XCTAssertEqual(reopenedStore.listRecords().map(\.id), [record.id])
    }
}
