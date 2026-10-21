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
            onApproval: { [weak self] value in self?.agentIsWaitingForApproval = value },
            onQuestion: { [weak self] question in self?.agentQuestion = question },
            onStep: { [weak self] text in self?.agentStatus = text })
        executor.listFriends = { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.listAgentFriends()
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
        guard currentCaptureSessionID == sessionID else { return }
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

    func startAgentCommand(expectedSessionID: UUID? = nil) async {
        guard !softwareUpdates.installing else { return }
        guard account.canUseWorkspace else { openPanel(); return }
        guard expectedSessionID == nil || currentCaptureSessionID == expectedSessionID else { return }
        let prompt = agentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSaving, !isCapturing else { return }
        stopAgent()
        await Task.yield()
        guard expectedSessionID == nil || currentCaptureSessionID == expectedSessionID else { return }
        analysisTask?.cancel()
        agentCommand = ""
        status = nil; agentError = nil; agentRetryPrompt = nil; agentSummary = nil
        currentAgentPrompt = String(prompt.prefix(8000))
        let sessionID = UUID()
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
        agentStatus = image == nil ? "Reading your command" : "Reading the screenshot"
        if destinations.isEmpty { await loadCalendars() }
        guard currentCaptureSessionID == sessionID, !Task.isCancelled else { return }
        do {
            let imageURL = try image.map(ResponsesCalendarAgentClient.imageDataURL)
            analyzedWithOpenAI = agentClient == nil
            lastAnalysisProvider = agentClient == nil ? "Calendar agent + Vision OCR" : "Offline calendar agent demo"
            try await agent.start(userMessage: prompt, imageDataURL: imageURL, memory: memory, sessionID: sessionID)
            guard currentCaptureSessionID == sessionID else { return }
            lastCaptureSummary = "\(calendarActions.addedCount) added · \(calendarActions.updatedCount) changed · \(calendarActions.deletedCount) removed · \(calendarActions.movedCount) moved"
        } catch is CancellationError { }
        catch {
            guard currentCaptureSessionID == sessionID, !Task.isCancelled else { return }
            agentError = error.localizedDescription
            agentRetryPrompt = prompt
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
        agentCommand = prompt
        await startAgentCommand()
    }

    func stopAgent() {
        calendarAgent?.cancel()
        agentIsRunning = false
        if calendarActions.isExecuting { calendarActions.requestStop() }
    }
    func answerAgentQuestion(_ answer: String) { agentToolExecutor?.answerQuestion(answer) }
    func cancelAgentQuestion() { agentToolExecutor?.answerQuestion(nil) }
    func skipAgentApproval() { agentToolExecutor?.skipApproval() }
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
