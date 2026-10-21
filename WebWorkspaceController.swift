import AppKit
import WebKit
import EventKit
import SwiftUI

/// A nonactivating notch must deliver its first click, rather than consuming it for focus.
@MainActor
final class WorkspaceWebView: WKWebView {
    var acceptsInactiveClicks = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        acceptsInactiveClicks || super.acceptsFirstMouse(for: event)
    }
}

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
    private var settingsSection = "general"
    private var calendarViewRequestID = UUID()
    private var lastFriendAccessToken = ""
    private(set) var calendarView: JSONValue = .object(["loaded": .bool(false), "loading": .bool(false), "events": .array([]), "errors": .array([])])

    init(model: CalshotModel, loadsResources: Bool = true, isNotch: Bool = false) {
        self.isNotch = isNotch; self.model = model; assets = WebWorkspaceAssets(model: model)
        super.init()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--sharing-preview") && !isNotch { settingsSection = "friends" }
#endif
        guard loadsResources else { return }
        let configuration = WKWebViewConfiguration()
        if isNotch {
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__calshotSurface = 'notch';", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.setURLSchemeHandler(assets, forURLScheme: "calshot-asset")
        configuration.userContentController.add(self, name: "calshot")
        let content = WorkspaceWebView(frame: .zero, configuration: configuration)
        content.acceptsInactiveClicks = isNotch
        webView = content
        webView.allowsBackForwardNavigationGestures = false
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
    /// Read-only browsing is independent of the agent and cannot approve or mutate events.
    func loadCalendarView(_ body: [String: Any]) async throws {
        guard !isNotch else { throw CalendarToolArgumentError("Open the calendar in the workspace.") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        func date(_ key: String) -> Date? {
            guard let text = body[key] as? String else { return nil }
            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        guard let start = date("start"), let end = date("end"), end > start, end.timeIntervalSince(start) <= 63 * 86400 else {
            throw CalendarToolArgumentError("Choose a calendar range of up to 63 days.")
        }
        guard let identifiers = body["calendarIDs"] as? [String], identifiers.count <= 100, Set(identifiers).count == identifiers.count else {
            throw CalendarToolArgumentError("Choose available calendars.")
        }
        let calendars = model.readableCalendars.filter { identifiers.contains($0.id) }
        let shared = model.friendBrowserSources.filter { identifiers.map { $0.lowercased() }.contains($0.id.lowercased()) }
        guard calendars.count + shared.count == identifiers.count else { throw CalendarToolArgumentError("A calendar changed. Refresh your calendars and try again.") }
        let owner = model.account.userID
        let accessToken = model.friendAccessToken
        let id = UUID(); calendarViewRequestID = id
        calendarView = .object(["loading": .bool(true), "loaded": .bool(false), "start": .string(ISO8601DateFormatter().string(from: start)), "end": .string(ISO8601DateFormatter().string(from: end)), "events": .array([]), "errors": .array([])])
        publish()
        var events: [JSONValue] = [], errors: [JSONValue] = []
        var truncated = false
        for calendar in calendars {
            guard calendarViewRequestID == id else { return }
            do {
                if calendar.id.hasPrefix("unavailable:") { throw CalendarDestinationError.calendarUnavailable }
                let result = try await browseEvents(start: start, end: end, calendarID: calendar.id)
                truncated = truncated || result.truncated
                var seen = Set<String>()
                for event in result.events.sorted(by: { $0.start < $1.start }) where event.start < end && event.end > start {
                    let key = event.eventIdentifier + "|" + String(event.start.timeIntervalSince1970)
                    guard seen.insert(key).inserted else { continue }
                    var row = WebWorkspaceState.encoded(event).objectValue ?? [:]
                    row["calendarIdentifier"] = .string(calendar.id)
                    row["calendarName"] = .string(calendar.title)
                    row["sourceName"] = .string(calendar.sourceName ?? calendar.provider.rawValue.capitalized)
                    events.append(.object(row))
                }
            } catch {
                errors.append(.object(["calendarIdentifier": .string(calendar.id), "calendarName": .string(calendar.title), "message": .string(error.localizedDescription)]))
            }
        }
        for source in shared {
            guard calendarViewRequestID == id, model.account.userID == owner, model.friendAccessToken == accessToken else { return }
            do {
                let result = try await model.browseFriendCalendar(id: source.id, start: start, end: end)
                guard calendarViewRequestID == id, model.account.userID == owner, model.friendAccessToken == accessToken else { return }
                events.append(contentsOf: result.events)
                if let warning = result.warning { errors.append(.object(["calendarIdentifier": .string(source.id), "calendarName": .string(source.share.personName + " · " + source.calendar.name), "message": .string(warning)])) }
            } catch {
                errors.append(.object(["calendarIdentifier": .string(source.id), "calendarName": .string(source.share.personName + " · " + source.calendar.name), "message": .string(error.localizedDescription)]))
            }
        }
        guard calendarViewRequestID == id, model.account.userID == owner, model.friendAccessToken == accessToken else { return }
        if events.count > 3000 { truncated = true }
        calendarView = .object(["loading": .bool(false), "loaded": .bool(true), "start": .string(ISO8601DateFormatter().string(from: start)), "end": .string(ISO8601DateFormatter().string(from: end)), "events": .array(Array(events.prefix(3000))), "errors": .array(errors), "truncated": .bool(truncated)])
    }
    private func browseEvents(start: Date, end: Date, calendarID: String, depth: Int = 0) async throws -> (events: [CalendarEventSnapshot], truncated: Bool) {
        let events = try await model.calendarService.searchEvents(query: nil, start: start, end: end, in: .resolve(identifier: calendarID))
        // Agent searches cap their results at 40. Subdivide busy ranges for the calendar UI.
        guard events.count >= 40 else { return (events, false) }
        guard depth < 6, end.timeIntervalSince(start) > 86400 else { return (events, true) }
        let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        let left = try await browseEvents(start: start, end: middle, calendarID: calendarID, depth: depth + 1)
        let right = try await browseEvents(start: middle, end: end, calendarID: calendarID, depth: depth + 1)
        return (left.events + right.events, left.truncated || right.truncated)
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
        let friendToken = model.friendAccessToken
        if lastFriendAccessToken != friendToken {
            lastFriendAccessToken = friendToken
            calendarViewRequestID = UUID()
            calendarView = .object(["loaded": .bool(false), "loading": .bool(false), "events": .array([]), "errors": .array([])])
        }
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
        var viewState = WebWorkspaceState.make(model, imageURL: assets.currentURL, notice: notice, accounts: accounts, googleReady: googleReady, comparisons: comparisons).objectValue ?? [:]
        viewState["settingsSection"] = .string(settingsSection)
        viewState["calendarView"] = calendarView
        let snapshot = JSONValue.object(viewState).jsonString()
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
    private func resetConversation() {
        model.analysisTask?.cancel(); model.analysisTask = nil; model.ocrTask?.cancel(); model.ocrTask = nil
        model.activeAgentRunID = nil; model.agentCommand = ""
        comparisons = [:]; model.currentCaptureSessionID = UUID(); model.currentMemoryRecordID = nil
        model.image = nil; model.previousCaptureImage = nil; model.recognizedText = ""
        model.screenRecognition = ScreenTextRecognition(lines: []); model.currentAgentSourceID = nil
        model.agentMessages = []; model.agentTranscriptPrefix = []
        model.agentSummary = nil; model.agentStreamingText = ""; model.agentError = nil; model.agentStatus = nil; model.status = nil
        model.agentRetryPrompt = nil; model.calendarActions.replace(with: []); model.workspaceSelection = .chat
    }
    private func requireReview(_ body: [String: Any]) throws {
        guard !model.agentIsRunning || model.agentIsWaitingForApproval else { throw CalendarToolArgumentError("Wait for Calshot to finish preparing this review.") }
        guard !model.isSaving, !model.calendarActions.isCheckingDuplicates, body["token"] as? String == WebWorkspaceState.approvalToken(model) else {
            throw CalendarToolArgumentError("The review changed. Check the latest events before continuing.")
        }
    }
    static let actionsAllowedBeforeSignIn: Set<String> = ["ready", "notchLayout", "collapseNotch", "openWorkspace", "appearance", "authSignIn", "authSignUp", "authGoogle", "authVerify", "authResend", "authReset", "authChangePassword", "authRestore"]
    func handle(_ action: String, _ body: [String: Any]) async throws {
        guard !model.softwareUpdates.installing else { throw CalendarToolArgumentError("Calshot is restarting to install an update.") }

        if isNotch && action.hasPrefix("auth") { throw CalendarToolArgumentError("Manage your account in the Calshot window.") }
        let accountActions = Self.actionsAllowedBeforeSignIn
        if model.account.requiresLogin && !accountActions.contains(action) { throw CalendarToolArgumentError("Sign in to Calshot to continue.") }
        if model.account.enabled, !model.account.onboarded, !model.account.aiSetupConfirmed,
           ["refreshCalendars", "connectGoogle", "selectCalendar", "calendarSettings"].contains(action) {
            throw CalendarToolArgumentError("Set up your AI service before confirming calendars.")
        }
        switch action {
        case "checkForUpdates":
            guard !isNotch else { throw CalendarToolArgumentError("Check for updates in Settings.") }
            try model.softwareUpdates.check()
        case "updatePreferences":
            guard !isNotch, let checks = body["checks"] as? Bool, let downloads = body["downloads"] as? Bool,
                  CFGetTypeID(body["checks"] as CFTypeRef) == CFBooleanGetTypeID(),
                  CFGetTypeID(body["downloads"] as CFTypeRef) == CFBooleanGetTypeID() else {
                throw CalendarToolArgumentError("Choose valid update preferences in Settings.")
            }
            try model.softwareUpdates.setPreferences(checks: checks, downloads: downloads)

        case "authSignIn", "authSignUp":
            guard !isNotch else { throw CalendarToolArgumentError("Sign in from the Calshot window.") }
            try await model.account.signIn(email: body["email"] as? String ?? "", password: body["password"] as? String ?? "", signUp: action == "authSignUp", name: body["name"] as? String ?? "")
        case "authGoogle":
            guard !isNotch else { throw CalendarToolArgumentError("Sign in from the Calshot window.") }
            try await model.account.googleSignIn()
        case "authConfirmAI":
            try requireIdle()
            guard let provider = body["provider"] as? String else { throw CalendarToolArgumentError("Choose an AI service.") }
            try model.confirmOnboardingAI(provider)
        case "setMacCalendarSync":
            try requireIdle()
            guard !isNotch, let calendarID = body["calendarID"] as? String, let enabled = body["enabled"] as? Bool else { throw CalendarToolArgumentError("Choose a calendar web sync setting in the workspace.") }
            try await model.setMacCalendarSync(calendarID: calendarID, enabled: enabled)
        case "stopMacCalendarSync":
            try requireIdle()
            guard !isNotch, let raw = body["mirrorID"] as? String, let mirror = UUID(uuidString: raw) else { throw CalendarToolArgumentError("Choose a synced calendar in the workspace.") }
            try await model.stopMacCalendarSync(mirrorID: mirror)
        case "syncMacCalendars":
            try requireIdle()
            guard !isNotch else { throw CalendarToolArgumentError("Manage calendar sync in the workspace.") }
            await model.syncMacCalendars(force: true)
        case "syncAccount": try requireIdle(); await model.syncAccount()
        case "authVerify": try await model.account.verify(code: body["code"] as? String ?? "")
        case "authResend": try await model.account.resendConfirmation()
        case "authReset": try await model.account.forgotPassword(email: body["email"] as? String ?? "")
        case "authChangePassword": try await model.account.changePassword(body["password"] as? String ?? "")
        case "authRestore": await model.account.restore(); await model.account.refreshProviders()
        case "authFinish":
            guard !model.account.requiresLogin, model.onboardingAIReady, model.account.aiSetupConfirmed || !model.account.enabled, model.readableCalendars.contains(where: { !$0.id.hasPrefix("unavailable:") }) else { throw CalendarToolArgumentError("Set up your AI service and confirm an available calendar first.") }
            model.account.finishOnboarding()
        case "authSignOut":
            try requireIdle()
            model.accountSyncTask?.cancel(); model.accountSyncTimer?.invalidate()
            try await model.account.signOut()
            model.accountSyncDevices = [:]; model.accountSyncError = nil; model.accountSyncLastDate = nil
            model.calendarSharing = CalendarSharingState(); model.sharingLoaded = false; model.sharingBusy = false; model.sharingError = nil
            model.stopAgent(); resetConversation()
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
            if page == .settings {
                let section = body["section"] as? String ?? "general"
                guard ["general", "calendars", "friends", "ai", "privacy"].contains(section) else { throw CalendarToolArgumentError("Unknown settings section.") }
                settingsSection = section
            }
            model.workspaceSelection = page
            if page == .settings && settingsSection == "friends" { Task { await model.refreshSharing() } }
            if page == .library { model.refreshMemory() }
            if page == .calendars || (page == .settings && settingsSection == "calendars") { Task { await model.loadCalendars(); refreshAccounts() } }
        case "loadCalendarEvents": try await loadCalendarView(body)
        case "dismissNotice": notice = nil
        case "capture":
            guard !model.isSaving, !model.isCapturing else { throw CalendarToolArgumentError("Wait for the current action to finish.") }
            model.taskUsesNotch = isNotch
            Task { await model.capture(quick: isNotch, appendToBatch: body["append"] as? Bool == true, askAfterCapture: isNotch) }
        case "startCalendarTask":
            guard !isNotch, model.workspaceSelection == .calendars else { throw CalendarToolArgumentError("Start calendar questions from Calendar.") }
            let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 8000 else { throw CalendarToolArgumentError("Enter a message up to 8,000 characters.") }
            try requireIdle()
            guard model.agentQuestion == nil, !model.agentIsWaitingForApproval, !model.calendarActions.isCheckingDuplicates else { throw CalendarToolArgumentError("Finish or stop the current task first.") }
            resetConversation()
            model.taskUsesNotch = false; model.agentCommand = text
            let sessionID = model.currentCaptureSessionID
            Task { [weak model] in
                guard let model, model.currentCaptureSessionID == sessionID else { return }
                await model.startAgentCommand(expectedSessionID: sessionID)
            }
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
            try requireIdle(); resetConversation()
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
        case "refreshSharing":
            guard !isNotch else { throw CalendarToolArgumentError("Manage sharing in Settings.") }
            await model.refreshSharing()
        case "syncSharing":
            guard !isNotch else { throw CalendarToolArgumentError("Manage sharing in Settings.") }
            try requireIdle(); await model.syncSharedCalendars(force: true)
        case "requestCalendarShare":
            guard !isNotch else { throw CalendarToolArgumentError("Manage sharing in Settings.") }
            try requireIdle()
            guard let email = body["email"] as? String, let ids = body["calendarIDs"] as? [String], let permission = body["permission"] as? String else { throw CalendarToolArgumentError("Choose a friend, calendars and an access level.") }
            try await model.sendCalendarRequest(email: email, calendarIDs: ids, permission: permission, token: body["sharingToken"] as? String)
        case "respondCalendarRequest":
            guard !isNotch, let id = (body["requestID"] as? String).flatMap(UUID.init(uuidString:)), let accept = body["accept"] as? Bool else { throw CalendarToolArgumentError("Choose a current sharing request.") }
            try await model.respondCalendarRequest(id: id, accept: accept, token: body["sharingToken"] as? String)
        case "manageCalendarShare":
            guard !isNotch, let id = (body["requestID"] as? String).flatMap(UUID.init(uuidString:)), let permission = body["permission"] as? String, let stop = body["stop"] as? Bool else { throw CalendarToolArgumentError("Choose a current sharing setting.") }
            try await model.manageCalendarShare(id: id, permission: permission, stop: stop, token: body["sharingToken"] as? String)
        case "withdrawSharingCalendar":
            guard !isNotch, let id = (body["calendarID"] as? String).flatMap(UUID.init(uuidString:)) else { throw CalendarToolArgumentError("Choose a published calendar.") }
            try await model.withdrawSharingCalendar(id: id, token: body["sharingToken"] as? String)
        case "sidebarWidth":
            guard !isNotch, let width = body["width"] as? Double, width.isFinite, (184...320).contains(width) else { throw CalendarToolArgumentError("Choose a sidebar width between 184 and 320 points.") }
            model.sidebarWidth = width
        case "sidebar":
            guard let expanded = body["expanded"] as? Bool else { throw CalendarToolArgumentError("Choose whether to expand the sidebar.") }
            model.sidebarExpanded = expanded
            model.scheduleAccountSync()
        case "appearance":
            guard let value = body["mode"] as? String, let mode = AppAppearance(rawValue: value) else { throw CalendarToolArgumentError("Choose Light, Dark, or System appearance.") }
            model.appearanceMode = mode
            model.scheduleAccountSync()
        case "provider":
            try requireIdle(); model.agentUseAPIKey = body["useAPIKey"] as? Bool == true
        case "agentEnabled": try requireIdle(); model.openAIAnalysisEnabled = body["enabled"] as? Bool == true
        case "copyCaptures": CaptureClipboard.automaticallyCopyCapture = body["enabled"] as? Bool == true
        case "saveAPIKey":
            try requireIdle(); try model.saveOpenAIAPIKey(body["key"] as? String ?? "")
        case "testAI": notice = try await model.testOpenAIConnection()
        case "connectChatGPT": try requireIdle(); try await model.connectChatGPT()
        case "refreshChatGPT": await model.refreshChatGPTModels()
        case "cancelChatGPT": model.cancelChatGPTSignIn()
        case "testChatGPT":
            try requireIdle()
            let client = ResponsesCalendarAgentClient()
            client.prefersAPIKey = { false }
            let result = try await client.turn(conversation: [.text(role: "user", content: "Reply with exactly: Calshot connection works.")], imageDataURL: nil, instructions: "You are testing Calshot’s ChatGPT plan connection. Reply only to the connection test.", tools: [], onText: { _ in })
            notice = "ChatGPT plan test completed: " + String(result.text.prefix(160))
        case "selectChatGPTModel":
            try requireIdle()
            guard let slug = body["model"] as? String, model.chatGPTModels.contains(where: { $0.slug == slug }) else { throw CalendarToolArgumentError("Choose a model available to your ChatGPT account.") }
            try await model.selectChatGPTModel(slug)
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
