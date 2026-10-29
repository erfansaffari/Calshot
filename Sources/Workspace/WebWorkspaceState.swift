import Foundation
import CryptoKit
import CoreGraphics

/// Explicit, credential-free view state. OAuth/API secrets never cross into JavaScript.
@MainActor
enum WebWorkspaceState {
    static func encoded<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), let result = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return result
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
            let title = record.calendarProposals.first?.draft.title ?? record.agentTranscript?.first(where: { $0.role == "user" })?.content ?? "Screenshot"
            var row: [String: JSONValue] = [
                "id": .string(record.id.uuidString), "title": .string(String(title.prefix(180))),
                "createdAt": .string(ISO8601DateFormatter().string(from: record.createdAt)),
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
            "appearance": .string(model.appearanceMode.rawValue), "agentEnabled": .bool(model.openAIAnalysisEnabled), "apiKeySaved": .bool(model.hasOpenAIAPIKey),
            "useAPIKey": .bool(model.agentUseAPIKey), "chatGPTPlan": .bool(model.chatGPTAccount?.canUsePlan == true), "chatGPTConnecting": .bool(model.chatGPTIsConnecting),
            "model": .string(model.agentUseAPIKey || model.chatGPTAccount == nil ? OpenAIEventAnalyzer.modelName : model.chatGPTAccount?.model ?? ""),
            "models": .array(model.chatGPTModels.map { .object(["id": .string($0.slug), "name": .string($0.displayName)]) }),
            "copyCaptures": .bool(CaptureClipboard.automaticallyCopyCapture), "notchEnabled": .bool(model.notchEnabled)]
        if let email = model.chatGPTAccount?.email { settings["chatGPTEmail"] = .string(email) }
        if let error = model.chatGPTConnectionError { settings["chatGPTError"] = .string(error) }
        state["settings"] = .object(settings)
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
            state.removeValue(forKey: "tasks"); state.removeValue(forKey: "taskImport")
            for key in ["taskReview", "taskOutcome", "agentPermissions"] { state.removeValue(forKey: key) }
            for key in ["imageURL", "summary", "question", "agentError", "status", "notice", "agentStatus"] { state.removeValue(forKey: key) }
            state["ocr"] = .string(""); state["streaming"] = .string(""); state["canApprove"] = .bool(false)
            state["waitingApproval"] = .bool(false); state["running"] = .bool(false)
        }
        return .object(state)
    }
}
