import XCTest
@testable import Calshot

final class MemoryStoreTests: XCTestCase {
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
