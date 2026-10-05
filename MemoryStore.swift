import Foundation

/// A local history entry for one screenshot capture. Screenshot bytes live in a
/// sibling image file; this Codable value contains only metadata and a filename.
public struct MemoryCaptureRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let screenshotFileName: String
    public let imageFormat: ImageFormat
    public var event: EventDetails?
    public var recognizedText: String?
    public var analysisProvider: String?
    public var savedToCalendarAt: Date?
    public var savedCalendarName: String?
    public var calendarEventIdentifier: String?

    public enum ImageFormat: String, Codable, Sendable {
        case png
        case jpeg
    }

    /// Serializable snapshot of EventDraft. Dates are stored as Foundation
    /// dates by Codable, and ambiguity cases are stored by their stable raw value.
    public struct EventDetails: Codable, Sendable {
        public var id: UUID
        public var title: String
        public var startDate: Date?
        public var endDate: Date?
        public var isAllDay: Bool
        public var timeZoneIdentifier: String?
        public var location: String?
        public var url: URL?
        public var notes: String?
        public var sourceText: String
        public var confidence: Double
        public var ambiguities: [String]

        public init(draft: EventDraft) {
            id = draft.id
            title = draft.title
            startDate = draft.startDate
            endDate = draft.endDate
            isAllDay = draft.isAllDay
            timeZoneIdentifier = draft.timeZoneIdentifier
            location = draft.location
            url = draft.url
            notes = draft.notes
            sourceText = draft.sourceText
            confidence = draft.confidence
            ambiguities = draft.ambiguities.map(\.rawValue)
        }
    }
}

/// Persists screenshot history locally under Application Support/Calshot/Memory.
/// Each capture has a JSON metadata file and a separate PNG or JPEG image file.
public final class MemoryStore: @unchecked Sendable {
    private static let directoryPreferenceKey = "memoryDirectoryPath"
    public static let shared = MemoryStore()

    private var directoryURL: URL
    private let fileManager: FileManager
    private let preferences: UserDefaults
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// The default location is `~/Library/Application Support/Calshot/Memory`.
    /// A custom directory can be supplied for callers that need an isolated store.
    public init(directoryURL: URL? = nil, fileManager: FileManager = .default,
                preferences: UserDefaults = .standard) {
        self.fileManager = fileManager
        self.preferences = preferences
        if let directoryURL {
            self.directoryURL = directoryURL.standardizedFileURL
        } else if let savedPath = preferences.string(forKey: Self.directoryPreferenceKey) {
            self.directoryURL = URL(fileURLWithPath: savedPath, isDirectory: true).standardizedFileURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directoryURL = support.appendingPathComponent("Calshot", isDirectory: true)
                .appendingPathComponent("Memory", isDirectory: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// The active folder used for capture files.
    public var locationURL: URL {
        lock.lock()
        defer { lock.unlock() }
        return directoryURL
    }

    /// Moves the complete history folder to a new location and remembers it for
    /// the next launch. An existing non-empty Calshot folder is left untouched.
    public func move(to newDirectoryURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        let destination = newDirectoryURL.standardizedFileURL
        guard destination != directoryURL else { return }
        guard !destination.path.hasPrefix(directoryURL.path + "/") else {
            throw MemoryStoreError.locationInsideCurrentFolder
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            let existingFiles = try fileManager.contentsOfDirectory(at: destination,
                                                                     includingPropertiesForKeys: nil)
            guard existingFiles.isEmpty else { throw MemoryStoreError.locationAlreadyContainsData }
            try fileManager.removeItem(at: destination)
        }

        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.moveItem(at: directoryURL, to: destination)
        } else {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        directoryURL = destination
        preferences.set(destination.path, forKey: Self.directoryPreferenceKey)
    }

    /// Saves a PNG or JPEG screenshot and optional extracted event details.
    /// Only the supplied screenshot bytes are written; no network operation occurs.
    @discardableResult
    public func recordCapture(
        imageData: Data,
        draft: EventDraft? = nil,
        recognizedText: String? = nil,
        analysisProvider: String? = nil,
        createdAt: Date = Date()
    ) throws -> MemoryCaptureRecord {
        let format = try Self.imageFormat(for: imageData)
        let id = UUID()
        let imageName = "\(id.uuidString).\(format.rawValue)"
        let record = MemoryCaptureRecord(
            id: id,
            createdAt: createdAt,
            screenshotFileName: imageName,
            imageFormat: format,
            event: draft.map(MemoryCaptureRecord.EventDetails.init(draft:)),
            recognizedText: recognizedText,
            analysisProvider: analysisProvider,
            savedToCalendarAt: nil,
            savedCalendarName: nil,
            calendarEventIdentifier: nil
        )

        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        let imageURL = directoryURL.appendingPathComponent(imageName)
        let recordURL = metadataURL(for: id)
        do {
            try imageData.write(to: imageURL, options: .atomic)
            try encoder.encode(record).write(to: recordURL, options: .atomic)
        } catch {
            // Avoid leaving an image without metadata if the second write fails.
            try? fileManager.removeItem(at: imageURL)
            try? fileManager.removeItem(at: recordURL)
            throw error
        }
        return record
    }

    /// Returns valid records newest first. A corrupt JSON file is skipped so it
    /// cannot prevent the remaining history from loading.
    public func listRecords() -> [MemoryCaptureRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> MemoryCaptureRecord? in
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(MemoryCaptureRecord.self, from: data),
                      url.lastPathComponent == metadataURL(for: record.id).lastPathComponent else {
                    return nil
                }
                return record
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Loads a record's screenshot. Returns nil if the record or image is missing,
    /// unreadable, or no longer contains a recognized PNG/JPEG payload.
    public func imageData(for record: MemoryCaptureRecord) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isSafeImageFileName(record.screenshotFileName),
              let data = try? Data(contentsOf: directoryURL.appendingPathComponent(record.screenshotFileName)),
              (try? Self.imageFormat(for: data)) == record.imageFormat else { return nil }
        return data
    }

    /// Replaces or clears the event snapshot after the user edits a proposal.
    @discardableResult
    public func updateEventDetails(for id: UUID, draft: EventDraft?) throws -> MemoryCaptureRecord? {
        try updateRecord(id: id) { $0.event = draft.map(MemoryCaptureRecord.EventDetails.init(draft:)) }
    }

    /// Marks a record as successfully added to a calendar.
    @discardableResult
    public func markSavedToCalendar(
        for id: UUID,
        calendarName: String?,
        eventIdentifier: String? = nil,
        savedAt: Date = Date()
    ) throws -> MemoryCaptureRecord? {
        try updateRecord(id: id) {
            $0.savedToCalendarAt = savedAt
            $0.savedCalendarName = calendarName
            $0.calendarEventIdentifier = eventIdentifier
        }
    }

    /// Deletes one capture's metadata and image. Missing files are treated as already deleted.
    public func deleteRecord(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let metadata = metadataURL(for: id)
        if let data = try? Data(contentsOf: metadata),
           let record = try? decoder.decode(MemoryCaptureRecord.self, from: data),
           Self.isSafeImageFileName(record.screenshotFileName) {
            try? fileManager.removeItem(at: directoryURL.appendingPathComponent(record.screenshotFileName))
        }
        if fileManager.fileExists(atPath: metadata.path) {
            try fileManager.removeItem(at: metadata)
        }
    }

    /// Deletes all history files in this store and recreates its directory.
    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        try ensureDirectory()
    }

    private func updateRecord(
        id: UUID,
        change: (inout MemoryCaptureRecord) -> Void
    ) throws -> MemoryCaptureRecord? {
        lock.lock()
        defer { lock.unlock() }
        let url = metadataURL(for: id)
        guard let data = try? Data(contentsOf: url),
              var record = try? decoder.decode(MemoryCaptureRecord.self, from: data) else { return nil }
        change(&record)
        try encoder.encode(record).write(to: url, options: .atomic)
        return record
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func metadataURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private static func isSafeImageFileName(_ name: String) -> Bool {
        name == URL(fileURLWithPath: name).lastPathComponent &&
            (name.lowercased().hasSuffix(".png") || name.lowercased().hasSuffix(".jpeg"))
    }

    private static func imageFormat(for data: Data) throws -> MemoryCaptureRecord.ImageFormat {
        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 8 && bytes == [137, 80, 78, 71, 13, 10, 26, 10] { return .png }
        if bytes.count >= 3 && bytes[0...2].elementsEqual([0xFF, 0xD8, 0xFF]) { return .jpeg }
        throw MemoryStoreError.unsupportedImageFormat
    }
}

public enum MemoryStoreError: Error, LocalizedError {
    case unsupportedImageFormat
    case locationAlreadyContainsData
    case locationInsideCurrentFolder

    public var errorDescription: String? {
        switch self {
        case .unsupportedImageFormat: return "The screenshot must be PNG or JPEG data."
        case .locationAlreadyContainsData:
            return "That folder already contains Calshot Memory data. Choose another folder, or choose the folder that already contains the history."
        case .locationInsideCurrentFolder:
            return "Choose a folder outside the current Calshot Memory folder."
        }
    }
}
