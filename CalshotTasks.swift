import Foundation
import CryptoKit
import UserNotifications

struct CalshotTask: Codable, Identifiable {
    var id = UUID()
    var version = UUID()
    var title: String
    var dueDate: String?
    var dueTime: String?
    var timeZone = TimeZone.current.identifier
    var notes = ""
    var completed = false
    var deleted = false
    var rank = 0
    var reminderMinutes: Int?
    var reminderTime: String?
    var reminderDeviceID: String?
    var calendarID: String?
    var calendarName: String?
    var receipt: CalendarActionReceipt?
    var receiptDeviceID: String?
    var publishedFingerprint: String?
    var calendarError: String?
    var sourceText: String?
    var updatedAt = Date.now

    var fingerprint: String { [title, dueDate ?? "", dueTime ?? "", timeZone, notes, calendarID ?? ""].joined(separator: "\u{1f}") }
    var needsPublication: Bool { !deleted && (dueDate != nil || receipt != nil) && publishedFingerprint != fingerprint }
    static func date(_ day: String, time: String? = nil, zone: String) throws -> Date {
        guard TimeZone(identifier: zone) != nil, day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              time == nil || time!.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { throw CalendarToolArgumentError("Choose a valid deadline and timezone.") }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: zone); f.dateFormat = "yyyy-MM-dd HH:mm"; f.isLenient = false
        let value = day + " " + (time ?? "00:00")
        guard let result = f.date(from: value), f.string(from: result) == value else { throw CalendarToolArgumentError("That deadline is not a real date/time in its timezone.") }
        return result
    }
    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 500, notes.count <= 8000,
              TimeZone(identifier: timeZone) != nil, rank >= 0, rank < 10000 else { throw CalendarToolArgumentError("Enter a title up to 500 characters and valid task details.") }
        if let day = dueDate { _ = try Self.date(day, time: dueTime, zone: timeZone) }
        else if dueTime != nil || reminderMinutes != nil { throw CalendarToolArgumentError("Choose a due date before adding a time or reminder.") }
        if let minutes = reminderMinutes {
            guard [0, 60, 1440].contains(minutes), dueTime != nil || reminderTime != nil else { throw CalendarToolArgumentError("Choose a reminder time for this date-only task.") }
            _ = try Self.date(dueDate!, time: dueTime ?? reminderTime, zone: timeZone)
        }
    }
    func applying(_ draft: EventDraft) throws -> CalshotTask {
        var task = self
        task.timeZone = draft.timeZoneIdentifier ?? timeZone
        if let start = draft.startDate {
            let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.timeZone=TimeZone(identifier:task.timeZone); f.dateFormat="yyyy-MM-dd"; task.dueDate=f.string(from:start)
        }
        let suffix = dueTime.map { " · due " + $0 } ?? ""
        task.title = !suffix.isEmpty && draft.title.hasSuffix(suffix) ? String(draft.title.dropLast(suffix.count)) : draft.title
        let notes = draft.notes ?? ""
        if let marker=notes.range(of:"\nCalshot task: " + id.uuidString,options:.backwards) { task.notes=String(notes[..<marker.lowerBound]) }
        else { task.notes=notes }
        try task.validate(); return task
    }
    func deadline(owner: UUID?, deviceID: String? = nil) throws -> CalendarActionProposal {
        let start = try dueDate.map { try Self.date($0, zone: timeZone) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: timeZone)!
        let end = start.flatMap { cal.date(byAdding: .day, value: 1, to: $0) }
        var title = self.title
        if let time = dueTime { title += " · due " + time }
        var note = notes
        note += "\nCalshot task: \(id.uuidString)\nDeadline: \(dueDate ?? "Unresolved")\(dueTime.map { " at " + $0 } ?? " (date only)") · \(timeZone)\nThis deadline does not reserve work time."
        var draft = EventDraft(title: title, startDate: start, endDate: end, isAllDay: true, timeZoneIdentifier: timeZone, location: nil, url: nil, notes: note, sourceText: sourceText ?? self.title, confidence: start == nil ? 0.5 : 1, ambiguities: start == nil ? [.missingDate] : [])
        draft.taskID = id; draft.taskVersion = version; draft.taskOwnerID = owner; draft.isTaskDeadline = true
        draft.taskSourceDeviceID = deviceID
        draft.taskDeadlineTime = dueTime; draft.taskBaseTitle = self.title
        var proposal = CalendarActionProposal(draft: draft, operation: receipt == nil ? .create : dueDate == nil ? .delete : .update, targetEventIdentifier: receipt?.eventIdentifier)
        if let receipt { proposal.targetDestinationID = receipt.destinationID; proposal.targetCalendarName = receipt.calendarName }
        else { proposal.targetDestinationID = calendarID; proposal.targetCalendarName = calendarName }
        return proposal
    }
}
struct CalshotTaskImport {
    var id = UUID()
    var items: [CalshotTask]
    var selectedInboxIDs: Set<UUID>
    var ownerID: UUID?
    var captureID: UUID?
    var recordID: UUID?
    var storeURL: URL
}
struct CalshotTaskDocument: Codable {
    var items: [CalshotTask] = []
    var baseline: [String: UUID] = [:]
}
struct CalshotTaskCloud: Decodable { var revision: Int; var items: [CalshotTask] }

struct CalshotTaskStore {
    let directory: URL
    var url: URL { directory.appendingPathComponent("tasks-v1.json") }
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    func load() throws -> CalshotTaskDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let doc = try Self.decoder.decode(CalshotTaskDocument.self, from: Data(contentsOf: url))
        guard doc.items.count <= 1000, Set(doc.items.map(\.id)).count == doc.items.count else { throw CalendarToolArgumentError("Task storage could not be read safely.") }
        try doc.items.forEach { try $0.validate() }; return doc
    }
    func save(_ doc: CalshotTaskDocument) throws {
        guard doc.items.count <= 1000, Set(doc.items.map(\.id)).count == doc.items.count else { throw CalendarToolArgumentError("Tasks supports up to 1,000 items including archived tasks.") }
        try doc.items.forEach { try $0.validate() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.encoder.encode(doc).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
extension CalshotModel {
    var taskStore: CalshotTaskStore { .init(directory: memoryStore.locationURL) }
    var tasksToken: String { UUIDToken.hash((account.userID?.uuidString ?? "local") + taskDocument.items.map { $0.id.uuidString + $0.version.uuidString }.joined()) }
    func loadTasks() {
        taskSessionID = UUID(); taskSyncBusy = false
        do {
            taskDocument = try taskStore.load(); taskDataReady = true; taskError = nil
            let receipts = memoryStore.listRecords().flatMap(\.calendarProposals).filter { $0.isFinished && $0.receipt != nil && $0.draft.taskSourceDeviceID == Self.syncDeviceID }
            try reconcileTaskReceipts(receipts)
        }
        catch { taskDocument = .init(); taskDataReady = false; taskError = "Couldn’t read your tasks. Your saved file is kept. \(error.localizedDescription)" }
        refreshTaskReminders()
    }
    func clearTaskSession() {
        taskSessionID = UUID(); taskSyncBusy = false
        taskReminderWork?.cancel(); taskReminderGeneration = UUID()
        taskImport = nil; taskDocument = .init(); taskDataReady = false; taskError = nil; taskConflict = false; taskReminderError = nil
        let session = taskSessionID
        guard account.enabled else { return }
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            let requests = await center.pendingNotificationRequests()
            guard self?.taskSessionID == session, self?.account.userID == nil else { return }
            center.removePendingNotificationRequests(withIdentifiers: requests.filter { $0.identifier.hasPrefix("calshot.task.") }.map(\.identifier))
        }
    }
    func persistTasks(_ doc: CalshotTaskDocument) throws {
        guard taskDataReady else { throw CalendarToolArgumentError("Reload Tasks before making changes.") }
        try taskStore.save(doc); taskDocument = doc
        refreshTaskReminders()
    }
    func validateTaskAction(_ body: [String: Any]) throws {
        guard account.canUseWorkspace, taskDataReady, body["token"] as? String == tasksToken, !taskSyncBusy else { throw CalendarToolArgumentError("Tasks changed. Refresh and try again.") }
        guard !isSaving, !isCapturing, !agentIsRunning, !isRecognizing, agentQuestion == nil else { throw CalendarToolArgumentError("Finish or stop the current conversation first.") }
    }
    func saveTask(_ body: [String: Any]) async throws {
        try validateTaskAction(body)
        guard Set(body.keys).isSubset(of: ["id", "action", "token", "taskID", "title", "dueDate", "dueTime", "timeZone", "notes", "reminderMinutes", "reminderTime", "calendarID"]) else { throw CalendarToolArgumentError("Unsupported task fields.") }
        for key in ["taskID", "dueDate", "dueTime", "timeZone", "notes", "calendarID", "reminderTime"] {
            if let value = body[key], !(value is NSNull), !(value is String) { throw CalendarToolArgumentError("Invalid task field: " + key) }
        }
        var doc = taskDocument
        let existing = (body["taskID"] as? String).flatMap(UUID.init(uuidString:))
        if body["taskID"] != nil && !(body["taskID"] is NSNull) && existing == nil { throw CalendarToolArgumentError("Invalid task.") }
        var task = try existing.map { id in guard let t = doc.items.first(where: { $0.id == id && !$0.deleted }) else { throw CalendarToolArgumentError("This task is no longer available.") }; return t } ?? CalshotTask(title: "", rank: (doc.items.map(\.rank).max() ?? -1) + 1)
        if let receipt = task.receipt, task.receiptDeviceID != Self.syncDeviceID { throw CalendarToolArgumentError("Edit this deadline on its source Mac (\(receipt.calendarName)). Completion and ordering are available here.") }
        guard !calendarActions.proposals.contains(where: { $0.draft.taskID == task.id && !$0.isFinished && $0.isSelected }) else { throw CalendarToolArgumentError("Finish or skip this task’s current deadline review before editing it.") }
        task.title = (body["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func optional(_ key: String) -> String? { (body[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        task.dueDate = optional("dueDate"); task.dueTime = optional("dueTime"); task.timeZone = optional("timeZone") ?? TimeZone.current.identifier; task.notes = body["notes"] as? String ?? ""
        if let value = body["reminderMinutes"], !(value is NSNull) { guard let n = value as? Int, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { throw CalendarToolArgumentError("Invalid reminder.") }; task.reminderMinutes = n } else { task.reminderMinutes = nil }
        task.reminderTime = optional("reminderTime"); task.reminderDeviceID = task.reminderMinutes == nil ? nil : Self.syncDeviceID
        if task.receipt == nil {
            let id = optional("calendarID") ?? selectedCalendarID
            if task.dueDate != nil { guard let id, let calendar = readableCalendars.first(where: { $0.id == id && !$0.isReadOnly && !$0.id.hasPrefix("unavailable:") }) else { throw CalendarToolArgumentError("Choose a connected writable calendar for this deadline.") }; task.calendarID = calendar.id; task.calendarName = calendar.title }
        }
        try task.validate(); task.version = UUID(); task.updatedAt = .now
        if let i = doc.items.firstIndex(where: { $0.id == task.id }) { doc.items[i] = task } else { doc.items.append(task) }
        try persistTasks(doc)
        if task.reminderMinutes != nil, account.enabled { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) ; refreshTaskReminders() }
        if task.needsPublication {
            do { try await reviewTaskDeadline(task.id) }
            catch {
                var latest = taskDocument
                if let i = latest.items.firstIndex(where: { $0.id == task.id && $0.version == task.version }) { latest.items[i].calendarError = error.localizedDescription; try persistTasks(latest) }
            }
        }
        Task { await self.syncTasks() }
    }
    func changeTask(_ body: [String: Any]) throws {
        try validateTaskAction(body)
        guard let raw = body["taskID"] as? String, let id = UUID(uuidString: raw), let i = taskDocument.items.firstIndex(where: { $0.id == id }) else { throw CalendarToolArgumentError("This task is no longer available.") }
        guard Set(body.keys).isSubset(of: ["id", "action", "token", "taskID", "completed", "offset", "targetTaskID", "archived"]) else { throw CalendarToolArgumentError("Unsupported task fields.") }
        guard !calendarActions.proposals.contains(where: { $0.draft.taskID == id && !$0.isFinished && $0.isSelected }) else { throw CalendarToolArgumentError("Finish or skip this task’s deadline review first.") }
        var doc = taskDocument
        switch body["action"] as? String {
        case "completeTask": guard !doc.items[i].deleted, let completed = body["completed"] as? Bool, CFGetTypeID(body["completed"] as CFTypeRef) == CFBooleanGetTypeID() else { throw CalendarToolArgumentError("Choose a completion state.") }; doc.items[i].completed = completed
        case "reorderTask":
            var order = doc.items.filter { !$0.deleted && !$0.completed }.sorted { $0.rank == $1.rank ? $0.id.uuidString < $1.id.uuidString : $0.rank < $1.rank }.map(\.id)
            guard let from = order.firstIndex(of: id) else { throw CalendarToolArgumentError("Only open tasks can be reordered.") }
            let to: Int
            if let target = body["targetTaskID"] as? String, let targetID = UUID(uuidString: target), let index = order.firstIndex(of: targetID) { to = index }
            else if let offset = body["offset"] as? Int, CFGetTypeID(body["offset"] as CFTypeRef) != CFBooleanGetTypeID(), [-1,1].contains(offset), order.indices.contains(from + offset) { to = from + offset }
            else { throw CalendarToolArgumentError("Choose a valid task position.") }
            order.remove(at: from); order.insert(id, at: to)
            for (rank, key) in order.enumerated() {
                guard let index = doc.items.firstIndex(where: { $0.id == key }), doc.items[index].rank != rank else { continue }
                doc.items[index].rank = rank; doc.items[index].version = UUID(); doc.items[index].updatedAt = .now
            }
        case "archiveTask": guard let archived = body["archived"] as? Bool, CFGetTypeID(body["archived"] as CFTypeRef) == CFBooleanGetTypeID() else { throw CalendarToolArgumentError("Choose an archive state.") }; doc.items[i].deleted = archived
        default: throw CalendarToolArgumentError("Unknown task action.")
        }
        doc.items[i].version = UUID(); doc.items[i].updatedAt = .now; try persistTasks(doc)
        Task { await self.syncTasks() }
    }
    func reviewTaskDeadline(_ id: UUID) async throws {
        guard !agentIsRunning, !isSaving, !isCapturing, !isRecognizing, agentQuestion == nil else { throw CalendarToolArgumentError("Finish the current task first.") }
        guard let task = taskDocument.items.first(where: { $0.id == id && !$0.deleted }), task.needsPublication else { return }
        guard task.receipt == nil || task.receiptDeviceID == Self.syncDeviceID else { throw CalendarToolArgumentError("Review this deadline on its source Mac.") }
        guard !calendarActions.proposals.contains(where: { !$0.isFinished && $0.isSelected }) else { throw CalendarToolArgumentError("Finish or skip the current calendar review first. Your task is saved.") }
        let owner = account.userID, storeURL = taskStore.url, generation = currentCaptureSessionID
        var proposal = try task.deadline(owner: owner, deviceID:Self.syncDeviceID)
        if let receipt = task.receipt {
            guard let before = try await calendarService.event(identifier: receipt.eventIdentifier, in: .resolve(identifier: receipt.destinationID)) else { throw CalendarToolArgumentError("The linked calendar entry is unavailable. Check the source calendar before retrying; a second entry was not created.") }
            guard account.userID == owner, taskStore.url == storeURL, currentCaptureSessionID == generation, !agentIsRunning, !isSaving, taskDocument.items.first(where: { $0.id == id })?.version == task.version else { throw CancellationError() }
            proposal.before = before.draft
        }
        guard task.calendarID != nil else { throw CalendarToolArgumentError("Choose a writable deadline calendar.") }
        guard !task.completed else { throw CalendarToolArgumentError("Reopen the task before publishing its deadline.") }
        image = nil; recognizedText = ""; agentMessages = []; agentTranscriptPrefix = []; agentSummary = nil; agentError = nil; agentStreamingText = ""; activeAgentRunID = nil
        let record = try memoryStore.recordCommand("Review deadline: " + task.title)
        currentMemoryRecordID = record.id; currentCaptureSessionID = UUID(); selectedCalendarID = task.calendarID
        calendarActions.replace(with: [proposal]); try memoryStore.updateProposals(for: record.id, proposals: [proposal]).map { _ in () }; refreshMemory()
    }
    func validateTaskApproval() throws {
        for p in calendarActions.proposals where p.isSelected && !p.isFinished && p.draft.taskID != nil {
            guard p.draft.taskOwnerID == account.userID, let t = (taskDocument.items + (taskImport?.items ?? [])).first(where: { $0.id == p.draft.taskID && !$0.deleted }), t.version == p.draft.taskVersion,
                  p.operation == .delete || p.draft.isAllDay, p.draft.isTaskDeadline == true,
                  p.targetDestinationID == t.calendarID, selectedCalendarID == t.calendarID, !t.completed else { throw CalendarToolArgumentError("This task changed. Return to Tasks and review its current deadline.") }
            if p.operation != .delete { _ = try t.applying(p.draft) }
        }
    }
    func reconcileTaskReceipts(_ rows: [CalendarActionProposal]) throws {
        var doc = taskDocument; var changed = false
        for p in rows {
            guard p.draft.taskOwnerID == account.userID, let i = doc.items.firstIndex(where: { $0.id == p.draft.taskID }), doc.items[i].version == p.draft.taskVersion else { continue }
            if let receipt = p.receipt, p.isFinished {
                if p.operation == .delete { doc.items[i].receipt = nil; doc.items[i].receiptDeviceID = nil }
                else {
                    doc.items[i] = try doc.items[i].applying(p.draft)
                    doc.items[i].receipt = receipt; doc.items[i].receiptDeviceID = Self.syncDeviceID; doc.items[i].calendarID = receipt.destinationID; doc.items[i].calendarName = receipt.calendarName
                }
                doc.items[i].publishedFingerprint = doc.items[i].fingerprint; doc.items[i].calendarError = nil; doc.items[i].version = UUID(); changed = true
            } else if p.state == .failed { doc.items[i].calendarError = p.error; changed = true }
        }
        if changed { try persistTasks(doc) }
    }
    func syncTasks(keepBoth: Bool = false) async {
        guard let owner = account.userID, activeLocalAccountID == owner, taskDataReady, !taskSyncBusy, !agentIsRunning, !isSaving else { return }
        let store = taskStore; let token = tasksToken; let session = taskSessionID; taskSyncBusy = true
        defer { if taskSessionID == session { taskSyncBusy = false } }
        do {
            let remoteData = try await taskStateRPC("read_task_state", body: .object([:]), owner: owner)
            let remote = try JSONDecoder.taskState.decode(CalshotTaskCloud.self, from: JSONEncoder().encode(remoteData))
            guard remote.revision >= 0, remote.items.count <= 1000, Set(remote.items.map(\.id)).count == remote.items.count else { throw CalendarToolArgumentError("The synced task list could not be validated.") }
            guard taskSessionID == session, account.userID == owner, taskStore.url == store.url, tasksToken == token, !agentIsRunning, !isSaving else { return }
            var merged = taskDocument.items
            for r in remote.items {
                try r.validate()
                guard let i = merged.firstIndex(where: { $0.id == r.id }) else { merged.append(r); continue }
                let local = merged[i], baseline = taskDocument.baseline[r.id.uuidString]
                if local.version == r.version { continue }
                if baseline == local.version { merged[i] = r }
                else if baseline != r.version {
                    guard keepBoth else { taskConflict = true; throw CalendarToolArgumentError("A task changed on another device. Keep both versions to finish syncing without losing edits.") }
                    var copy = local; copy.id = UUID(); copy.version = UUID(); copy.title = String((copy.title + " (local copy)").prefix(500)); copy.receipt = nil; copy.receiptDeviceID = nil; copy.publishedFingerprint = nil; copy.reminderMinutes = nil; copy.reminderTime = nil; copy.reminderDeviceID = nil; copy.calendarError = "Local copy kept after a sync conflict. Review before publishing."; merged[i] = r; merged.append(copy)
                }
            }
            guard merged.count <= 1000 else { throw CalendarToolArgumentError("Task sync supports up to 1,000 tasks.") }
            let data = try CalshotTaskStore.encoder.encode(merged)
            let encodedRemote = try CalshotTaskStore.encoder.encode(remote.items.sorted { $0.id.uuidString < $1.id.uuidString })
            let mergedData = try CalshotTaskStore.encoder.encode(merged.sorted { $0.id.uuidString < $1.id.uuidString })
            if mergedData != encodedRemote {
                let _ = try await taskStateRPC("write_task_state", body: .object(["items": try JSONDecoder().decode(JSONValue.self, from: data), "expected_revision": .number(Double(remote.revision))]), owner: owner)
            }
            guard taskSessionID == session, account.userID == owner, taskStore.url == store.url, tasksToken == token, !agentIsRunning, !isSaving else { return }
            let doc = CalshotTaskDocument(items: merged, baseline: Dictionary(uniqueKeysWithValues: merged.map { ($0.id.uuidString, $0.version) }))
            try persistTasks(doc); taskError = nil; taskConflict = false
        } catch is CancellationError {} catch { if taskSessionID == session, account.userID == owner { taskError = "Tasks not synced: \(error.localizedDescription). Local changes are kept." } }
    }
    private func taskStateRPC(_ name: String, body: JSONValue, owner: UUID) async throws -> JSONValue {
        if let taskRPC { return try await taskRPC(name, body, owner) }
        return try await account.syncRPC(name, body: body, user: owner)
    }
    func refreshTaskReminders() {
        taskReminderWork?.cancel(); let generation = UUID(); taskReminderGeneration = generation
        guard account.enabled, let owner = account.userID, account.canUseWorkspace else { return }
        let tasks = taskDocument.items; let token = tasksToken
        taskReminderWork = Task { @MainActor [weak self] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            guard self.account.userID == owner, self.tasksToken == token, self.taskReminderGeneration == generation, !Task.isCancelled else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("calshot.task.") }.map(\.identifier))
            let active = tasks.filter { !$0.deleted && !$0.completed && $0.reminderMinutes != nil && $0.reminderDeviceID == Self.syncDeviceID }
            guard !active.isEmpty else { self.taskReminderError = nil; return }
            let settings = await center.notificationSettings()
            guard self.account.userID == owner, self.tasksToken == token, self.taskReminderGeneration == generation, !Task.isCancelled else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { self.taskReminderError = "Mac reminders are not enabled. Allow notifications for Calshot in System Settings."; return }
            self.taskReminderError = nil
            for t in active {
                guard self.account.userID == owner, self.tasksToken == token, self.taskReminderGeneration == generation, !Task.isCancelled else { return }
                do {
                    guard let day = t.dueDate, let date = try? CalshotTask.date(day, time: t.dueTime ?? t.reminderTime, zone: t.timeZone).addingTimeInterval(-Double(t.reminderMinutes! * 60)), date > .now else { continue }
                    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: t.timeZone)!
                    var components = cal.dateComponents([.year,.month,.day,.hour,.minute], from: date); components.timeZone = cal.timeZone
                    let content = UNMutableNotificationContent(); content.title = t.title; content.body = "Task deadline: \(day)\(t.dueTime.map { " at " + $0 } ?? "")"; content.sound = .default
                    let identifier = "calshot.task." + owner.uuidString + "." + generation.uuidString + "." + t.id.uuidString
                    try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
                    if Task.isCancelled || self.taskReminderGeneration != generation || self.account.userID != owner { center.removePendingNotificationRequests(withIdentifiers: [identifier]); return }
                } catch { self.taskReminderError = "A Mac reminder could not be scheduled. Reopen Tasks and try again." }
            }
        }
    }
}
private enum UUIDToken { static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() } }

private extension JSONDecoder { static var taskState: JSONDecoder { CalshotTaskStore.decoder } }

@MainActor
extension CalshotModel {
    func createAgentTasks(_ fields: [String: JSONValue]) throws -> (saved: JSONValue, proposals: [CalendarActionProposal]) {
        try CalendarToolDraftMapper.keys(fields, allowed: ["tasks", "calendarIdentifier"])
        guard taskDataReady, !taskSyncBusy, !isSaving, currentMemoryRecordID != nil,
              let rows = fields["tasks"]?.arrayValue, !rows.isEmpty, rows.count <= 100 else { throw CalendarToolArgumentError("Tasks are not ready or the batch is outside the 1–100 task limit.") }
        guard !calendarActions.proposals.contains(where: { !$0.isFinished && $0.isSelected }) else { throw CalendarToolArgumentError("Finish the existing review before adding another task batch.") }
        let destination = try CalendarToolDraftMapper.string(fields, "calendarIdentifier", limit: 1024) ?? selectedCalendarID
        var doc = taskDocument, proposals: [CalendarActionProposal] = [], saved: [JSONValue] = []
        for row in rows {
            guard let f = row.objectValue else { throw CalendarToolArgumentError("Each task must be an object.") }
            try CalendarToolDraftMapper.keys(f, allowed: ["title", "dueDate", "dueTime", "timeZone", "notes", "sourceText", "yearResolved"])
            let title = try CalendarToolDraftMapper.string(f, "title", required: true, limit: 500)!
            let day = try CalendarToolDraftMapper.string(f, "dueDate", limit: 10)
            let resolved = f["yearResolved"] == .bool(true)
            var task = CalshotTask(title: title, dueDate: resolved ? day : nil,
                dueTime: resolved && day != nil ? try CalendarToolDraftMapper.string(f, "dueTime", limit: 5) : nil,
                timeZone: try CalendarToolDraftMapper.string(f, "timeZone", limit: 100) ?? TimeZone.current.identifier,
                notes: try CalendarToolDraftMapper.string(f, "notes", limit: 8000) ?? "",
                rank: (doc.items.map(\.rank).max() ?? -1) + 1,
                sourceText: try CalendarToolDraftMapper.string(f, "sourceText", required: true, limit: 8000))
            if day != nil && !resolved { task.calendarError = "Deadline year is unresolved. Add the full date in Tasks before calendar review." }
            if task.dueDate != nil {
                guard let destination, let calendar = readableCalendars.first(where: { $0.id == destination && !$0.isReadOnly && !$0.id.hasPrefix("unavailable:") }) else { throw CalendarToolArgumentError("Choose a connected writable deadline calendar.") }
                task.calendarID = calendar.id; task.calendarName = calendar.title
            }
            try task.validate()
            if let existing = doc.items.first(where: { !$0.deleted && $0.title == task.title && $0.dueDate == task.dueDate && $0.dueTime == task.dueTime && $0.timeZone == task.timeZone && $0.notes == task.notes && $0.calendarID == task.calendarID && $0.sourceText == task.sourceText }) {
                if taskDocument.items.contains(where: { $0.id == existing.id }) { saved.append(.object(["id": .string(existing.id.uuidString), "title": .string(existing.title), "alreadyInTasks": .bool(true)])) }
                continue
            }
            doc.items.append(task)
            saved.append(.object(["id": .string(task.id.uuidString), "title": .string(task.title), "deadlineReady": .bool(task.dueDate != nil)]))
            if task.dueDate != nil { proposals.append(try task.deadline(owner: account.userID, deviceID:Self.syncDeviceID)) }
        }
        let newItems = doc.items.filter { candidate in !taskDocument.items.contains(where: { $0.id == candidate.id }) }
        if !newItems.isEmpty {
            guard doc.items.count <= 1000 else { throw CalendarToolArgumentError("Tasks supports up to 1,000 items.") }
            taskImport = CalshotTaskImport(items:newItems, selectedInboxIDs:Set(newItems.filter { $0.dueDate == nil }.map(\.id)), ownerID:account.userID, captureID:currentCaptureSessionID, recordID:currentMemoryRecordID, storeURL:taskStore.url)
            if let destination, !proposals.isEmpty { selectedCalendarID = destination }
        }
        return (.array(saved), proposals)
    }
    var taskImportIsCurrent: Bool {
        guard let batch = taskImport else { return false }
        return agentIsWaitingForApproval && batch.ownerID == account.userID && batch.captureID == currentCaptureSessionID && batch.recordID == currentMemoryRecordID && batch.storeURL == taskStore.url && taskDataReady
    }
    var canApproveTaskImport: Bool {
        guard taskImportIsCurrent, !isSaving, !calendarActions.isCheckingDuplicates else { return false }
        return calendarActions.selectedCount > 0 ? calendarActions.canApprove : !(taskImport?.selectedInboxIDs.isEmpty ?? true)
    }
    func commitTaskImport() throws {
        guard taskImportIsCurrent, let batch = taskImport else { throw CalendarToolArgumentError("This task import is no longer current. Start a new review.") }
        var doc = taskDocument
        for var task in batch.items where !doc.items.contains(where: { $0.id == task.id }) {
            if task.dueDate == nil { guard batch.selectedInboxIDs.contains(task.id) else { continue } }
            else {
                guard let p = calendarActions.proposals.first(where: { $0.draft.taskID == task.id && $0.isSelected && !$0.isFinished && calendarActions.isInApprovalScope($0.id) }), p.isApprovable else { continue }
                guard p.draft.taskVersion == task.version, p.draft.taskOwnerID == batch.ownerID, p.draft.isAllDay, let start=p.draft.startDate else { throw CalendarToolArgumentError("The task deadline changed. Review it again.") }
                task = try task.applying(p.draft)
            }
            try task.validate(); doc.items.append(task)
        }
        try persistTasks(doc)
    }
    func taskImportReceipts(_ prepared: JSONValue) -> JSONValue {
        .array((prepared.arrayValue ?? []).compactMap { row in
            guard let id=row.objectValue?["id"]?.stringValue.flatMap(UUID.init(uuidString:)), let task=taskDocument.items.first(where:{$0.id==id}) else { return nil }
            return .object(["id":.string(task.id.uuidString),"title":.string(task.title),"alreadyInTasks":row.objectValue?["alreadyInTasks"] ?? .bool(false)])
        })
    }
}

#if DEBUG
@MainActor
extension CalshotModel {
    static func tasksPreviewModel() -> CalshotModel {
        let model = CalshotModel(calendarService: CalendarDemoService(), memoryStore: MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("CalshotTasksPreview-" + UUID().uuidString)), loadsAIConnection: false)
        model.workspaceSelection = .tasks
        model.taskDocument.items = (0..<12).map { i in
            CalshotTask(title: ["Finish the research methods assignment", "Outline the studio presentation", "Read chapter four and write discussion notes", "Submit the field report — observations, illustrations and the full reference list"][i % 4], dueDate: i % 4 == 2 ? nil : String(format: "2026-11-%02d", 1 + i), dueTime: i % 3 == 0 && i % 4 != 2 ? "17:00" : nil, timeZone: "America/Toronto", notes: "Fictional task for isolated UI verification.", completed: i == 10, deleted: i == 11, rank: i, calendarID: "demo", calendarName: "Demo calendar")
        }
        model.taskError = "Isolated preview · Fictional tasks and calendar. No real calendar writes."
        Task { await model.loadCalendars() }
        return model
    }
}
#endif
