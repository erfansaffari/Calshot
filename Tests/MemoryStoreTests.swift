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
