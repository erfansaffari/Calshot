import Foundation
import AppKit
import CryptoKit
import CoreGraphics

/// Explicit, credential-free view state. OAuth/API secrets never cross into JavaScript.
@MainActor
enum WebWorkspaceState {
    /// Creating a formatter costs far more than formatting; snapshots are built often, so share one.
    static let iso = ISO8601DateFormatter()
    private static let snapshotEncoder: JSONEncoder = { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }()
    /// Decoded values by their encoded bytes. Most of a snapshot (the chat, tasks, rows) is unchanged between
    /// snapshots, and decoding it again was most of the cost of building one.
    private static var decodedCache: [Data: JSONValue] = [:]
    static func encoded<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? snapshotEncoder.encode(value) else { return .null }
        if let cached = decodedCache[data] { return cached }
        guard let result = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        if decodedCache.count >= 512 { decodedCache.removeAll(keepingCapacity: true) }
        decodedCache[data] = result
        return result
    }
    /// Local, read-only inspection. Never gathers a new screen or sends data to an AI service.
    static func contextInspection(_ model: CalshotModel) throws -> JSONValue {
        let conversation = try model.ongoingConversationContext(limit: 40, budget: 24_000)
        let rows = conversation.objectValue?["turns"]?.arrayValue ?? []
        let transcript = rows.compactMap { row -> String? in
            guard let fields = row.objectValue, let text = fields["text"]?.stringValue else { return nil }
            return (fields["role"]?.stringValue == "user" ? "You: " : "Assistant: ") + text
        }.joined(separator: "\n\n")
        let personal = model.personalMemory
        let memories = personal.items.filter { $0.status == .active && !$0.isExpired(at: Date()) }
        let screen = model.agentToolExecutor?.memorySuggestionsBlocked == true ? "Withheld: this run contains shared-friend context." : String((model.voiceSession.active ? model.voiceScreenText : model.recognizedText).prefix(16_000))
        let receipts = model.calendarChangeLedger().prefix(10).map { "\($0.operation.rawValue): \($0.draft.title) · \($0.receipt?.calendarName ?? "Calendar")" }.joined(separator: "\n")
        func section(_ title: String, _ detail: String, _ text: String, _ empty: String) -> JSONValue {
            .object(["title": .string(title), "detail": .string(detail), "text": .string(text.isEmpty ? empty : text)])
        }
        return .object(["capturedAt": .string(ISO8601DateFormatter().string(from: Date())), "sections": .array([
            section("Saved memories", "Approved, unexpired memories. Pending suggestions are not used. Manage these in Memory below.", personal.error.map { "Unavailable: " + $0 } ?? memories.map { "[\($0.kind.rawValue)] \($0.text)" }.joined(separator: "\n\n"), "No approved memories saved."),
            section("Who you are and earlier conversations", "Your name and account, and Calshot's dated notes on earlier conversations. Sent with each request. Notes stay on this Mac.", [model.userIdentityContext, MemoryContextBuilder.notes(personal.notes)].filter { !$0.isEmpty }.joined(separator: "\n\n"), "Nothing yet."),
            section("Retained conversation", "Recent bounded excerpts; up to 600 stored turns are retained. Older retained details can be retrieved by the assistant. Shared-friend turns and raw tool calls are excluded. Excerpts may be clipped.", transcript, "No retained conversation excerpts."),
            section("Connected calendars", "Readable sources available to calendar tools. This list does not mean every event has been read.", model.readableCalendars.map { "\($0.title) · \($0.provider.rawValue)" }.joined(separator: "\n"), "No readable calendars connected."),
            section("Voice calendar snapshot", "The last snapshot sent during this voice session, with freshness status. This viewer does not fetch calendar events.", model.voiceSession.scheduleContextForInspection, "No voice snapshot."),
            section("Screen text", "Latest captured text, limited to 16,000 characters. Captured evidence, not a live screen. Images may also accompany a request; they are not shown here.", screen, "No screen text available."),
            section("Saved calendar changes", "Up to 10 recent changes backed by native receipts. These are historical outcomes, not current event state.", receipts, "No saved calendar changes."),
            section("Tasks", "Up to 100 current task titles available through native task tools; full details are read on request.", model.taskError.map { "Unavailable: " + $0 } ?? model.taskDocument.items.filter { !$0.deleted }.prefix(100).map { $0.title }.joined(separator: "\n"), "No current tasks.")
        ])])
    }
    static func approvalToken(_ model: CalshotModel) -> String {
        let rows = model.calendarActions.proposals.filter { model.calendarActions.isInApprovalScope($0.id) && !$0.isFinished }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; encoder.dateEncodingStrategy = .iso8601
        let context = (model.currentCaptureSessionID?.uuidString ?? "") + "|" + (model.currentMemoryRecordID?.uuidString ?? "") + "|" + (model.activeAgentRunID?.uuidString ?? "") + "|" + (model.selectedCalendarID ?? "")
        let taskContext = (model.taskImport?.id.uuidString ?? "") + (model.taskImport?.selectedInboxIDs.map(\.uuidString).sorted().joined() ?? "")
        var data = Data((context + taskContext).utf8); data.append((try? encoder.encode(rows)) ?? Data())
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func make(_ model: CalshotModel, imageURL: String?, notice: String?, accounts: [JSONValue], googleReady: Bool, comparisons: [String: JSONValue] = [:]) -> JSONValue {
        var state: [String: JSONValue] = [:]
        func string(_ key: String, _ value: String?) { if let value { state[key] = .string(value) } }
        func flag(_ key: String, _ value: Bool) { state[key] = .bool(value) }
        state["tasks"] = .object(["items": encoded(model.taskDocument.items), "token": .string(model.tasksToken), "loaded": .bool(model.taskDataReady), "busy": .bool(model.taskSyncBusy), "error": model.taskError.map(JSONValue.string) ?? .null, "reminderError": model.taskReminderError.map(JSONValue.string) ?? .null, "conflict": .bool(model.taskConflict), "deviceID": .string(CalshotModel.syncDeviceID)])
        let personal = model.personalMemory
        state["personalMemory"] = .object(["loaded": .bool(personal.error == nil), "error": personal.error.map(JSONValue.string) ?? .null,
            "items": encoded(personal.items.filter { $0.status == .active }), "pending": encoded(personal.items.filter { $0.status == .pendingApproval }), "notes": encoded(Array(personal.notes.suffix(30).reversed())), "token": .string(personal.token),
            "sync": model.knowledgeSyncSnapshot])
        state["voice"] = model.voiceSession.snapshot
        state["recentChanges"] = model.recentChangesSnapshot()
        state["calendarContentToken"] = .string(model.calendarContentToken.uuidString)
        state["voiceShortcut"] = .string(model.voiceShortcut.label)
        func shortcutState(_ target: ShortcutTarget, _ value: GlobalShortcut, fallback: GlobalShortcut) -> JSONValue {
            .object(["label": .string(value.label), "isDefault": .bool(value.sameKeys(as: fallback)), "error": model.shortcutError(target).map(JSONValue.string) ?? .null])
        }
        state["shortcuts"] = .object(["recording": model.shortcutRecordingTarget.map { .string($0.rawValue) } ?? .null,
            "capture": shortcutState(.capture, model.shortcut, fallback: .default), "voice": shortcutState(.voice, model.voiceShortcut, fallback: .voiceDefault)])
        state["softwareUpdate"] = model.softwareUpdates.snapshot
        // Device-local task-only review/outcome and Settings permissions. None of this is account-synced.
        let taskReview = model.agentTaskReviewSnapshot()
        if taskReview != .null { state["taskReview"] = taskReview }
        let taskOutcome = model.agentTaskOutcomeSnapshot()
        if taskOutcome != .null { state["taskOutcome"] = taskOutcome }
        state["agentPermissions"] = model.agentPermissionSnapshot()
        state["sidebarWidth"] = .number(model.sidebarWidth)
        flag("sidebarExpanded", model.sidebarExpanded); flag("ready", true); flag("native", true); string("page", model.workspaceSelection.rawValue)
        string("status", model.status); string("notice", notice); string("imageURL", imageURL)
        string("captureID", model.currentCaptureSessionID?.uuidString); string("ocr", String(model.recognizedText.prefix(16000)))
        flag("isCapturing", model.isCapturing); flag("isRecognizing", model.isRecognizing)
        flag("running", model.agentIsRunning); string("streaming", model.agentStreamingText)
        string("agentStatus", model.agentStatus); string("summary", model.agentSummary); string("agentError", model.agentError)
        flag("canRetry", model.agentRetryPrompt != nil); flag("waitingApproval", model.agentIsWaitingForApproval)
        state["messages"] = encoded(model.agentMessages.compactMap { turn -> AgentTurn? in
            if turn.toolName == nil && (turn.role == "user" || turn.role == "assistant") { return turn }
            guard turn.toolName == "ask_user" else { return nil }
            if turn.role == "tool", let raw = turn.result, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) {
                if let answer = value.objectValue?["answer"]?.stringValue { return AgentTurn(role: "user", content: answer) }
                if value.objectValue?["cancelled"]?.boolValue == true { return AgentTurn(role: "user", content: "Cancelled this question.") }
            }
            return nil
        })
        if let question = model.agentQuestion {
            state["question"] = .object(["id": .string(question.id.uuidString), "question": .string(question.question), "choices": encoded(question.choices)])
        }
        state["proposals"] = .array(model.calendarActions.proposals.map { item in
            var row = encoded(item).objectValue ?? [:]
            if model.currentMemoryRecordID != nil { row["sourceImageURL"] = .string("calshot-asset://proposal/" + item.id.uuidString) }
            row["id"] = .string(item.id.uuidString); row["status"] = .string(item.status)
            row["isFinished"] = .bool(item.isFinished); row["isApprovable"] = .bool(item.isApprovable)
            row["inScope"] = .bool(model.calendarActions.isInApprovalScope(item.id))
            row["issues"] = encoded(item.issues)
            row["canSelect"] = .bool(!item.isFinished && item.state != .saving && model.calendarActions.isInApprovalScope(item.id) &&
                (item.operation == .delete ? !(item.targetEventIdentifier?.isEmpty ?? true) : item.isSelected || item.canAdd))
            return .object(row)
        })
        string("approvalToken", approvalToken(model)); flag("canApprove", (model.taskImport != nil ? model.canApproveTaskImport : model.calendarActions.canApprove) && (!model.agentIsRunning || model.agentIsWaitingForApproval))
        if let batch=model.taskImport { state["taskImport"] = .object(["id":.string(batch.id.uuidString),"items":encoded(batch.items),"selectedInboxIDs":encoded(batch.selectedInboxIDs)]) }
        state["selectedCount"] = .number(Double(model.calendarActions.selectedCount))
        flag("checking", model.calendarActions.isCheckingDuplicates); flag("saving", model.isSaving)
        string("reviewMessage", model.calendarActions.message ?? model.saveMessage)
        state["calendars"] = .array(model.readableCalendars.map { calendar in
            .object(["id": .string(calendar.id), "title": .string(calendar.title), "provider": .string(calendar.provider.rawValue),
                     "sourceName": .string(calendar.sourceName ?? calendar.provider.rawValue.capitalized),
                     "isReadOnly": .bool(calendar.isReadOnly), "direct": .bool(calendar.id.hasPrefix("remote:") || calendar.id.hasPrefix("icloud:")),
                     "unavailable": .bool(calendar.id.hasPrefix("unavailable:"))])
        })
        if model.account.userID != nil {
            state["sharing"] = .object(["loaded": .bool(model.sharingLoaded), "busy": .bool(model.sharingBusy), "error": model.sharingError.map(JSONValue.string) ?? .null, "token": .string(model.calendarSharing.token), "sources": encoded(model.calendarSharing.sources), "shares": encoded(model.calendarSharing.shares)])
            state["webCalendarSync"] = .object(["busy": .bool(model.macCalendarSyncBusy), "error": model.macCalendarSyncError.map(JSONValue.string) ?? .null, "mirrors": encoded(model.macCalendarMirrors), "sourceKeys": .object(Dictionary(uniqueKeysWithValues: model.readableCalendars.map { ($0.id, JSONValue.string(MacCalendarSnapshot.key($0.id))) }))])
        }
        string("selectedCalendarID", model.selectedCalendarID ?? ""); string("calendarMessage", model.calendarConnectionMessage)
        state["duplicateComparisons"] = .object(comparisons)
        state["accounts"] = .array(accounts); flag("connecting", model.calendarAccountIsConnecting)
        string("connectingProvider", model.connectingCalendarProvider?.rawValue)
        string("accountMessage", model.calendarAccountMessage); flag("accountError", model.calendarAccountError)
        flag("googleReady", googleReady)
        
        
        state["memory"] = .array(model.memoryRecords.map { record in
            let title = record.isMainChat == true ? "Your conversation with Calshot" : record.calendarProposals.first?.draft.title ?? record.agentTranscript?.first(where: { $0.role == "user" })?.content ?? "Screenshot"
            var row: [String: JSONValue] = [
                "id": .string(record.id.uuidString), "title": .string(String(title.prefix(180))),
                "createdAt": .string(iso.string(from: record.createdAt)),
                "completed": .number(Double(record.calendarProposals.filter(\.isFinished).count)),
                "count": .number(Double(record.calendarProposals.count)), "provider": .string(record.analysisProvider ?? "Capture")]
            if !record.screenshotFileName.isEmpty || !(record.additionalScreenshots ?? []).isEmpty {
                row["imageURL"] = .string("calshot-asset://memory/" + record.id.uuidString)
            }
            return .object(row)
        })
        string("memoryLocation", model.memoryDirectoryURL.path); string("shortcut", model.shortcut.label)
        flag("screenPermissionNeeded", model.screenCapturePermissionNeeded)
        flag("screenPermissionGranted", CGPreflightScreenCaptureAccess())
        var settings: [String: JSONValue] = [
            "appearance": .string(model.appearanceMode.rawValue), "glass": encoded(model.glassAppearance), "agentEnabled": .bool(model.openAIAnalysisEnabled), "apiKeySaved": .bool(model.hasOpenAIAPIKey),
            "useAPIKey": .bool(model.agentUseAPIKey), "chatGPTPlan": .bool(model.chatGPTAccount?.canUsePlan == true), "chatGPTConnecting": .bool(model.chatGPTIsConnecting),
            "model": .string(model.agentUseAPIKey || model.chatGPTAccount == nil ? OpenAIEventAnalyzer.modelName : model.chatGPTAccount?.model ?? ""),
            "models": .array(model.chatGPTModels.map { .object(["id": .string($0.slug), "name": .string($0.displayName)]) }),
            "copyCaptures": .bool(CaptureClipboard.automaticallyCopyCapture), "notchEnabled": .bool(model.notchEnabled), "notchAvailable": .bool(CalshotModel.notchAvailable)]
        if let email = model.chatGPTAccount?.email { settings["chatGPTEmail"] = .string(email) }
        if let error = model.chatGPTConnectionError { settings["chatGPTError"] = .string(error) }
        state["settings"] = .object(settings)
        state["displayAccessibility"] = .object([
            "reducedTransparency": .bool(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency),
            "increasedContrast": .bool(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)])
        state["auth"] = model.account.snapshot
        if model.account.userID != nil {
            state["accountSync"] = .object([
                "busy": .bool(model.accountSyncBusy), "status": .string(model.accountSyncStatus),
                "displayName": .string(model.accountDisplayName), "deviceID": .string(CalshotModel.syncDeviceID),
                "devices": encoded(model.accountSyncDevices), "lastSyncedAt": encoded(model.accountSyncLastDate),
                "error": model.accountSyncError.map(JSONValue.string) ?? .null])
        }
        if model.account.requiresLogin {
            for key in ["messages", "proposals", "calendars", "accounts", "memory"] { state[key] = .array([]) }
            state.removeValue(forKey: "voice"); state.removeValue(forKey: "personalMemory"); state.removeValue(forKey: "tasks"); state.removeValue(forKey: "taskImport")
            for key in ["taskReview", "taskOutcome", "agentPermissions", "recentChanges"] { state.removeValue(forKey: key) }
            for key in ["imageURL", "summary", "question", "agentError", "status", "notice", "agentStatus"] { state.removeValue(forKey: key) }
            state["ocr"] = .string(""); state["streaming"] = .string(""); state["canApprove"] = .bool(false)
            state["waitingApproval"] = .bool(false); state["running"] = .bool(false)
        }
        return .object(state)
    }
}
