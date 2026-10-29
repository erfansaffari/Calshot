import AppKit
import Combine
import Foundation

extension CalshotModel {
    var canUseCalendarAgent: Bool {
        agentClient != nil || (openAIAnalysisEnabled && (chatGPTAccount?.canUsePlan == true || hasOpenAIAPIKey))
    }

    func configureCalendarAgent() {
        guard calendarAgent == nil else { return }
        let executor = CalendarAgentToolExecutor(service: calendarService, coordinator: calendarActions,
            destination: { [weak self] in
                guard let self, let id = self.selectedCalendarID,
                      let info = self.destinations.first(where: { $0.id == id && !$0.isReadOnly }) else { return nil }
                return (id, info.title)
            }, searchDestinations: { [weak self] in self?.readableCalendars ?? [] },
            onTargetDestination: { [weak self] in self?.selectedCalendarID = $0 }, screenText: { [weak self] in
                guard let self else { return "" }
                if self.voicePreparedRunID == self.activeAgentRunID, self.voicePreparedRunID != nil { return "" }
                let captureID = self.currentCaptureSessionID
                if let task = self.ocrTask, let result = try? await task.value {
                    guard self.currentCaptureSessionID == captureID, !Task.isCancelled else { return "" }
                    self.screenRecognition = result; self.recognizedText = result.text
                    return result.text
                }
                return self.recognizedText
            }, sourceContext: { [weak self] in self?.currentAgentPrompt ?? "" },
            sourceRegion: { [weak self] in self?.screenRecognition.region(for: $0) },
            sourceCaptureID: { [weak self] in self?.currentAgentSourceID },
            onApproval: { [weak self] value in self?.agentIsWaitingForApproval = value; self?.voiceSession.review(value) },
            onQuestion: { [weak self] question in self?.agentQuestion = question },
            onStep: { [weak self] text in self?.agentStatus = text })
        executor.remember = { [weak self] kind, text in
            guard let self else { throw CancellationError() }
            try self.suggestPersonalMemory(kind: kind, text: text, sourceReference: self.currentMemoryRecordID?.uuidString)
        }
        executor.recall = { [weak self] query in
            guard let self else { throw CancellationError() }
            if let error = self.personalMemory.error { throw CalendarToolArgumentError(error) }
            return self.personalMemoryContext(for: query)
        }
        executor.listFriends = { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.listAgentFriends()
        }
        executor.listTasks = { [weak self] in
            guard let self, let runID = self.activeAgentRunID else { throw CancellationError() }
            _ = try self.taskContext(origin: .agent(runID: runID))
            return .array(self.taskDocument.items.map(Self.agentTaskJSON))
        }
        executor.selectedTaskContext = { [weak self] runID in
            guard let self else { throw CancellationError() }
            return try self.selectedAgentTaskContext(runID: runID)
        }
        executor.prepareTaskMutation = { [weak self] change, runID in
            guard let self else { throw CancellationError() }
            return try await self.prepareAgentTaskChange(change, runID: runID)
        }
        // Authorization is native: a saved explicit grant executes the exact request; otherwise a task-only
        // review opens in this conversation. Neither path touches calendar approval or provider writes.
        executor.authorizeTaskMutation = { [weak self] change, runID in
            guard let self else { throw CancellationError() }
            // The executor ran the same pure preflight immediately before this call.
            return try await self.authorizeAgentTaskChange(change, runID: runID, preflighted: true)
        }
        executor.cancelTaskMutation = { [weak self] runID in self?.cancelAgentTaskReview(runID: runID) }
        executor.commitTaskOnlyImport = { [weak self] runID in
            guard let self else { throw CancellationError() }
            return try await self.commitAgentTaskOnlyImport(runID: runID)
        }
        executor.taskImportReceipts = { [weak self] prepared in self?.taskImportReceipts(prepared) ?? .array([]) }
        executor.finishTaskImport = { [weak self] in self?.taskImport = nil }
        executor.createTasks = { [weak self] fields in
            guard let self else { throw CancellationError() }
            return try self.createAgentTasks(fields)
        }
        executor.searchFriend = { [weak self] fields in
            guard let self else { throw CancellationError() }
            return try await self.searchAgentFriend(fields)
        }
        agentToolExecutor = executor
        calendarActions.onExecutionFinished = { [weak executor] proposals in executor?.finishApproval(proposals) }
        let client: any CalendarAgentModelClient
        if let agentClient { client = agentClient }
        else {
            let responses = ResponsesCalendarAgentClient()
            responses.prefersAPIKey = { [weak self] in self?.agentUseAPIKey == true }
            client = responses
        }
        let agent = CalendarAgent(client: client, executor: executor)
        calendarAgent = agent
        agent.$streamingText.sink { [weak self] in self?.agentStreamingText = $0 }.store(in: &agentSubscriptions)
        agent.$isRunning.sink { [weak self] value in self?.agentIsRunning = value }.store(in: &agentSubscriptions)
        agent.$status.sink { [weak self] value in self?.agentStatus = value.isEmpty ? nil : value }.store(in: &agentSubscriptions)
        agent.$finalSummary.sink { [weak self] value in self?.agentSummary = value.isEmpty ? nil : value }.store(in: &agentSubscriptions)
    }

    func analyzeWithCalendarAgent(_ cgImage: CGImage, sessionID: UUID) async {
        guard !voiceSession.active else { agentError = "Voice mode is on — stop it first"; return }
        guard currentCaptureSessionID == sessionID else { return }
        agentTypedRunID = nil // a capture alone is not a request to change tasks
        image = NSImage(cgImage: cgImage, size: .zero)
        if CaptureClipboard.automaticallyCopyCapture, let image { CaptureClipboard.copy(image) }
        isCapturing = false
        workspaceSelection = .capture
        presentTask(compact: true); showNotchLauncher()
        status = nil; saveMessage = nil
        currentAgentPrompt = CalendarAgent.screenshotPrompt
        screenRecognition = ScreenTextRecognition(lines: [])
        let recognitionTask = Task { try await ScreenTextRecognizer.recognizeLayout(in: cgImage) }
        ocrTask = recognitionTask
        // History exists before any tool can write. OCR is intentionally not included in the first model request.
        do {
            guard let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { throw ResponsesCalendarAgentClient.ClientError.imageEncoding }
            if isAppendingCapture, let id = currentMemoryRecordID {
                guard let record = try memoryStore.appendScreenshot(for: id, imageData: png, recognizedText: "", proposals: []) else {
                    throw CalendarToolArgumentError("The original capture no longer exists.")
                }
                currentAgentSourceID = record.additionalScreenshots?.last?.id
                calendarActions.replace(with: record.calendarProposals)
            } else {
                let record = try memoryStore.recordCapture(imageData: png, proposals: [], analysisProvider: canUseCalendarAgent ? "Calendar agent" : "On-device analysis + Vision OCR")
                currentMemoryRecordID = record.id
                currentAgentSourceID = nil
                calendarActions.replace(with: [])
            }
            refreshMemory()
        } catch {
            status = "Couldn’t save capture history: \(error.localizedDescription)"
            isRecognizing = false; isAppendingCapture = false; resumeShortcutAfterSelection()
            return
        }
        isAppendingCapture = false; previousCaptureImage = nil
        let recordID = currentMemoryRecordID
        ocrObserverTask = Task { [weak self] in
            let recognition = (try? await recognitionTask.value) ?? ScreenTextRecognition(lines: [])
            guard let self, self.currentCaptureSessionID == sessionID, !Task.isCancelled else { return }
            self.screenRecognition = recognition
            self.recognizedText = recognition.text
            self.lastOCRStatus = "Vision recognized \(recognition.text.count) characters."
            if let recordID {
                self.persistScreenRecognition(recognition, recordID: recordID)
            }
        }
        if canUseCalendarAgent {
            isRecognizing = false
            resumeShortcutAfterSelection()
            await runAgentSession(prompt: currentAgentPrompt, image: cgImage, sessionID: sessionID)
        } else {
            isRecognizing = true
            let recognition = (try? await recognitionTask.value) ?? ScreenTextRecognition(lines: [])
            guard currentCaptureSessionID == sessionID, !Task.isCancelled else { return }
            screenRecognition = recognition; recognizedText = recognition.text
            await showLocalFallback(recognition.text, sessionID: sessionID, error: nil)
        }
    }

    func persistScreenRecognition(_ recognition: ScreenTextRecognition, recordID: UUID) {
        do {
            guard let current = memoryStore.listRecords().first(where: { $0.id == recordID }) else { return }
            _ = try memoryStore.updateAgentContext(for: recordID, transcript: current.agentTranscript ?? [], recognizedText: currentAgentSourceID == nil ? recognition.text : nil)
            if let sourceID = currentAgentSourceID { _ = try memoryStore.updateScreenshotText(for: recordID, sourceID: sourceID, text: recognition.text) }
            refreshMemory()
        } catch { status = "Couldn’t save recognized text: \(error.localizedDescription)" }
    }

    func startAgentCommand(prompt explicitPrompt: String? = nil, expectedSessionID: UUID? = nil, isTypedRequest: Bool = true) async {
        guard !voiceSession.active else { agentError = "Voice mode is on — stop it first"; return }
        guard !softwareUpdates.installing else { return }
        guard account.canUseWorkspace else { openPanel(); return }
        guard expectedSessionID == nil || currentCaptureSessionID == expectedSessionID else { return }
        let prompt = (explicitPrompt ?? agentCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSaving, !isCapturing else { return }
        stopAgent()
        voicePreparedRunID = nil
        await Task.yield()
        guard expectedSessionID == nil || currentCaptureSessionID == expectedSessionID else { return }
        analysisTask?.cancel()
        agentCommand = ""
        status = nil; agentError = nil; agentRetryPrompt = nil; agentSummary = nil; agentTaskOutcome = nil
        agentRetryWasTypedRequest = false
        currentAgentPrompt = String(prompt.prefix(8000))
        let sessionID = UUID()
        agentTypedRunID = isTypedRequest ? sessionID : nil
        bindSelectedEventContext(runID: sessionID)
        currentCaptureSessionID = sessionID
        if currentMemoryRecordID == nil {
            do { currentMemoryRecordID = try memoryStore.recordCommand(prompt).id; refreshMemory() }
            catch { status = "Couldn’t save conversation history: \(error.localizedDescription)"; return }
        }
        workspaceSelection = .chat
        presentTask(compact: true)
        var cgImage: CGImage?
        if let image { var rect = CGRect(origin: .zero, size: image.size); cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) }
        if let cgImage { ocrTask = Task { try await ScreenTextRecognizer.recognizeLayout(in: cgImage) } }
        if canUseCalendarAgent {
            await runAgentSession(prompt: currentAgentPrompt, image: cgImage, sessionID: sessionID)
        } else {
            agentStatus = "Connect ChatGPT or add an API key and enable OpenAI analysis to use calendar tools."
            agentError = agentStatus
            agentMessages.append(.init(role: "user", content: prompt))
            if prompt.range(of: #"(?i)\b(delete|remove|move|update|change|search|find)\b"#, options: .regularExpression) == nil {
                await showLocalFallback(prompt, sessionID: sessionID, error: nil)
            }
        }
    }

    func runAgentSession(prompt: String, image: CGImage?, sessionID: UUID) async {
        guard !voiceSession.active else { agentError = "Voice mode is on — stop it first"; return }
        configureCalendarAgent()
        guard let agent = calendarAgent, let executor = agentToolExecutor, let recordID = currentMemoryRecordID else { return }
        activeAgentRunID = sessionID
        agentError = nil; agentRetryPrompt = nil; agentStreamingText = ""
        let record = memoryStore.listRecords().first(where: { $0.id == recordID })
        agentTranscriptPrefix = record?.agentTranscript ?? []
        if agentTranscriptPrefix.count == 1, agentTranscriptPrefix.first?.role == "user", agentTranscriptPrefix.first?.content == prompt, record?.calendarProposals.isEmpty == true {
            agentTranscriptPrefix = []
        }
        let prefix = agentTranscriptPrefix
        let memory = memoryStore.agentMemory(excluding: recordID) + prefix
        agent.onTranscriptChanged = { [weak self] turns in
            guard let self, self.activeAgentRunID == sessionID else { return }
            self.agentMessages = prefix + turns
            do {
                guard try self.memoryStore.updateAgentContext(for: recordID, transcript: prefix + turns) != nil else {
                    throw CalendarToolArgumentError("Conversation history disappeared.")
                }
                self.refreshMemory()
            } catch { self.status = "Couldn’t save agent memory: \(error.localizedDescription)" }
        }
        executor.activate(sessionID: sessionID)
        executor.memorySuggestionsBlocked = prefix.contains { $0.sharedCalendarContext == true }
        agentStatus = image == nil ? "Reading your command" : "Reading the screenshot"
        if destinations.isEmpty { await loadCalendars() }
        guard currentCaptureSessionID == sessionID, !Task.isCancelled else { return }
        do {
            let imageURL = try image.map(ResponsesCalendarAgentClient.imageDataURL)
            analyzedWithOpenAI = agentClient == nil
            lastAnalysisProvider = agentClient == nil ? "Calendar agent + Vision OCR" : "Offline calendar agent demo"
            try await agent.start(userMessage: prompt, imageDataURL: imageURL, memory: memory, personalMemoryContext: personalMemoryContext(for: prompt), sessionID: sessionID)
            guard currentCaptureSessionID == sessionID else { return }
            lastCaptureSummary = "\(calendarActions.addedCount) added · \(calendarActions.updatedCount) changed · \(calendarActions.deletedCount) removed · \(calendarActions.movedCount) moved"
        } catch is CancellationError { }
        catch {
            guard currentCaptureSessionID == sessionID, !Task.isCancelled else { return }
            agentError = error.localizedDescription
            agentRetryPrompt = prompt
            agentRetryWasTypedRequest = agentTypedRunID == sessionID
            agentStreamingText = ""
            agentMessages.append(.init(role: "error", content: error.localizedDescription))
            _ = try? memoryStore.updateAgentContext(for: recordID, transcript: agentMessages)
            let recognition = (try? await ocrTask?.value) ?? screenRecognition
            guard currentCaptureSessionID == sessionID, !Task.isCancelled else { return }
            screenRecognition = recognition
            recognizedText = recognition.text
            if agent.transcript.contains(where: { $0.role == "tool" && ["create_events", "update_event", "delete_event", "move_events"].contains($0.toolName ?? "") }) || (image == nil && prompt.range(of: #"(?i)\b(delete|remove|move|update|change|search|find)\b"#, options: .regularExpression) != nil) {
                status = "The agent could not continue: \(error.localizedDescription). Existing events remain unchanged unless an earlier write was approved."
                agentStatus = "Calendar tools unavailable"
            } else {
                await showLocalFallback(image == nil ? prompt : recognition.text, sessionID: sessionID, error: error.localizedDescription)
            }
        }
        if currentCaptureSessionID == sessionID { isRecognizing = false; analysisTask = nil }
    }

    func showLocalFallback(_ text: String, sessionID: UUID, error: String?) async {
        let drafts = await EventDraftExtractionService.extract(text)
        guard currentCaptureSessionID == sessionID, !Task.isCancelled else { return }
        analyzedWithOpenAI = false
        lastAnalysisProvider = "On-device fallback + Vision OCR"
        var items = calendarActions.proposals
        for var draft in drafts {
            draft.sourceRegion = screenRecognition.region(for: draft.sourceText)
            if items.contains(where: { CalendarDraftValidation.sameEvent($0.draft, draft) }) { continue }
            var item = CalendarActionProposal(draft: draft); item.sourceCaptureID = currentAgentSourceID
            items.append(item)
        }
        calendarActions.replace(with: items)
        if let id = currentMemoryRecordID {
            do { _ = try memoryStore.updateProposals(for: id, proposals: items); refreshMemory() }
            catch { status = "Couldn’t save local proposals: \(error.localizedDescription)" }
        }
        status = [error.map { "Agent unavailable; used on-device extraction. \($0)" }, "Review detected items against the source; unclear table rows may need manual entry."].compactMap { $0 }.joined(separator: " ")
        agentStatus = error == nil ? nil : "Using on-device fallback"
        isRecognizing = false
        analysisTask = nil
        resumeShortcutAfterSelection()
    }

    func retryAgentCommand() async {
        guard let prompt = agentRetryPrompt, !agentIsRunning else { return }
        let wasTyped = agentRetryWasTypedRequest
        await startAgentCommand(prompt: prompt, isTypedRequest: wasTyped)
    }

    func stopAgent() {
        voiceSession.stop()
        // Resume any awaited task review exactly once and invalidate its buttons before cancelling the run.
        cancelAgentTaskReview(reason: "Stopped.")
        calendarAgent?.cancel()
        agentIsRunning = false
        if calendarActions.isExecuting { calendarActions.requestStop() }
    }
    func answerAgentQuestion(_ answer: String) { agentToolExecutor?.answerQuestion(answer) }
    func cancelAgentQuestion() { agentToolExecutor?.answerQuestion(nil) }
    func skipAgentApproval() {
        let voiceReview = voicePreparedRunID != nil && voicePreparedRunID == activeAgentRunID
        agentToolExecutor?.skipApproval()
        if voiceReview { calendarActions.replace(with: calendarActions.proposals.filter(\.isFinished)) }
    }
}

extension CalshotModel {
    var directCalendarAccounts: [CalendarAccountConnection.Account] { CalendarAccountConnection.accounts() }
    func connectCalendarAccount(_ provider: CalendarAccountConnection.Provider, clientID: String) {
        guard !calendarAccountIsConnecting else { return }
        calendarAccountError = false; connectingCalendarProvider = provider
        calendarAccountIsConnecting = true; calendarAccountMessage = "Waiting for \(provider.title) sign-in and calendar consent…"
        calendarConnectionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.calendarAccountIsConnecting = false; self.connectingCalendarProvider = nil; self.calendarConnectionTask = nil }
            do {
                let account = try await CalendarAccountConnection.shared.connect(provider: provider, clientID: clientID)
                self.calendarAccountMessage = "Connected \(account.email)."
                await self.loadCalendars()
            } catch { self.calendarAccountError = !(error is CancellationError); self.calendarAccountMessage = error is CancellationError ? "Connection cancelled." : error.localizedDescription }
        }
    }
    func cancelCalendarConnection() { calendarConnectionTask?.cancel() }
    func disconnectCalendarAccount(_ id: UUID) async {
        do {
            try await CalendarAccountConnection.shared.disconnect(id)
            calendarAccountError = false
            calendarAccountMessage = "Disconnected from Calshot. Provider access can also be revoked in your account's security settings."
            await loadCalendars()
        } catch { calendarAccountError = true; calendarAccountMessage = error.localizedDescription }
    }
    func reuseSystemCalendar(remoteID: String, systemID: String) async {
        guard readableCalendars.contains(where: { $0.id == remoteID && ($0.id.hasPrefix("remote:") || $0.id.hasPrefix("icloud:")) }),
              readableCalendars.contains(where: { $0.id == systemID && !$0.id.hasPrefix("remote:") && !$0.id.hasPrefix("icloud:") && !$0.id.hasPrefix("unavailable:") }) else { return }
        var aliases = UserDefaults.standard.dictionary(forKey: "calendarTransportAliases") as? [String: String] ?? [:]
        aliases[remoteID] = systemID
        if selectedCalendarID == remoteID { selectedCalendarID = systemID }
        UserDefaults.standard.set(aliases, forKey: "calendarTransportAliases")
        calendarAccountMessage = "Using the existing macOS calendar instead of a second connection to the same calendar."
        await loadCalendars()
    }
}

extension CalshotModel {
    func connectICloudCalendar(email: String, appPassword: String) {
        guard !calendarAccountIsConnecting else { return }
        calendarAccountError = false; connectingCalendarProvider = .icloud
        calendarAccountIsConnecting = true; calendarAccountMessage = "Checking iCloud calendar access…"
        calendarConnectionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.calendarAccountIsConnecting = false; self.connectingCalendarProvider = nil; self.calendarConnectionTask = nil }
            do {
                let account = try await CalendarAccountConnection.shared.connectICloud(email: email, appPassword: appPassword)
                self.calendarAccountMessage = "Connected \(account.email)."
                await self.loadCalendars()
            } catch { self.calendarAccountError = !(error is CancellationError); self.calendarAccountMessage = error is CancellationError ? "Connection cancelled." : error.localizedDescription }
        }
    }
}

@MainActor
extension CalshotModel {
    /// Presentation only: no ownership, provider credentials or source identity is sent to the model.
    static func agentTaskJSON(_ task: CalshotTask) -> JSONValue {
        .object(["id": .string(task.id.uuidString), "version": .string(task.version.uuidString),
            "title": .string(task.title), "dueDate": task.dueDate.map(JSONValue.string) ?? .null,
            "dueTime": task.dueTime.map(JSONValue.string) ?? .null, "timeZone": .string(task.timeZone),
            "notes": .string(task.notes), "completed": .bool(task.completed), "archived": .bool(task.deleted),
            "calendarIntent": .string(task.resolvedCalendarIntent.rawValue),
            "calendarName": task.calendarName.map(JSONValue.string) ?? .null,
            "hasSourceLink": .bool(task.sourceLink != nil), "hasPublishedDeadline": .bool(task.receipt != nil)])
    }

    func validatedAgentSelectedContext(runID: UUID, reference: UUID? = nil) throws -> CalshotSelectedEventContext {
        _ = try taskContext(origin: .agent(runID: runID))
        guard let context = selectedEventContext, reference == nil || context.token == reference,
              context.runID == runID, context.captureID == currentCaptureSessionID,
              context.recordID == currentMemoryRecordID, context.ownerID == account.userID,
              context.storeURL == taskStore.url else {
            throw CalendarToolArgumentError("The selected event context is no longer current. Select the event again.")
        }
        return context
    }

    func selectedAgentTaskContext(runID: UUID) throws -> JSONValue {
        let context = try validatedAgentSelectedContext(runID: runID)
        let event = context.snapshot
        return .object(["contextReference": .string(context.token.uuidString), "title": .string(event.title),
            "start": .string(ISO8601DateFormatter().string(from: event.start)),
            "end": .string(ISO8601DateFormatter().string(from: event.end)), "isAllDay": .bool(event.isAllDay),
            "timeZone": event.timeZone.map(JSONValue.string) ?? .null, "calendarName": .string(event.calendarName)])
    }

    /// Reusable pure preflight. The result is review data, never an authorization or success receipt.
    /// The authorization hook must repeat this after approval and call the shared domain with the
    /// original operation IDs. Provider publication requires its own separately authorized action.
    func prepareAgentTaskChange(_ request: AgentPreparedTaskMutation, runID: UUID) async throws -> JSONValue {
        _ = try taskContext(origin: .agent(runID: runID))
        switch request.change {
        case .linkSelectedEvent(let reference):
            let context = try validatedAgentSelectedContext(runID: runID, reference: reference)
            guard try await freshSelectedSourceFingerprint(context) == context.fingerprint else {
                throw CalendarToolArgumentError("The source event changed or is unavailable. Select it again.")
            }
            _ = try validatedAgentSelectedContext(runID: runID, reference: reference)
            return .object(["status": .string("prepared"), "proposalID": .string(request.id.uuidString),
                "operation": .string("linkExistingEvent"), "event": try selectedAgentTaskContext(runID: runID),
                "calendarWrites": .number(0)])
        case .patches(let patches):
            guard !patches.isEmpty, patches.count <= 100, Set(patches.map(\.taskID)).count == patches.count else {
                throw CalendarToolArgumentError("Provide 1–100 unique task changes.")
            }
            let rows = try patches.map { patch -> JSONValue in
                guard let task = taskDocument.items.first(where: { $0.id == patch.taskID }), task.version == patch.expectedVersion else {
                    throw CalendarToolArgumentError("The task changed. Read its current version before editing.")
                }
                try CalendarToolDraftMapper.keys(patch.fields, allowed: ["title", "dueDate", "dueTime", "timeZone", "notes", "completed", "archived"])
                guard !patch.fields.isEmpty else { throw CalendarToolArgumentError("Provide at least one task change.") }
                return .object(["operationID": .string(patch.operationID.uuidString), "before": Self.agentTaskJSON(task), "patch": .object(patch.fields)])
            }
            return .object(["status": .string("prepared"), "proposalID": .string(request.id.uuidString),
                "operation": .string("patchTasks"), "tasks": .array(rows), "calendarPublication": .string("separateAuthorizationRequired")])
        }
    }
}

// MARK: - Task-only review and saved task permissions
// Device-local and native-only. Calendar approval, calendar grants and provider writes are separate.

enum AgentTaskReviewDecision { case approved, declined, cancelled }

/// One short, task-only review shown inside the current conversation or notch.
struct AgentTaskReview: Identifiable {
    enum Phase: String { case waiting, applying }
    struct Change { let label: String; let before: String?; let after: String? }
    struct Row: Identifiable { let id: UUID; let title: String; let changes: [Change]; let note: String? }
    let id: UUID
    let token = UUID().uuidString
    let runID: UUID
    let ownerID: UUID?
    let storeURL: URL
    let captureID: UUID?
    let digest: String
    let kind: String
    let heading: String
    let rows: [Row]
    let reason: String
    var phase: Phase = .waiting
    var error: String?
}

/// Concise result shown next to the conversation. Built only from native receipts.
struct AgentTaskOutcome: Identifiable {
    struct Row: Identifiable { let id: UUID; let title: String; let status: String; let message: String? }
    let id = UUID()
    let runID: UUID
    let status: String
    let headline: String
    let rows: [Row]
    let viaSavedPermission: Bool
}

struct AgentTaskPlan {
    enum Kind: String { case link, edit, complete, archive }
    enum Detail { case link(CalshotSelectedEventContext), patches([AgentPreparedTaskMutation.Patch]) }
    let kind: Kind
    let detail: Detail
    let operations: [AgentPermissionOperation]
    let titles: [String]
    let reviewRows: [AgentTaskReview.Row]
    let heading: String
    let digest: String
}

struct AgentTaskRowResult {
    let operationID: UUID
    var taskID: UUID?
    let title: String
    var status: String          // saved | alreadyLinked | failed | cancelled
    var message: String?
    var receipt: CalshotTaskOperationReceipt?
}

@MainActor
extension CalshotModel {
    /// Fields each saved family may touch. Subsets of the kernel allowlist; background is never granted here.
    static let agentTaskGrantFields: [AgentPermissionAction: Set<String>] = [
        .taskCreate: ["title", "notes", "dueDate", "dueTime", "timeZone", "calendarIntent"],
        .taskLink: ["sourceLink", "title", "dueDate", "dueTime", "timeZone"],
        .taskEdit: ["title", "notes", "dueDate", "dueTime", "timeZone"],
        .taskComplete: ["completed"],
        .taskArchive: ["deleted"]]
    static let agentTaskFamilies: [(id: String, action: AgentPermissionAction, label: String, detail: String)] = [
        ("create", .taskCreate, "Add tasks", "Save tasks you ask for when they have no new calendar deadline."),
        ("link", .taskLink, "Add calendar events to Tasks", "Link an event you selected. The event itself is never changed."),
        ("edit", .taskEdit, "Edit tasks", "Change a task’s title, date, time or notes."),
        ("complete", .taskComplete, "Complete or reopen tasks", "Mark tasks done, or open them again."),
        ("archive", .taskArchive, "Archive or restore tasks", "Move tasks out of your list, or bring them back.")]
    static let agentSupportedTaskActions: Set<AgentPermissionAction> = [.taskCreate, .taskLink, .taskEdit, .taskComplete, .taskArchive]

    var agentPermissionOwnerID: String { account.userID?.uuidString ?? "local" }

    private func agentPermissionDirectory() -> URL {
        let base = agentPermissionBaseURL ?? memoryStore.locationURL.appendingPathComponent("AgentPermissions", isDirectory: true)
        return base.appendingPathComponent(agentPermissionOwnerID, isDirectory: true)
            .appendingPathComponent(Self.syncDeviceID, isDirectory: true)
    }

    static func agentPermissionMessage(_ error: Error) -> String {
        switch error as? AgentPermissionError {
        case .storeAlreadyOpen: return "Task permissions are in use by another Calshot process. Quit it, then reopen Calshot."
        case .corruptStore: return "Saved task permissions couldn’t be read safely. The file was kept and task changes by Calshot are paused."
        case .wrongOwnerOrDevice: return "Saved task permissions belong to another account or Mac. Task changes by Calshot are paused."
        case .stalePolicy: return "Permissions changed. Check the latest settings and save again."
        case .closed: return "Task permissions closed because the account changed. Try again."
        case .invalidPolicy: return "Those permission settings are not valid."
        default: return error.localizedDescription
        }
    }

    // MARK: Store lifecycle

    /// One store per canonical account + device. Opening never resets, repairs or deletes saved permissions.
    @discardableResult
    func openAgentPermissionStore() async throws -> AgentPermissionStore {
        guard account.canUseWorkspace else { throw CalendarToolArgumentError("Sign in to Calshot to manage task permissions.") }
        let directory = agentPermissionDirectory()
        let key = agentPermissionOwnerID + "|" + directory.path
        if let store = agentPermissionStore, agentPermissionStoreKey == key {
            if agentPermissionNeedsReconcile { await reconcileAgentPermissionLedger(store) }
            return store
        }
        if let opening = agentPermissionOpening, opening.key == key { return try await opening.task.value }
        if let old = agentPermissionStore {
            agentPermissionStore = nil; agentPermissionStoreKey = nil; agentPermissionPolicy = nil
            let previous = agentPermissionClosing
            agentPermissionClosing = Task { await previous?.value; await old.close() }
        }
        agentPermissionOpening?.task.cancel()
        let owner = agentPermissionOwnerID, device = Self.syncDeviceID, closing = agentPermissionClosing, generation = agentPermissionGeneration
        let task = Task { @MainActor [weak self] () -> AgentPermissionStore in
            await closing?.value
            // Check before taking the file lock so a torn-down attempt can never hold it while a new one starts.
            guard let current = self, current.agentPermissionOpening?.key == key, current.agentPermissionGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            let store = try AgentPermissionStore(directory: directory, ownerID: owner, deviceID: device)
            guard let self, self.agentPermissionOpening?.key == key, self.agentPermissionGeneration == generation, !Task.isCancelled else {
                await store.close(); throw CancellationError()
            }
            self.agentPermissionStore = store; self.agentPermissionStoreKey = key
            self.agentPermissionOpening = nil
            self.agentPermissionPolicy = try await store.snapshot()
            self.agentPermissionError = nil
            await self.reconcileAgentPermissionLedger(store)
            return store
        }
        agentPermissionOpening = (key, task)
        do { return try await task.value }
        catch {
            if agentPermissionOpening?.key == key { agentPermissionOpening = nil }
            if error is CancellationError { throw error }
            let message = Self.agentPermissionMessage(error)
            agentPermissionError = message
            throw CalendarToolArgumentError(message)
        }
    }

    /// Called after a successful task load: settles ledger rows whose proof needed the task file.
    func retryAgentPermissionReconcile() {
        guard agentPermissionNeedsReconcile, let store = agentPermissionStore else { return }
        let generation = agentPermissionGeneration
        Task { if self.agentPermissionGeneration == generation { await self.reconcileAgentPermissionLedger(store) } }
    }

    /// Account change or sign-out: resume any awaited review as cancelled, then close the old store.
    func teardownAgentPermissions(reason: String) {
        voiceSession.stop()
        cancelAgentTaskReview(reason: reason)
        agentPermissionOpening?.task.cancel(); agentPermissionOpening = nil
        if let old = agentPermissionStore {
            let previous = agentPermissionClosing
            agentPermissionClosing = Task { await previous?.value; await old.close() }
        }
        agentPermissionStore = nil; agentPermissionStoreKey = nil; agentPermissionPolicy = nil
        agentPermissionError = nil; agentPermissionNotice = nil; agentPermissionBusy = false
        agentPermissionGeneration = UUID(); agentPermissionLiveOperations = []; agentPermissionNeedsReconcile = false
        agentTaskOutcome = nil
    }

    /// Restored ledger rows are evidence, never authority. Local task storage is the proof of what happened.
    /// Skips operations this process still owns.
    func reconcileAgentPermissionLedger(_ store: AgentPermissionStore) async {
        guard taskDataReady else { agentPermissionNeedsReconcile = true; return }
        guard let records = try? await store.operationRecords() else { agentPermissionNeedsReconcile = true; return }
        agentPermissionNeedsReconcile = false
        let receipts = Set((taskDocument.operations ?? []).map(\.operationID))
        for record in records where ["reserved", "dispatched", "unknown"].contains(record.status) {
            let operation = record.envelope.operation
            guard !agentPermissionLiveOperations.contains(operation.operationID) else { continue }
            if record.status == "reserved" { try? await store.settle(record.envelope, outcome: .failedWithoutEffect); continue }
            let outcome: AgentPermissionSettlement?
            switch operation.action {
            case .taskCreate:
                let present = operation.resourceIDs.filter { id in taskDocument.items.contains { $0.id.uuidString == id } }
                outcome = present.count == operation.resourceIDs.count ? .succeeded : present.isEmpty ? .failedWithoutEffect : nil
            case .taskLink:
                if receipts.contains(operation.operationID) { outcome = .succeeded }
                else {
                    let linked = operation.resourceIDs.contains { resource in
                        taskDocument.items.contains { task in task.sourceLink.map { "source:" + $0.calendarID + "|" + $0.eventID == resource } ?? false }
                    }
                    outcome = linked ? nil : .failedWithoutEffect
                }
            case .taskEdit, .taskComplete, .taskArchive:
                if receipts.contains(operation.operationID) { outcome = .succeeded }
                else {
                    let unchanged = operation.expectedVersions.allSatisfy { expected in
                        taskDocument.items.contains { $0.id.uuidString == expected.key && $0.version.uuidString == expected.value }
                    }
                    outcome = unchanged ? .failedWithoutEffect : nil
                }
            default: outcome = nil
            }
            if let outcome { try? await store.settle(record.envelope, outcome: outcome) }
        }
    }

    // MARK: Review state

    private func resolveAgentTaskReview(_ decision: AgentTaskReviewDecision) {
        guard let continuation = agentTaskReviewContinuation else { return }
        agentTaskReviewContinuation = nil
        continuation.resume(returning: decision)
    }

    /// Stop, a new task, sign-out and account change all land here. Resumes the awaited hook once.
    func cancelAgentTaskReview(runID: UUID? = nil, reason: String = "Stopped.") {
        guard let review = agentTaskReview else { resolveAgentTaskReview(.cancelled); return }
        guard runID == nil || review.runID == runID else { return }
        if review.phase == .waiting { agentTaskReview = nil }
        resolveAgentTaskReview(.cancelled)
    }

    private func awaitAgentTaskReview(_ review: AgentTaskReview) async -> AgentTaskReviewDecision {
        await withCheckedContinuation { continuation in
            guard agentTaskReview == nil, agentTaskReviewContinuation == nil, (agentIsRunning || voiceRunID == review.runID || voicePreparedRunID == review.runID),
                  activeAgentRunID == review.runID, !Task.isCancelled else { continuation.resume(returning: .cancelled); return }
            agentTaskReviewContinuation = continuation
            voiceSession.review(true)
            agentTaskReview = review
            agentStatus = "Review the task change"
        }
    }

    func validateAgentTaskReview(_ review: AgentTaskReview) throws {
        do { _ = try taskContext(origin: .agent(runID: review.runID)) }
        catch { throw CalendarToolArgumentError("This task review is no longer current. Ask Calshot again.") }
        guard review.ownerID == account.userID, review.storeURL == taskStore.url,
              review.captureID == currentCaptureSessionID, activeAgentRunID == review.runID else {
            throw CalendarToolArgumentError("This task review is no longer current. Ask Calshot again.")
        }
    }

    /// Bridge entry. Rejects stale, wrong-token or repeated clicks without changing anything.
    func approveAgentTaskReview(id: UUID, token: String, digest: String) throws {
        guard let review = agentTaskReview, review.id == id, review.token == token, review.digest == digest,
              review.phase == .waiting, agentTaskReviewContinuation != nil else {
            throw CalendarToolArgumentError("This task review is no longer current.")
        }
        do { try validateAgentTaskReview(review) }
        catch { cancelAgentTaskReview(runID: review.runID); throw error }
        var next = review; next.phase = .applying; next.error = nil
        agentTaskReview = next
        resolveAgentTaskReview(.approved)
    }

    func declineAgentTaskReview(id: UUID, token: String) throws {
        guard let review = agentTaskReview, review.id == id, review.token == token,
              review.phase == .waiting, agentTaskReviewContinuation != nil else {
            throw CalendarToolArgumentError("This task review is no longer current.")
        }
        agentTaskReview = nil
        resolveAgentTaskReview(.declined)
    }

    // MARK: Plans (immutable, native-built operations)

    static func agentEffectDigest(_ value: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return AgentPermissionOperation.hash((try? encoder.encode(value)) ?? Data())
    }

    func freshSelectedSourceFingerprint(_ context: CalshotSelectedEventContext) async throws -> String? {
        try await freshSourceFingerprint(snapshot: context.snapshot, destinationID: context.destinationID)
    }

    func freshSourceFingerprint(snapshot: CalendarEventSnapshot, destinationID: String) async throws -> String? {
        guard readableCalendars.contains(where: { $0.id == destinationID && !$0.id.hasPrefix("unavailable:") }),
              let fresh = try await calendarService.event(matching: snapshot, in: .resolve(identifier: destinationID)) else { return nil }
        return try Self.taskSourceFingerprint(fresh)
    }

    private static func agentSourceResource(_ context: CalshotSelectedEventContext) -> String {
        "source:" + context.destinationID + "|" + context.snapshot.eventIdentifier
    }

    private static func display(_ value: JSONValue?, empty: String = "None") -> String {
        guard let value, value != .null else { return empty }
        if let text = value.stringValue { return text.isEmpty ? empty : String(text.prefix(160)) }
        if let flag = value.boolValue { return flag ? "Yes" : "No" }
        return empty
    }

    private static func eventWhen(_ event: CalendarEventSnapshot) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale.current
        formatter.timeZone = event.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        if event.isAllDay {
            formatter.dateStyle = .medium; formatter.timeStyle = .none
            let last = event.end.addingTimeInterval(-1)
            let start = formatter.string(from: event.start), end = formatter.string(from: max(last, event.start))
            return (start == end ? start : start + " – " + end) + " · all day"
        }
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: event.start) + " – " + formatter.string(from: event.end)
    }

    /// Builds the exact, immutable operations for a prepared request. Called again after review; equal output
    /// is what lets an exact review submission match the shown effect.
    func agentTaskPlan(_ request: AgentPreparedTaskMutation, runID: UUID) throws -> AgentTaskPlan {
        let owner = agentPermissionOwnerID, device = Self.syncDeviceID
        switch request.change {
        case .linkSelectedEvent(let reference):
            let context = try validatedAgentSelectedContext(runID: runID, reference: reference)
            let resource = Self.agentSourceResource(context)
            let effect = JSONValue.object(["kind": .string("link"), "calendarID": .string(context.destinationID),
                "eventID": .string(context.snapshot.eventIdentifier), "fingerprint": .string(context.fingerprint)])
            let operation = AgentPermissionOperation(operationID: request.id, runID: runID, ownerID: owner, deviceID: device,
                action: .taskLink, resourceIDs: [resource], expectedVersions: [resource: context.fingerprint], calendarIDs: [],
                fields: ["sourceLink", "title", "dueDate", "dueTime", "timeZone"], effectDigest: Self.agentEffectDigest(effect),
                hasGuestEffects: false, affectsSeries: false, hasSharingEffects: false)
            let event = context.snapshot
            let row = AgentTaskReview.Row(id: request.id, title: event.title, changes: [
                .init(label: "New task", before: nil, after: event.title),
                .init(label: "Event", before: nil, after: Self.eventWhen(event)),
                .init(label: "Linked to", before: nil, after: event.calendarName)],
                note: "Your calendar isn’t changed.")
            return AgentTaskPlan(kind: .link, detail: .link(context), operations: [operation], titles: [event.title],
                reviewRows: [row], heading: "Add this event to Tasks", digest: Self.agentEffectDigest(effect))
        case .patches(let patches):
            guard !patches.isEmpty, patches.count <= 100 else { throw CalendarToolArgumentError("Provide 1–100 task changes.") }
            var kind: AgentTaskPlan.Kind?
            var operations: [AgentPermissionOperation] = [], titles: [String] = [], rows: [AgentTaskReview.Row] = []
            for patch in patches {
                guard let task = taskDocument.items.first(where: { $0.id == patch.taskID }), task.version == patch.expectedVersion else {
                    throw CalendarToolArgumentError("The task changed. Read its current version before editing.")
                }
                let keys = Set(patch.fields.keys)
                let rowKind: AgentTaskPlan.Kind, action: AgentPermissionAction, fields: Set<String>
                if keys == ["completed"] { rowKind = .complete; action = .taskComplete; fields = ["completed"] }
                else if keys == ["archived"] { rowKind = .archive; action = .taskArchive; fields = ["deleted"] }
                else if !keys.isEmpty, keys.isSubset(of: ["title", "dueDate", "dueTime", "timeZone", "notes"]) { rowKind = .edit; action = .taskEdit; fields = keys }
                else { throw CalendarToolArgumentError("Change one kind of task detail per request: details, completion or archive.") }
                guard kind == nil || kind == rowKind else { throw CalendarToolArgumentError("Change one kind of task detail per request.") }
                kind = rowKind
                let effect = JSONValue.object(["kind": .string(rowKind.rawValue), "taskID": .string(task.id.uuidString),
                    "expectedVersion": .string(task.version.uuidString), "patch": .object(patch.fields)])
                operations.append(AgentPermissionOperation(operationID: patch.operationID, runID: runID, ownerID: owner, deviceID: device,
                    action: action, resourceIDs: [task.id.uuidString], expectedVersions: [task.id.uuidString: task.version.uuidString],
                    calendarIDs: [], fields: fields, effectDigest: Self.agentEffectDigest(effect),
                    hasGuestEffects: false, affectsSeries: false, hasSharingEffects: false))
                titles.append(task.title)
                var changes: [AgentTaskReview.Change] = []
                let current: [String: String] = ["title": task.title, "dueDate": task.dueDate ?? "None", "dueTime": task.dueTime ?? "None",
                    "timeZone": task.timeZone, "notes": task.notes.isEmpty ? "None" : String(task.notes.prefix(160))]
                let labels = ["title": "Title", "dueDate": "Due date", "dueTime": "Due time", "timeZone": "Time zone", "notes": "Notes"]
                for key in ["title", "dueDate", "dueTime", "timeZone", "notes"] where patch.fields[key] != nil {
                    changes.append(.init(label: labels[key]!, before: current[key], after: Self.display(patch.fields[key])))
                }
                if let value = patch.fields["completed"]?.boolValue { changes.append(.init(label: "Status", before: task.completed ? "Complete" : "Open", after: value ? "Complete" : "Open")) }
                if let value = patch.fields["archived"]?.boolValue { changes.append(.init(label: "In your list", before: task.deleted ? "Archived" : "Active", after: value ? "Archived" : "Active")) }
                rows.append(.init(id: patch.operationID, title: task.title, changes: changes,
                    note: task.sourceLink != nil ? "Its linked calendar event isn’t changed." : (task.receipt != nil ? "Its published deadline isn’t changed here." : nil)))
            }
            let kindValue = kind!
            let heading: String
            let plural = patches.count == 1 ? "task" : "\(patches.count) tasks"
            switch kindValue {
            case .edit: heading = "Update " + plural
            case .complete: heading = (patches.first?.fields["completed"]?.boolValue == false ? "Reopen " : "Mark complete: ") + plural
            case .archive: heading = (patches.first?.fields["archived"]?.boolValue == false ? "Restore " : "Archive ") + plural
            case .link: heading = "Add to Tasks"
            }
            let digest = Self.agentEffectDigest(.array(operations.map { .string($0.effectDigest) }))
            return AgentTaskPlan(kind: kindValue, detail: .patches(patches), operations: operations, titles: titles,
                reviewRows: rows, heading: heading, digest: digest)
        }
    }

    /// Fresh native resources for every reserve/dispatch. Never reuse values read for an earlier decision.
    func agentTaskResources(_ plan: AgentTaskPlan?, runID: UUID) async -> AgentPermissionResources {
        var versions = Dictionary(uniqueKeysWithValues: taskDocument.items.map { ($0.id.uuidString, $0.version.uuidString) })
        if case .link(let context)? = plan?.detail, let fingerprint = try? await freshSelectedSourceFingerprint(context) {
            versions[Self.agentSourceResource(context)] = fingerprint
        }
        let current = (try? taskContext(origin: .agent(runID: runID))) != nil && activeAgentRunID == runID
        return AgentPermissionResources(ownerID: agentPermissionOwnerID, deviceID: Self.syncDeviceID, versions: versions,
            writableCalendarIDs: [], supportedActions: Self.agentSupportedTaskActions, cancelled: Task.isCancelled || !current)
    }

    // MARK: Authorization

    private func releaseAgentReservations(_ envelopes: [AgentPermissionEnvelope], store: AgentPermissionStore) async {
        for envelope in envelopes {
            try? await store.settle(envelope, outcome: .failedWithoutEffect)
            agentPermissionLiveOperations.remove(envelope.operation.operationID)
        }
    }

    private func recordAgentTaskOutcome(runID: UUID, status: String, headline: String, rows: [AgentTaskOutcome.Row], viaPermission: Bool) {
        guard activeAgentRunID == runID else { return }
        agentTaskOutcome = AgentTaskOutcome(runID: runID, status: status, headline: headline, rows: rows, viaSavedPermission: viaPermission)
    }

    private func agentTaskFailure(runID: UUID, status: String = "failed", message: String, rows: [AgentTaskRowResult] = [], titles: [String] = [], viaPermission: Bool = false) -> JSONValue {
        let outcomeRows = rows.isEmpty
            ? titles.prefix(12).map { AgentTaskOutcome.Row(id: UUID(), title: $0, status: status, message: message) }
            : rows.map { AgentTaskOutcome.Row(id: $0.operationID, title: $0.title, status: $0.status, message: $0.message) }
        recordAgentTaskOutcome(runID: runID, status: status, headline: status == "cancelled" ? "Task change cancelled" : "Calshot couldn’t change Tasks", rows: outcomeRows.isEmpty ? [.init(id: UUID(), title: message, status: status, message: nil)] : Array(outcomeRows), viaPermission: viaPermission)
        return .object(["status": .string(status), "saved": .bool(false), "error": .string(message), "calendarWrites": .number(0),
                        "rows": .array(rows.map(Self.agentRowJSON))])
    }

    static func agentRowJSON(_ row: AgentTaskRowResult) -> JSONValue {
        var fields: [String: JSONValue] = ["operationID": .string(row.operationID.uuidString), "outcome": .string(row.status), "title": .string(row.title)]
        if let id = row.taskID { fields["taskID"] = .string(id.uuidString) }
        if let receipt = row.receipt {
            fields["taskVersion"] = .string(receipt.taskVersion.uuidString)
            fields["savedAt"] = .string(ISO8601DateFormatter().string(from: receipt.savedAt))
        }
        if let message = row.message { fields["error"] = .string(message) }
        return .object(fields)
    }

    /// Executes one task request. A matching saved grant runs it immediately; otherwise exactly one task-only
    /// review opens here. Never changes calendar approval state and never writes to a calendar provider.
    func authorizeAgentTaskChange(_ request: AgentPreparedTaskMutation, runID: UUID, preflighted: Bool = false) async throws -> JSONValue {
        // The review stays visible (as "saving") until the exact receipts exist, then always clears.
        defer { if agentTaskReview?.id == request.id { agentTaskReview = nil }; voiceSession.review(false) }
        return try await performAgentTaskAuthorization(request, runID: runID, preflighted: preflighted)
    }

    private func performAgentTaskAuthorization(_ request: AgentPreparedTaskMutation, runID: UUID, preflighted: Bool) async throws -> JSONValue {
        let plan: AgentTaskPlan
        do {
            if !preflighted { _ = try await prepareAgentTaskChange(request, runID: runID) }
            plan = try agentTaskPlan(request, runID: runID)
        } catch is CancellationError { throw CancellationError() }
        catch { return agentTaskFailure(runID: runID, message: error.localizedDescription) }
        let store: AgentPermissionStore
        do { store = try await openAgentPermissionStore() }
        catch is CancellationError { throw CancellationError() }
        catch { return agentTaskFailure(runID: runID, status: "unavailable", message: error.localizedDescription, titles: plan.titles) }

        var envelopes: [AgentPermissionEnvelope] = []
        var reviewReason: String?
        var viaPermission = true
        // Saved grants cover only requests the user typed. A screenshot-started run always asks.
        if agentTypedRunID != runID { reviewReason = voiceRunID == runID ? "Voice requests always ask before changing your tasks." : "A screenshot started this request, so Calshot asks before changing your tasks." }
        do {
            for operation in plan.operations where reviewReason == nil {
                let resources = await agentTaskResources(plan, runID: runID)
                switch try await store.reserve(operation, context: .userRequested(), resources: resources) {
                case .allow(let envelope): envelopes.append(envelope); agentPermissionLiveOperations.insert(operation.operationID)
                case .requireReview(let reason): reviewReason = reason
                case .deny(let reason):
                    await releaseAgentReservations(envelopes, store: store)
                    return agentTaskFailure(runID: runID, status: reason == "The run was cancelled." ? "cancelled" : "denied", message: reason, titles: plan.titles)
                }
                if reviewReason != nil { break }
            }
            if let reason = reviewReason {
                await releaseAgentReservations(envelopes, store: store); envelopes = []; viaPermission = false
                let review = AgentTaskReview(id: request.id, runID: runID, ownerID: account.userID, storeURL: taskStore.url,
                    captureID: currentCaptureSessionID, digest: plan.digest, kind: plan.kind.rawValue, heading: plan.heading,
                    rows: plan.reviewRows, reason: reason)
                let decision = await awaitAgentTaskReview(review)
                switch decision {
                case .cancelled: return agentTaskFailure(runID: runID, status: "cancelled", message: "Stopped before anything changed.", titles: plan.titles)
                case .declined:
                    recordAgentTaskOutcome(runID: runID, status: "declined", headline: "Nothing changed", rows: [], viaPermission: false)
                    return .object(["status": .string("declined"), "saved": .bool(false), "calendarWrites": .number(0)])
                case .approved: break
                }
                // After review, repeat preflight and bind each operation to this exact shown effect. The explicit review is
                // operation-scoped authority, so it may exceed the saved-grant quotas; it never widens scope.
                _ = try await prepareAgentTaskChange(request, runID: runID)
                let confirmed = try agentTaskPlan(request, runID: runID)
                guard confirmed.digest == plan.digest, confirmed.operations == plan.operations else {
                    return agentTaskFailure(runID: runID, message: "The task changed while you were reviewing it. Nothing was saved.", titles: plan.titles)
                }
                for operation in plan.operations {
                    let resources = await agentTaskResources(plan, runID: runID)
                    switch try await store.reserve(operation, context: .reviewedTaskSubmission(operation), resources: resources) {
                    case .allow(let envelope): envelopes.append(envelope); agentPermissionLiveOperations.insert(operation.operationID)
                    case .requireReview(let reason), .deny(let reason):
                        await releaseAgentReservations(envelopes, store: store)
                        return agentTaskFailure(runID: runID, message: reason + " Nothing was saved.", titles: plan.titles)
                    }
                }
            }
        } catch is CancellationError {
            await releaseAgentReservations(envelopes, store: store); throw CancellationError()
        } catch {
            await releaseAgentReservations(envelopes, store: store)
            return agentTaskFailure(runID: runID, message: Self.agentPermissionMessage(error), titles: plan.titles)
        }
        let results = await executeAgentTaskPlan(plan, envelopes: envelopes, store: store, runID: runID)
        return finishAgentTaskResults(results, plan: plan, runID: runID, viaPermission: viaPermission)
    }

    private func executeAgentTaskPlan(_ plan: AgentTaskPlan, envelopes: [AgentPermissionEnvelope], store: AgentPermissionStore, runID: UUID) async -> [AgentTaskRowResult] {
        var results: [AgentTaskRowResult] = []
        for (index, envelope) in envelopes.enumerated() {
            let operation = envelope.operation, title = plan.titles[index]
            var row = AgentTaskRowResult(operationID: operation.operationID, taskID: nil, title: title, status: "failed")
            func fence(_ message: String, status: String = "failed") async {
                row.status = status; row.message = message
                await releaseAgentReservations([envelope], store: store)
            }
            // Stop, a new run, sign-out or revocation fences every row that has not dispatched.
            guard (try? taskContext(origin: .agent(runID: runID))) != nil, activeAgentRunID == runID, !Task.isCancelled else {
                await fence("Stopped before this change was saved.", status: "cancelled"); results.append(row); continue
            }
            do { try await store.beginDispatch(envelope, resources: await agentTaskResources(plan, runID: runID)) }
            catch {
                await fence(error is AgentPermissionError ? "Permissions or the task changed before this change was saved." : error.localizedDescription)
                results.append(row); continue
            }
            do {
                let receipt: CalshotTaskOperationReceipt
                switch plan.detail {
                case .patches(let patches):
                    // No suspension between the dispatch permit and this synchronous domain mutation.
                    let patch = patches[index]
                    receipt = try mutateTask(taskID: patch.taskID, expectedVersion: patch.expectedVersion, patch: patch.fields,
                        context: try taskContext(origin: .agent(runID: runID)), operationID: patch.operationID)
                case .link(let context):
                    receipt = try await linkExistingEvent(snapshot: context.snapshot, destinationID: context.destinationID,
                        expectedFingerprint: context.fingerprint, context: try taskContext(origin: .agent(runID: runID)), operationID: operation.operationID)
                }
                row.receipt = receipt; row.taskID = receipt.taskID; row.status = receipt.outcome == "saved" ? "saved" : receipt.outcome
                if let saved = taskDocument.items.first(where: { $0.id == receipt.taskID }) { row = AgentTaskRowResult(operationID: row.operationID, taskID: row.taskID, title: saved.title, status: row.status, message: nil, receipt: receipt) }
                try? await store.settle(envelope, outcome: .succeeded)
            } catch {
                switch await settleAfterFailedTaskWrite(envelope, store: store, operationID: operation.operationID) {
                case .applied(let persisted):
                    row.receipt = persisted; row.taskID = persisted.taskID; row.status = persisted.outcome == "saved" ? "saved" : persisted.outcome
                case .notApplied:
                    row.status = error is CancellationError ? "cancelled" : "failed"
                    row.message = error is CancellationError ? "Stopped before this change was saved." : error.localizedDescription
                case .unknown:
                    row.message = "Calshot couldn’t confirm whether this change was saved. Reload Tasks to check before trying again."
                }
            }
            agentPermissionLiveOperations.remove(operation.operationID)
            results.append(row)
        }
        return results
    }

    enum TaskWriteOutcome { case applied(CalshotTaskOperationReceipt), notApplied, unknown }

    /// After a dispatched task write fails: the local task file is the proof. A persisted receipt means it happened,
    /// a clean read without one means it did not. If the file cannot be read, the outcome is unknown: keep the
    /// reservation, stop all further task mutation and show a persistent recovery error until a clean reload,
    /// so nothing can overwrite or duplicate the unresolved state.
    func settleAfterFailedTaskWrite(_ envelope: AgentPermissionEnvelope, store: AgentPermissionStore, operationID: UUID) async -> TaskWriteOutcome {
        if let document = try? taskStore.load() {
            if let receipt = document.operations?.first(where: { $0.operationID == operationID }) {
                try? await store.settle(envelope, outcome: .succeeded); return .applied(receipt)
            }
            try? await store.settle(envelope, outcome: .failedWithoutEffect); return .notApplied
        }
        try? await store.settle(envelope, outcome: .unknown)
        taskDataReady = false; agentPermissionNeedsReconcile = true
        taskError = "Calshot couldn’t confirm whether the last task change was saved. Your task file was kept. Reload Tasks to check it before making more changes."
        return .unknown
    }

    private func finishAgentTaskResults(_ results: [AgentTaskRowResult], plan: AgentTaskPlan, runID: UUID, viaPermission: Bool) -> JSONValue {
        let saved = results.filter { ["saved", "alreadyLinked", "alreadyLinkedArchived"].contains($0.status) }
        let cancelled = results.filter { $0.status == "cancelled" }
        let status = saved.count == results.count ? "saved" : saved.isEmpty ? (cancelled.count == results.count ? "cancelled" : "failed") : "partial"
        let headline: String
        switch (plan.kind, status) {
        case (.link, "saved"): headline = results.first?.status == "saved" ? "Added to Tasks" : "Already in Tasks"
        case (_, "saved"): headline = results.count == 1 ? "Task updated" : "\(results.count) tasks updated"
        case (_, "partial"): headline = "\(saved.count) of \(results.count) saved"
        case (_, "cancelled"): headline = "Stopped before anything changed"
        default: headline = "Couldn’t save this change"
        }
        recordAgentTaskOutcome(runID: runID, status: status, headline: headline,
            rows: results.prefix(12).map { .init(id: $0.operationID, title: $0.title, status: $0.status, message: $0.message) }, viaPermission: viaPermission)
        var payload: [String: JSONValue] = ["status": .string(status), "saved": .bool(status == "saved"),
            "authorization": .string(viaPermission ? "savedPermission" : "taskReview"), "calendarWrites": .number(0),
            "rows": .array(results.map(Self.agentRowJSON))]
        if results.count > 1 { payload["note"] = .string("Rows are applied one at a time; saved rows are kept and are not rolled back.") }
        if plan.kind != .link { payload["calendarPublication"] = .string("unchanged; a deadline change needs its own calendar review in Tasks") }
        return .object(payload)
    }

    // MARK: Task-only create under a saved grant

    /// Returns nil when the user must review (no matching grant, limit reached, or the store is unavailable).
    func commitAgentTaskOnlyImport(runID: UUID) async throws -> JSONValue? {
        guard agentTypedRunID == runID else { return nil }
        guard let batch = taskImport, !batch.items.isEmpty, batch.ownerID == account.userID, batch.storeURL == taskStore.url,
              batch.captureID == currentCaptureSessionID, batch.recordID == currentMemoryRecordID,
              batch.items.allSatisfy({ $0.resolvedCalendarIntent != .new || $0.dueDate == nil }) else { return nil }
        guard let store = try? await openAgentPermissionStore() else { return nil }
        var fields: Set<String> = ["title", "timeZone"]
        for task in batch.items {
            if !task.notes.isEmpty { fields.insert("notes") }
            if task.dueDate != nil { fields.insert("dueDate") }
            if task.dueTime != nil { fields.insert("dueTime") }
            if task.intentProvenance == .explicit { fields.insert("calendarIntent") }
        }
        let effect = JSONValue.array(batch.items.map { task in
            .object(["id": .string(task.id.uuidString), "title": .string(task.title), "dueDate": task.dueDate.map(JSONValue.string) ?? .null,
                     "dueTime": task.dueTime.map(JSONValue.string) ?? .null, "timeZone": .string(task.timeZone), "notes": .string(task.notes),
                     "intent": .string(task.resolvedCalendarIntent.rawValue)])
        })
        let operation = AgentPermissionOperation(operationID: UUID(), runID: runID, ownerID: agentPermissionOwnerID, deviceID: Self.syncDeviceID,
            action: .taskCreate, resourceIDs: Set(batch.items.map { $0.id.uuidString }), expectedVersions: [:], calendarIDs: [], fields: fields,
            effectDigest: Self.agentEffectDigest(effect), hasGuestEffects: false, affectsSeries: false, hasSharingEffects: false)
        guard case .allow(let envelope)? = try? await store.reserve(operation, context: .userRequested(), resources: await agentTaskResources(nil, runID: runID)) else { return nil }
        agentPermissionLiveOperations.insert(operation.operationID)
        defer { agentPermissionLiveOperations.remove(operation.operationID) }
        guard (try? taskContext(origin: .agent(runID: runID))) != nil, activeAgentRunID == runID else {
            await releaseAgentReservations([envelope], store: store); throw CancellationError()
        }
        do { try await store.beginDispatch(envelope, resources: await agentTaskResources(nil, runID: runID)) }
        catch { await releaseAgentReservations([envelope], store: store); return nil }
        do {
            _ = try taskContext(origin: .agent(runID: runID))
            var doc = taskDocument
            guard doc.items.count + batch.items.count <= 1000, batch.items.allSatisfy({ item in !doc.items.contains { $0.id == item.id } }) else {
                throw CalendarToolArgumentError("Tasks supports up to 1,000 items.")
            }
            doc.items.append(contentsOf: batch.items)
            let digest = Self.agentEffectDigest(effect)
            doc.operations = (doc.operations ?? []) + batch.items.map {
                CalshotTaskOperationReceipt(operationID: UUID(), requestDigest: digest, taskID: $0.id, taskVersion: $0.version, outcome: "saved", savedAt: .now)
            }
            try persistTasks(doc)
            taskImport = nil
            try? await store.settle(envelope, outcome: .succeeded)
            let rows = batch.items.map { JSONValue.object(["id": .string($0.id.uuidString), "title": .string($0.title), "outcome": .string("saved"), "taskVersion": .string($0.version.uuidString)]) }
            recordAgentTaskOutcome(runID: runID, status: "saved", headline: batch.items.count == 1 ? "Added to Tasks" : "\(batch.items.count) tasks added",
                rows: batch.items.prefix(12).map { .init(id: $0.id, title: $0.title, status: "saved", message: nil) }, viaPermission: true)
            return .array(rows)
        } catch {
            let present = (try? taskStore.load())?.items.map(\.id)
            if let present, batch.items.allSatisfy({ present.contains($0.id) }) { try? await store.settle(envelope, outcome: .succeeded); taskImport = nil }
            else if present != nil { try? await store.settle(envelope, outcome: .failedWithoutEffect); throw error }
            else {
                // Unknown outcome: pause every task mutation until a clean reload, and never retry with new IDs.
                try? await store.settle(envelope, outcome: .unknown)
                taskDataReady = false; taskImport = nil; agentPermissionNeedsReconcile = true
                taskError = "Calshot couldn’t confirm whether new tasks were saved. Your task file was kept. Reload Tasks to check it before adding more."
                throw CalendarToolArgumentError("Calshot couldn’t confirm whether these tasks were saved. Reload Tasks to check before trying again.")
            }
            return .array(batch.items.map { .object(["id": .string($0.id.uuidString), "title": .string($0.title), "outcome": .string("saved")]) })
        }
    }

    // MARK: Direct Add to Tasks (visible exact control, no model, no review)

    /// The Calendar page's Add to Tasks control. The click is the exact visible effect, so it needs no review, but it
    /// uses the same ledger, dispatch fence and domain receipt as the agent: one operation ID throughout, persistent
    /// recovery if the outcome is unknown, and no calendar write. The exact click may exceed automation quotas.
    func linkSelectedEventDirectly(snapshot: CalendarEventSnapshot, destinationID: String, expectedFingerprint: String) async throws -> CalshotTaskOperationReceipt {
        _ = try taskContext(origin: .workspace)
        let store = try await openAgentPermissionStore()
        let resource = "source:" + destinationID + "|" + snapshot.eventIdentifier
        let effect = JSONValue.object(["kind": .string("link"), "calendarID": .string(destinationID),
            "eventID": .string(snapshot.eventIdentifier), "fingerprint": .string(expectedFingerprint)])
        let operation = AgentPermissionOperation(operationID: UUID(), runID: UUID(), ownerID: agentPermissionOwnerID, deviceID: Self.syncDeviceID,
            action: .taskLink, resourceIDs: [resource], expectedVersions: [resource: expectedFingerprint], calendarIDs: [],
            fields: ["sourceLink", "title", "dueDate", "dueTime", "timeZone"], effectDigest: Self.agentEffectDigest(effect),
            hasGuestEffects: false, affectsSeries: false, hasSharingEffects: false)
        func resources() async -> AgentPermissionResources {
            var versions = Dictionary(uniqueKeysWithValues: taskDocument.items.map { ($0.id.uuidString, $0.version.uuidString) })
            if let fingerprint = try? await freshSourceFingerprint(snapshot: snapshot, destinationID: destinationID) { versions[resource] = fingerprint }
            return AgentPermissionResources(ownerID: agentPermissionOwnerID, deviceID: Self.syncDeviceID, versions: versions, writableCalendarIDs: [],
                supportedActions: Self.agentSupportedTaskActions, cancelled: Task.isCancelled || (try? taskContext(origin: .workspace)) == nil)
        }
        let envelope: AgentPermissionEnvelope
        do {
            // The event detail shows the exact source and "Add to Tasks" is its explicit submission.
            // Automation quotas do not block this user-confirmed effect; the ledger still accounts for it.
            switch try await store.reserve(operation, context: .reviewedTaskSubmission(operation), resources: await resources()) {
            case .allow(let allowed): envelope = allowed
            case .requireReview(let reason), .deny(let reason): throw CalendarToolArgumentError(reason + " Nothing was added.")
            }
        } catch let error as AgentPermissionError { throw CalendarToolArgumentError(Self.agentPermissionMessage(error)) }
        agentPermissionLiveOperations.insert(operation.operationID)
        defer { agentPermissionLiveOperations.remove(operation.operationID) }
        do { try await store.beginDispatch(envelope, resources: await resources()) }
        catch {
            try? await store.settle(envelope, outcome: .failedWithoutEffect)
            throw CalendarToolArgumentError("The event or your tasks changed. Select the event again.")
        }
        do {
            let receipt = try await linkExistingEvent(snapshot: snapshot, destinationID: destinationID, expectedFingerprint: expectedFingerprint,
                context: try taskContext(origin: .workspace), operationID: operation.operationID)
            try? await store.settle(envelope, outcome: .succeeded)
            return receipt
        } catch {
            switch await settleAfterFailedTaskWrite(envelope, store: store, operationID: operation.operationID) {
            case .applied(let receipt): return receipt
            case .notApplied: throw error
            case .unknown: throw CalendarToolArgumentError("Calshot couldn’t confirm whether the event was added. Reload Tasks to check before trying again.")
            }
        }
    }

    // MARK: Settings (workspace only; never reachable from tools or the notch)

    func saveAgentTaskPermissions(revision: UInt64, families: [String: Bool], days: Int, renew: Bool = false) async throws {
        guard [7, 30, 90].contains(days), Set(families.keys).isSubset(of: Set(Self.agentTaskFamilies.map(\.id))) else {
            throw CalendarToolArgumentError("Choose valid task permissions.")
        }
        guard !agentPermissionBusy else { throw CalendarToolArgumentError("Permissions are already being saved.") }
        // An account change or teardown while this save awaits must not publish its result into the new account.
        let generation = agentPermissionGeneration
        agentPermissionBusy = true; agentPermissionNotice = nil
        defer { if agentPermissionGeneration == generation { agentPermissionBusy = false } }
        let owner = agentPermissionOwnerID
        do {
            let store = try await openAgentPermissionStore()
            guard agentPermissionGeneration == generation, owner == agentPermissionOwnerID else { throw CancellationError() }
            let current = try await store.snapshot()
            guard agentPermissionGeneration == generation else { throw CancellationError() }
            guard current.revision == revision else {
                agentPermissionPolicy = current
                throw CalendarToolArgumentError("Permissions changed on this Mac. Check the latest settings and save again.")
            }
            let now = Date.now, expires = now.addingTimeInterval(Double(days) * 86_400)
            let existing = Dictionary(current.grants.map { ($0.action, $0) }, uniquingKeysWith: { first, _ in first })
            var grants = current.grants.filter { grant in !Self.agentTaskFamilies.contains { $0.action == grant.action } }
            for family in Self.agentTaskFamilies where families[family.id] == true {
                // An unexpired family keeps its period unless the user explicitly renews it.
                let kept = existing[family.action].flatMap { $0.requestedEnabled && $0.expiresAt > now && !renew ? $0.expiresAt : nil }
                grants.append(AgentPermissionGrant(action: family.action, requestedEnabled: true, backgroundEnabled: false,
                    calendarIDs: [], fields: Self.agentTaskGrantFields[family.action] ?? [], expiresAt: kept ?? expires))
            }
            let control = AgentPermissionSettingsControl(nativeOwnerID: owner, nativeDeviceID: Self.syncDeviceID)
            let policy = try await store.replaceGrants(grants, expectedRevision: revision, control: control,
                maxPerRun: current.maxPerRun, maxPerWindow: current.maxPerWindow, windowSeconds: current.windowSeconds)
            guard agentPermissionGeneration == generation, owner == agentPermissionOwnerID else { throw CancellationError() }
            agentPermissionPolicy = policy
            agentPermissionNotice = families.values.contains(true)
                ? "Saved. These task actions apply to new requests on this Mac."
                : "Saved. Calshot will ask before changing tasks."
        } catch is CancellationError { throw CalendarToolArgumentError("The account changed. Open Settings and try again.") }
        catch let error as AgentPermissionError { throw CalendarToolArgumentError(Self.agentPermissionMessage(error)) }
    }

    /// Credential-free view state. Device-local: this is never part of the account sync document.
    func agentPermissionSnapshot() -> JSONValue {
        let now = Date.now
        let grants = agentPermissionPolicy?.grants ?? []
        var latest: Date?
        let families: [JSONValue] = Self.agentTaskFamilies.map { family in
            let grant = grants.first { $0.action == family.action }
            let active = grant.map { $0.requestedEnabled && $0.expiresAt > now } ?? false
            if active, let expires = grant?.expiresAt, latest == nil || expires > latest! { latest = expires }
            return .object(["id": .string(family.id), "label": .string(family.label), "detail": .string(family.detail),
                            "enabled": .bool(active), "expired": .bool(grant != nil && !active)])
        }
        return .object(["loaded": .bool(agentPermissionPolicy != nil), "busy": .bool(agentPermissionBusy),
            "error": agentPermissionError.map(JSONValue.string) ?? .null, "notice": agentPermissionNotice.map(JSONValue.string) ?? .null,
            "revision": .number(Double(agentPermissionPolicy?.revision ?? 0)), "families": .array(families),
            "expiresAt": latest.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "limits": .object(["perRun": .number(Double(agentPermissionPolicy?.maxPerRun ?? 20)), "perWindow": .number(Double(agentPermissionPolicy?.maxPerWindow ?? 100)),
                               "windowMinutes": .number((agentPermissionPolicy?.windowSeconds ?? 3600) / 60)])])
    }

    func agentTaskReviewSnapshot() -> JSONValue {
        guard let review = agentTaskReview else { return .null }
        return .object(["id": .string(review.id.uuidString), "token": .string(review.token), "digest": .string(review.digest),
            "kind": .string(review.kind), "heading": .string(review.heading), "phase": .string(review.phase.rawValue),
            "reason": .string(review.reason), "calendarWrites": .number(0), "error": review.error.map(JSONValue.string) ?? .null,
            "rows": .array(review.rows.prefix(100).map { row in
                .object(["id": .string(row.id.uuidString), "title": .string(row.title), "note": row.note.map(JSONValue.string) ?? .null,
                         "changes": .array(row.changes.map { .object(["label": .string($0.label), "before": $0.before.map(JSONValue.string) ?? .null, "after": $0.after.map(JSONValue.string) ?? .null]) })])
            })])
    }

    func agentTaskOutcomeSnapshot() -> JSONValue {
        guard let outcome = agentTaskOutcome else { return .null }
        return .object(["id": .string(outcome.id.uuidString), "status": .string(outcome.status), "headline": .string(outcome.headline),
            "viaSavedPermission": .bool(outcome.viaSavedPermission),
            "rows": .array(outcome.rows.map { .object(["id": .string($0.id.uuidString), "title": .string($0.title), "status": .string($0.status), "message": $0.message.map(JSONValue.string) ?? .null]) })])
    }
}
