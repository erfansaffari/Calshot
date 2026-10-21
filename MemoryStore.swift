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
    public var schemaVersion: Int?
    public var proposals: [CalendarActionProposal]?
    public var agentTranscript: [AgentTurn]?
    public var additionalScreenshots: [ScreenshotSource]?

    public struct ScreenshotSource: Codable, Identifiable, Sendable {
        public var id: UUID
        public var fileName: String
        public var imageFormat: ImageFormat
        public var recognizedText: String
    }

    public var calendarProposals: [CalendarActionProposal] {
        if let proposals { return proposals }
        guard let event else { return [] }
        var item = CalendarActionProposal(draft: event.draft)
        if let savedAt = savedToCalendarAt {
            item.state = .added
            item.isSelected = false
            item.receipt = CalendarActionReceipt(destinationID: "legacy", calendarName: savedCalendarName ?? "Calendar",
                eventIdentifier: calendarEventIdentifier ?? "", savedAt: savedAt)
        }
        return [item]
    }

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

        public var draft: EventDraft {
            EventDraft(id: id, title: title, startDate: startDate, endDate: endDate, isAllDay: isAllDay,
                       timeZoneIdentifier: timeZoneIdentifier, location: location, url: url, notes: notes,
                       sourceText: sourceText, confidence: confidence,
                       ambiguities: ambiguities.compactMap(EventAmbiguity.init(rawValue:)))
        }

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

    /// A separate folder per Calshot identity prevents one person's local history
    /// from being uploaded into the next account signed in on this Mac.
    public func accountStore(for user: UUID) throws -> MemoryStore {
        var root = locationURL
        if fileManager.fileExists(atPath: root.appendingPathComponent(".calshot-account").path) { root.deleteLastPathComponent() }
        let destination = root.appendingPathComponent(user.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: destination.appendingPathComponent(".calshot-account").path) {
            return MemoryStore(directoryURL: destination, fileManager: fileManager, preferences: preferences)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent(".calshot-legacy-owner")
        let owner = try? String(contentsOf: marker, encoding: .utf8)
        if owner == nil || owner == user.uuidString {
            // Claim legacy local history once. Copy it, preserving the original
            // as a migration backup and never overwriting newer account files.
            try user.uuidString.write(to: marker, atomically: true, encoding: .utf8)
            for record in listRecords() where root == locationURL {
                let names = [record.id.uuidString + ".json", record.screenshotFileName] + (record.additionalScreenshots ?? []).map(\.fileName)
                for name in names where name == URL(fileURLWithPath: name).lastPathComponent && !name.isEmpty {
                    let source = root.appendingPathComponent(name), target = destination.appendingPathComponent(name)
                    if fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: target.path) { try fileManager.copyItem(at: source, to: target) }
                }
            }
        }
        try user.uuidString.write(to: destination.appendingPathComponent(".calshot-account"), atomically: true, encoding: .utf8)
        return MemoryStore(directoryURL: destination, fileManager: fileManager, preferences: preferences)
    }
    func applyAccountSync(_ document: AccountSyncDocument) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory()
        for (key, remote) in document.history {
            guard key == remote.id.uuidString, remote.screenshotFileName.isEmpty, remote.additionalScreenshots == nil else { throw MemoryStoreError.unsupportedImageFormat }
            var copy = remote.accountSyncCopy()
            let url = metadataURL(for: remote.id)
            if let data = try? Data(contentsOf: url), let local = try? decoder.decode(MemoryCaptureRecord.self, from: data) {
                if try local.syncHash() == remote.syncHash() { continue }
                copy = MemoryCaptureRecord(id: copy.id, createdAt: copy.createdAt, screenshotFileName: local.screenshotFileName, imageFormat: local.imageFormat,
                    event: copy.event, recognizedText: copy.recognizedText, analysisProvider: copy.analysisProvider,
                    savedToCalendarAt: copy.savedToCalendarAt, savedCalendarName: copy.savedCalendarName, calendarEventIdentifier: copy.calendarEventIdentifier,
                    schemaVersion: copy.schemaVersion, proposals: copy.proposals, agentTranscript: copy.agentTranscript, additionalScreenshots: local.additionalScreenshots)
            }
            try encoder.encode(copy).write(to: url, options: .atomic)
        }
        // Tombstones remove metadata only here; local screenshot files stay local.
        for id in document.deleted where document.history[id.uuidString] == nil {
            let url = metadataURL(for: id)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
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
        proposals: [CalendarActionProposal]? = nil,
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
            calendarEventIdentifier: nil,
            schemaVersion: 3,
            proposals: proposals
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

    /// Typed-only sessions have metadata without a fabricated screenshot.
    public func recordCommand(_ command: String, transcript: [AgentTurn] = []) throws -> MemoryCaptureRecord {
        let record = MemoryCaptureRecord(id: UUID(), createdAt: .now, screenshotFileName: "", imageFormat: .png,
            event: nil, recognizedText: nil, analysisProvider: "Calendar agent", savedToCalendarAt: nil,
            savedCalendarName: nil, calendarEventIdentifier: nil, schemaVersion: 3, proposals: [], agentTranscript: transcript.isEmpty ? [AgentTurn(role: "user", content: String(command.prefix(8000)))] : transcript)
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        try encoder.encode(record).write(to: metadataURL(for: record.id), options: .atomic)
        return record
    }

    @discardableResult
    public func updateScreenshotText(for id: UUID, sourceID: UUID, text: String) throws -> MemoryCaptureRecord? {
        try updateRecord(id: id) { record in
            guard let index = record.additionalScreenshots?.firstIndex(where: { $0.id == sourceID }) else { return }
            record.additionalScreenshots?[index].recognizedText = text
        }
    }

    @discardableResult
    public func updateAgentContext(for id: UUID, transcript: [AgentTurn], recognizedText: String? = nil) throws -> MemoryCaptureRecord? {
        try updateRecord(id: id) { record in
            record.schemaVersion = 3
            record.agentTranscript = Array(transcript.suffix(600))
            if let recognizedText { record.recognizedText = recognizedText }
        }
    }

    /// Real write receipts and recent user/tool context from local history. This
    /// bounded context informs future requests; it never authorizes a new write.
    public func agentMemory(excluding id: UUID? = nil) -> [AgentTurn] {
        let formatter = ISO8601DateFormatter()
        var result: [AgentTurn] = []
        var characters = 0
        for record in listRecords().filter({ $0.id != id }).prefix(12) {
            let actions: [[String: String]] = record.calendarProposals.compactMap { proposal in
                guard let receipt = proposal.receipt, proposal.isFinished else { return nil }
                return ["operation": proposal.operation.rawValue, "status": proposal.state.rawValue,
                    "title": String(proposal.draft.title.prefix(500)), "eventIdentifier": receipt.eventIdentifier,
                    "calendar": receipt.calendarName, "destinationID": receipt.destinationID,
                    "start": proposal.draft.startDate.map(formatter.string(from:)) ?? "",
                    "end": proposal.draft.endDate.map(formatter.string(from:)) ?? "",
                    "savedAt": formatter.string(from: receipt.savedAt)]
            }
            let context = (record.agentTranscript ?? []).filter { $0.sharedCalendarContext != true && ($0.role == "user" || $0.role == "tool" || ($0.role == "assistant" && $0.toolName == nil)) }.suffix(8)
            let contextual: [[String: String]] = context.map { turn in
                ["role": turn.role, "tool": turn.toolName ?? "", "content": String((turn.result ?? turn.content ?? "").prefix(2000))]
            }
            guard !actions.isEmpty || !contextual.isEmpty else { continue }
            let value: [String: Any] = ["captureID": record.id.uuidString, "date": formatter.string(from: record.createdAt),
                                       "actions": Array(actions.prefix(40)), "conversation": contextual]
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8), characters + text.count <= 20_000 else { continue }
            result.append(AgentTurn(role: "memory", content: text))
            characters += text.count
        }
        return result.reversed()
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
    public func imageData(for record: MemoryCaptureRecord, sourceID: UUID? = nil) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let source = sourceID.flatMap { id in record.additionalScreenshots?.first { $0.id == id } }
        if sourceID != nil && source == nil { return nil }
        let fileName = source?.fileName ?? record.screenshotFileName
        let format = source?.imageFormat ?? record.imageFormat
        guard Self.isSafeImageFileName(fileName),
              let data = try? Data(contentsOf: directoryURL.appendingPathComponent(fileName)),
              (try? Self.imageFormat(for: data)) == format else { return nil }
        return data
    }

    /// Adds another visible page to the same history record. The new image and
    /// proposal collection are committed together, preserving each item's source.
    @discardableResult
    public func appendScreenshot(for id: UUID, imageData: Data, recognizedText: String,
                                 proposals newItems: [CalendarActionProposal]) throws -> MemoryCaptureRecord? {
        let format = try Self.imageFormat(for: imageData)
        let sourceID = UUID()
        let fileName = sourceID.uuidString + "." + format.rawValue
        lock.lock()
        defer { lock.unlock() }
        let metadata = metadataURL(for: id)
        guard let data = try? Data(contentsOf: metadata),
              var record = try? decoder.decode(MemoryCaptureRecord.self, from: data) else { return nil }
        var items = record.calendarProposals
        for var item in newItems {
            if items.contains(where: { CalendarDraftValidation.sameEvent($0.draft, item.draft) }) { continue }
            item.sourceCaptureID = sourceID
            items.append(item)
        }
        record.proposals = items
        record.schemaVersion = 3
        var sources = record.additionalScreenshots ?? []
        sources.append(MemoryCaptureRecord.ScreenshotSource(id: sourceID, fileName: fileName,
                                                           imageFormat: format, recognizedText: recognizedText))
        record.additionalScreenshots = sources
        let imageURL = directoryURL.appendingPathComponent(fileName)
        do {
            try imageData.write(to: imageURL, options: .atomic)
            try encoder.encode(record).write(to: metadata, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: imageURL)
            throw error
        }
        return record
    }

    @discardableResult
    public func updateProposals(for id: UUID, proposals: [CalendarActionProposal]) throws -> MemoryCaptureRecord? {
        try updateRecord(id: id) { record in
            record.schemaVersion = 3
            record.proposals = proposals
            record.event = proposals.first.map { MemoryCaptureRecord.EventDetails(draft: $0.draft) }
            let receipt = proposals.compactMap(\.receipt).first
            record.savedToCalendarAt = receipt?.savedAt
            record.savedCalendarName = receipt?.calendarName
            record.calendarEventIdentifier = receipt?.eventIdentifier
        }
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
            for source in record.additionalScreenshots ?? [] where Self.isSafeImageFileName(source.fileName) {
                try? fileManager.removeItem(at: directoryURL.appendingPathComponent(source.fileName))
            }
        }
        if fileManager.fileExists(atPath: metadata.path) {
            try fileManager.removeItem(at: metadata)
        }
    }

    /// Deletes all history files in this store and recreates its directory.
    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        let accountMarker = directoryURL.appendingPathComponent(".calshot-account")
        let owner = try? Data(contentsOf: accountMarker)
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        try ensureDirectory()
        if let owner { try owner.write(to: accountMarker, options: .atomic) }
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
