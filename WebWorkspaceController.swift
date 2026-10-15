import AppKit
import WebKit
import EventKit
import SwiftUI

/// Presentation-only boundary. All calendar writes still pass through the native coordinator.
@MainActor
final class WebWorkspaceController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let isNotch: Bool
    var onNotchLayout: ((Bool, Int?) -> Void)?
    var onNotchCollapse: (() -> Void)?
    let model: CalshotModel
    let assets: WebWorkspaceAssets
    private(set) var webView: WKWebView!
    private var timer: Timer?
    private var lastSnapshot = ""
    private var notice: String?
    private var comparisons: [String: JSONValue] = [:]
    private var ready = false
    private var allowedPageURL: URL?
    private var accounts: [JSONValue] = []
    private var googleReady = false
    private var duplicateCheckRunning = false
    private var wasConnecting = false
    private var settingsWindow: NSWindow?

    init(model: CalshotModel, loadsResources: Bool = true, isNotch: Bool = false) {
        self.isNotch = isNotch; self.model = model; assets = WebWorkspaceAssets(model: model)
        super.init()
        guard loadsResources else { return }
        let configuration = WKWebViewConfiguration()
        if isNotch {
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__calshotSurface = 'notch';", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.setURLSchemeHandler(assets, forURLScheme: "calshot-asset")
        configuration.userContentController.add(self, name: "calshot")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        refreshAccounts()
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebUI") {
            allowedPageURL = url.standardizedFileURL
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }
    func resetNotchPresentation() {
        guard isNotch, let webView else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new Event('calshot:notch-collapsed'))", completionHandler: nil)
    }
    func refreshAccounts() {
        accounts = model.directCalendarAccounts.map { account in
            .object(["id": .string(account.id.uuidString), "email": .string(account.email), "provider": .string(account.provider.rawValue),
                     "unavailable": .bool(model.readableCalendars.contains { $0.id == "unavailable:" + account.id.uuidString })])
        }
        let client = UserDefaults.standard.string(forKey: "googleCalendarClientID") ?? CalendarAccountConnection.googleClientID
        googleReady = CalendarAccountConnection.googleClientSecret(clientID: client) != nil
    }
    func publish() {
        guard ready else { return }
        if wasConnecting && !model.calendarAccountIsConnecting { refreshAccounts() }
        wasConnecting = model.calendarAccountIsConnecting
        if !duplicateCheckRunning, !model.isSaving, !model.calendarActions.isCheckingDuplicates,
           let destination = model.selectedCalendarID,
           model.calendarActions.needsDuplicateCheck(destinationID: destination),
           model.calendarActions.proposals.contains(where: { !$0.isFinished && model.calendarActions.isInApprovalScope($0.id) }) {
            duplicateCheckRunning = true
            Task { [weak self] in
                guard let self else { return }
                await model.calendarActions.checkDuplicates(destinationID: destination)
                duplicateCheckRunning = false
            }
        }
        assets.refreshImage()
        let snapshot = WebWorkspaceState.make(model, imageURL: assets.currentURL, notice: notice, accounts: accounts, googleReady: googleReady, comparisons: comparisons).jsonString()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        Task { try? await webView.callAsyncJavaScript("window.__calshotReceive(state)", arguments: ["state": (try? JSONSerialization.jsonObject(with: Data(snapshot.utf8))) ?? [:]], in: nil, contentWorld: .page) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.standardizedFileURL == allowedPageURL,
              let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] as? String else { return }
        Task { @MainActor in
            do { try await handle(action, body); reply(id, error: nil) }
            catch { reply(id, error: error.localizedDescription) }
            publish()
        }
    }
    private func reply(_ id: String, error: String?) {
        Task { try? await webView.callAsyncJavaScript("window.__calshotReply(reply)", arguments: ["reply": ["id": id, "ok": error == nil, "error": error ?? ""]], in: nil, contentWorld: .page) }
    }
    private func requireIdle() throws {
        guard !model.isSaving, !model.isCapturing, !model.agentIsRunning, !model.isRecognizing else { throw CalendarToolArgumentError("Finish or stop the current task first.") }
    }
    private func requireReview(_ body: [String: Any]) throws {
        guard !model.agentIsRunning || model.agentIsWaitingForApproval else { throw CalendarToolArgumentError("Wait for Calshot to finish preparing this review.") }
        guard !model.isSaving, !model.calendarActions.isCheckingDuplicates, body["token"] as? String == WebWorkspaceState.approvalToken(model) else {
            throw CalendarToolArgumentError("The review changed. Check the latest events before continuing.")
        }
    }
    func handle(_ action: String, _ body: [String: Any]) async throws {
        switch action {
        case "notchLayout":
            guard isNotch, let detail = body["detail"] as? Bool else { throw CalendarToolArgumentError("Invalid notch layout.") }
            let height = body["height"] as? Int
            guard body["height"] == nil || (height != nil && (200...490).contains(height!)) else { throw CalendarToolArgumentError("Invalid notch height.") }
            onNotchLayout?(detail, height)
        case "collapseNotch":
            guard isNotch else { throw CalendarToolArgumentError("Notch action unavailable.") }
            onNotchCollapse?()
        case "openWorkspace": model.taskUsesNotch = false; model.openPanel()
        case "ready":
            ready = true; lastSnapshot = ""; model.refreshMemory()
            if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
                model.calendarConnectionMessage = "Checking connected calendars…"
                Task { await model.loadCalendars(); refreshAccounts() }
            }
        case "navigate":
            guard let raw = body["page"] as? String, let page = WorkspaceSection(rawValue: raw) else { return }
            model.workspaceSelection = page
            if page == .library { model.refreshMemory() }
            if page == .calendars { Task { await model.loadCalendars(); refreshAccounts() } }
        case "dismissNotice": notice = nil
        case "capture":
            guard !model.isSaving, !model.isCapturing else { throw CalendarToolArgumentError("Wait for the current action to finish.") }
            model.taskUsesNotch = isNotch
            Task { await model.capture(quick: isNotch, appendToBatch: body["append"] as? Bool == true, askAfterCapture: isNotch) }
        case "send":
            let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 8000 else { throw CalendarToolArgumentError("Enter a message up to 8,000 characters.") }
            if let question = model.agentQuestion {
                guard body["questionID"] as? String == question.id.uuidString else { throw CalendarToolArgumentError("This question changed. Answer the current question.") }
                model.answerAgentQuestion(text)
            } else {
                try requireIdle(); model.taskUsesNotch = isNotch; model.agentCommand = text
                Task { await model.startAgentCommand() }
                if isNotch { onNotchCollapse?() }
            }
        case "answer", "cancelQuestion":
            guard let question = model.agentQuestion, body["questionID"] as? String == question.id.uuidString else { throw CalendarToolArgumentError("This question is no longer waiting for an answer.") }
            if action == "cancelQuestion" { model.cancelAgentQuestion() }
            else { guard let answer = body["answer"] as? String, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.count <= 8000 else { throw CalendarToolArgumentError("Enter an answer.") }; model.answerAgentQuestion(answer) }
            if isNotch { onNotchCollapse?() }
        case "stop": model.stopAgent(); model.calendarActions.requestStop()
        case "newTask":
            try requireIdle(); comparisons = [:]; model.currentCaptureSessionID = UUID(); model.currentMemoryRecordID = nil
            model.image = nil; model.recognizedText = ""; model.agentMessages = []; model.agentTranscriptPrefix = []
            model.agentSummary = nil; model.agentStreamingText = ""; model.agentError = nil; model.agentStatus = nil; model.status = nil
            model.agentRetryPrompt = nil; model.calendarActions.replace(with: []); model.workspaceSelection = .chat
        case "selectCalendar":
            guard !model.isSaving, let value = body["calendarID"] as? String, model.destinations.contains(where: { $0.id == value && !$0.isReadOnly }) else { throw CalendarToolArgumentError("Choose an available writable calendar.") }
            model.selectedCalendarID = value
        case "selectProposal":
            try requireReview(body)
            guard let raw = body["proposalID"] as? String, let id = UUID(uuidString: raw), let selected = body["selected"] as? Bool,
                  let row = model.calendarActions.proposals.first(where: { $0.id == id }), model.calendarActions.isInApprovalScope(id), !row.isFinished else { throw CalendarToolArgumentError("This event is no longer in the current review.") }
            guard !selected || (row.operation == .delete ? row.targetEventIdentifier != nil : row.canAdd) else { throw CalendarToolArgumentError("Resolve this event's details or duplicate first.") }
            model.calendarActions.update(id) { $0.isSelected = selected }
        case "compareDuplicate":
            try requireReview(body)
            guard let id = (body["proposalID"] as? String).flatMap(UUID.init(uuidString:)),
                  let row = model.calendarActions.proposals.first(where: { $0.id == id }), model.calendarActions.isInApprovalScope(id),
                  let destinationID = row.targetDestinationID ?? model.selectedCalendarID else { throw CalendarToolArgumentError("This duplicate is no longer available.") }
            var drafts: [EventDraft] = []
            for identifier in row.duplicateIdentifiers.prefix(10) where identifier != "batch" {
                if let event = try await model.calendarService.event(identifier: identifier, in: .resolve(identifier: destinationID)) { drafts.append(event.draft) }
            }
            if row.duplicateIdentifiers.contains("batch") {
                drafts += model.calendarActions.proposals.filter { $0.id != id && CalendarDraftValidation.sameEvent($0.draft, row.draft) }.map(\.draft)
            }
            try requireReview(body)
            comparisons[id.uuidString] = WebWorkspaceState.encoded(drafts)
        case "allowDuplicate":
            try requireReview(body)
            guard let id = (body["proposalID"] as? String).flatMap(UUID.init(uuidString:)), model.calendarActions.isInApprovalScope(id) else { return }
            model.calendarActions.update(id) { $0.allowDuplicate = true; $0.isSelected = $0.canAdd }
        case "approve":
            try requireReview(body)
            guard model.calendarActions.canApprove else { throw CalendarToolArgumentError("Select ready events and an available destination first.") }
            if isNotch { onNotchCollapse?() }
            await model.saveEvents()
        case "skipApproval":
            try requireReview(body)
            if model.agentIsWaitingForApproval { model.skipAgentApproval() } else { model.calendarActions.skipAll() }
        case "editProposal": try edit(body)
        case "retryAgent": try requireIdle(); model.taskUsesNotch = isNotch; Task { await model.retryAgentCommand() }
        case "restoreMemory":
            try requireIdle()
            guard let raw = body["recordID"] as? String, let record = model.memoryRecords.first(where: { $0.id.uuidString == raw }) else { throw CalendarToolArgumentError("This task is no longer in History.") }
            model.taskUsesNotch = isNotch
            model.restoreCalendarReview(record)
        case "deleteMemory":
            try requireIdle()
            guard let id = (body["recordID"] as? String).flatMap(UUID.init(uuidString:)) else { return }
            model.deleteMemoryRecord(id)
        case "refreshCalendars": try requireIdle(); await model.loadCalendars(); refreshAccounts()
        case "connectGoogle":
            guard !model.calendarAccountIsConnecting else { return }
            let client = UserDefaults.standard.string(forKey: "googleCalendarClientID") ?? CalendarAccountConnection.googleClientID
            model.connectCalendarAccount(.google, clientID: client)
        case "cancelConnection": model.cancelCalendarConnection()
        case "disconnectAccount":
            try requireIdle()
            guard let id = (body["accountID"] as? String).flatMap(UUID.init(uuidString:)) else { return }
            await model.disconnectCalendarAccount(id); refreshAccounts()
        case "screenSettings": model.openScreenCaptureSettings()
        case "calendarSettings": NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
        case "sidebar":
            guard let expanded = body["expanded"] as? Bool else { throw CalendarToolArgumentError("Choose whether to expand the sidebar.") }
            model.sidebarExpanded = expanded
        case "appearance":
            guard let value = body["mode"] as? String, let mode = AppAppearance(rawValue: value) else { throw CalendarToolArgumentError("Choose Light, Dark, or System appearance.") }
            model.appearanceMode = mode
        case "provider":
            try requireIdle(); model.agentUseAPIKey = body["useAPIKey"] as? Bool == true
        case "agentEnabled": try requireIdle(); model.openAIAnalysisEnabled = body["enabled"] as? Bool == true
        case "copyCaptures": CaptureClipboard.automaticallyCopyCapture = body["enabled"] as? Bool == true
        case "saveAPIKey":
            try requireIdle(); try model.saveOpenAIAPIKey(body["key"] as? String ?? "")
        case "testAI": notice = try await model.testOpenAIConnection()
        case "connectChatGPT": try requireIdle(); try await model.connectChatGPT()
        case "refreshChatGPT": await model.refreshChatGPTModels()
        case "advancedSettings": openAdvancedSettings()
        default: throw CalendarToolArgumentError("This action isn't available in this version of Calshot.")
        }
    }
    private func edit(_ body: [String: Any]) throws {
        try requireReview(body)
        guard let id = (body["proposalID"] as? String).flatMap(UUID.init(uuidString:)),
              let row = model.calendarActions.proposals.first(where: { $0.id == id }), !row.isFinished,
              model.calendarActions.isInApprovalScope(id), row.operation != .delete, row.operation != .move,
              let fields = body["fields"] as? [String: Any] else { throw CalendarToolArgumentError("This event cannot be edited here.") }
        let zone = fields["timeZone"] as? String ?? ""
        guard let timeZone = TimeZone(identifier: zone) else { throw CalendarToolArgumentError("Choose a valid time zone, such as America/Toronto.") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"; formatter.isLenient = false
        guard let startText = fields["start"] as? String, let endText = fields["end"] as? String,
              let start = formatter.date(from: startText), let end = formatter.date(from: endText), end > start,
              formatter.string(from: start) == startText, formatter.string(from: end) == endText else { throw CalendarToolArgumentError("Choose valid start and end times, with the end after the start.") }
        let title = (fields["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 500 else { throw CalendarToolArgumentError("Enter an event title up to 500 characters.") }
        let urlText = (fields["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlText.isEmpty ? nil : URL(string: urlText)
        guard urlText.isEmpty || (url?.host != nil && ["http", "https"].contains(url?.scheme?.lowercased() ?? "")) else { throw CalendarToolArgumentError("Enter a valid https or http link.") }
        model.calendarActions.edit(id) { draft in
            draft.title = title; draft.startDate = start; draft.endDate = end; draft.isAllDay = fields["allDay"] as? Bool == true
            draft.timeZoneIdentifier = zone; draft.location = fields["location"] as? String; draft.url = url; draft.notes = fields["notes"] as? String
            if draft.isAllDay {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
                draft.startDate = calendar.startOfDay(for: start)
                let endDay = calendar.startOfDay(for: end)
                draft.endDate = endDay > draft.startDate! ? endDay : calendar.date(byAdding: .day, value: 1, to: draft.startDate!)
            }
            draft.ambiguities = []
        }
    }
    private func openAdvancedSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Calshot — Advanced settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: NativeAdvancedSettings(model: model))
            window.appearance = nil
            settingsWindow = window; window.center()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.request.url?.standardizedFileURL == allowedPageURL { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; lastSnapshot = ""; webView.reload() }
}


private struct NativeAdvancedSettings: View {
    @ObservedObject var model: CalshotModel
    var body: some View {
        TabView {
            SettingsView(model: model, section: .general).tabItem { Text("Capture") }
            SettingsView(model: model, section: .ai).tabItem { Text("AI") }
            CalendarConnectionsView(model: model).tabItem { Text("Connection setup") }
            SettingsView(model: model, section: .memory).tabItem { Text("Storage") }
        }
    }
}
