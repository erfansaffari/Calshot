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
    /// Authority stays native: JavaScript receives only a handle and view generation.
    private struct CalendarTaskSelection {
        let snapshot: CalendarEventSnapshot
        let calendarID: String
        let fingerprint: String
        let ownerID: UUID?
        let storeURL: URL
        let taskSessionID: UUID
        let captureID: UUID?
    }
    private var calendarTaskSelections: [String: CalendarTaskSelection] = [:]
    private var calendarTaskLinkBusy = false
    private var calendarDirectActionBusy = false
    private(set) var calendarTaskNotices: [String: JSONValue] = [:]
    /// Built only from the provider receipt of the last direct Calendar change.
    private(set) var calendarChange: JSONValue = .null
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
        if !model.taskDataReady { model.loadTasks() }
        let owner = model.account.userID
        let storeURL = model.taskStore.url
        let taskSessionID = model.taskSessionID
        let captureID = model.currentCaptureSessionID
        let accessToken = model.friendAccessToken
        let id = UUID(); calendarViewRequestID = id
        calendarTaskSelections = [:]; calendarTaskNotices = [:]
        calendarView = .object(["loading": .bool(true), "loaded": .bool(false), "start": .string(ISO8601DateFormatter().string(from: start)), "end": .string(ISO8601DateFormatter().string(from: end)), "events": .array([]), "errors": .array([])])
        publish()
        var events: [JSONValue] = [], errors: [JSONValue] = []
        var truncated = false
        var selections: [String: CalendarTaskSelection] = [:]
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
                    let handle = UUID().uuidString
                    row["selectionHandle"] = .string(handle)
                    row["selectionGeneration"] = .string(id.uuidString)
                    selections[handle] = CalendarTaskSelection(snapshot: event, calendarID: calendar.id,
                        fingerprint: try CalshotModel.taskSourceFingerprint(event), ownerID: owner,
                        storeURL: storeURL, taskSessionID: taskSessionID,
                        captureID: captureID)
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
        guard calendarViewRequestID == id, model.account.userID == owner, model.friendAccessToken == accessToken,
              model.taskStore.url == storeURL, model.taskSessionID == taskSessionID, model.currentCaptureSessionID == captureID else { return }
        if events.count > 3000 { truncated = true }
        let visible = Array(events.prefix(3000))
        let handles = Set(visible.compactMap { $0.objectValue?["selectionHandle"]?.stringValue })
        calendarTaskSelections = selections.filter { handles.contains($0.key) }
        calendarView = .object(["loading": .bool(false), "loaded": .bool(true), "start": .string(ISO8601DateFormatter().string(from: start)), "end": .string(ISO8601DateFormatter().string(from: end)), "events": .array(Array(events.prefix(3000))), "errors": .array(errors), "truncated": .bool(truncated)])
    }
    private func resolveCalendarTaskSelection(handle: String?, generation: String?) throws -> CalendarTaskSelection {
        guard let handle, generation == calendarViewRequestID.uuidString,
              let selection = calendarTaskSelections[handle],
              selection.ownerID == model.account.userID, selection.storeURL == model.taskStore.url,
              selection.taskSessionID == model.taskSessionID, selection.captureID == model.currentCaptureSessionID,
              model.readableCalendars.contains(where: { $0.id == selection.calendarID && !$0.id.hasPrefix("unavailable:") }),
              !selection.calendarID.hasPrefix("shared:"), !selection.calendarID.hasPrefix("friend:") else {
            throw CalendarToolArgumentError("This event selection changed. Refresh Calendar and select it again.")
        }
        return selection
    }
    /// Exact, direct task-only mutation. This route never prepares or approves a calendar write.
    func linkCalendarEventTask(_ body: [String: Any]) async throws {
        guard !isNotch, model.workspaceSelection == .calendars else {
            throw CalendarToolArgumentError("Add events to Tasks from Calendar.")
        }
        guard Set(body.keys).isSubset(of: ["id", "action", "selectionHandle", "selectionGeneration"]) else {
            throw CalendarToolArgumentError("Use the current native event selection to add to Tasks.")
        }
        guard let handle = body["selectionHandle"] as? String else {
            throw CalendarToolArgumentError("Choose the current calendar event first.")
        }
        let selection = try resolveCalendarTaskSelection(handle: handle,
            generation: body["selectionGeneration"] as? String)
        try requireIdle()
        guard model.agentQuestion == nil, !model.agentIsWaitingForApproval, !model.calendarActions.isCheckingDuplicates else {
            throw CalendarToolArgumentError("Finish or stop the current task first.")
        }
        if !model.taskDataReady { model.loadTasks() }
        _ = try model.taskContext(origin: .workspace)
        calendarTaskLinkBusy = true
        calendarTaskNotices[handle] = .object(["status": .string("loading")])
        publish()
        defer { calendarTaskLinkBusy = false; publish() }
        do {
            let receipt = try await model.linkSelectedEventDirectly(snapshot: selection.snapshot, destinationID: selection.calendarID,
                expectedFingerprint: selection.fingerprint)
            // Do not expose a prior owner's receipt if the account changed during the native read.
            guard selection.ownerID == model.account.userID, selection.storeURL == model.taskStore.url,
                  body["selectionGeneration"] as? String == calendarViewRequestID.uuidString else { return }
            calendarTaskNotices[handle] = .object(["status": .string("success"), "receipt": WebWorkspaceState.encoded(receipt)])
        } catch {
            if selection.ownerID == model.account.userID, body["selectionGeneration"] as? String == calendarViewRequestID.uuidString {
                calendarTaskNotices[handle] = .object(["status": .string("error"), "message": .string(error.localizedDescription)])
            }
            throw error
        }
    }
    /// Applies one change the user confirmed in Calendar. No conversation or History record.
    func changeCalendarEvent(_ body: [String: Any]) async throws {
        guard !isNotch, model.workspaceSelection == .calendars else {
            throw CalendarToolArgumentError("Change calendar events from Calendar.")
        }
        guard Set(body.keys).isSubset(of: ["id", "action", "operation", "fields", "selectionHandle", "selectionGeneration", "allowDuplicate"]),
              let operation = body["operation"] as? String,
              ["create", "update", "delete"].contains(operation) else {
            throw CalendarToolArgumentError("Choose a supported calendar change.")
        }
        var allowDuplicate = false
        if let flag = body["allowDuplicate"] {
            guard operation == "create", let value = flag as? Bool, CFGetTypeID(flag as CFTypeRef) == CFBooleanGetTypeID() else {
                throw CalendarToolArgumentError("Choose a supported calendar change.")
            }
            allowDuplicate = value
        }
        try requireCalendarDirectWrite()
        calendarDirectActionBusy = true
        calendarChange = .null
        publish()
        defer { calendarDirectActionBusy = false; publish() }
        await model.recoverDirectCalendarWrites()
        var proposal: CalendarActionProposal
        let calendar: CalendarDestinationInfo
        switch operation {
        case "create":
            let fields = try directCalendarFields(body["fields"], allowed: Self.directCreateFields)
            let calendarID = try requiredString(fields, "calendarID", limit: 1024, message: "Choose an available calendar.")
            calendar = try writableCalendarInfo(calendarID)
            proposal = CalendarActionProposal(draft: try directDraft(fields, sourceText: "Direct user entry"))
            proposal.allowDuplicate = allowDuplicate
        case "update":
            guard let handle = body["selectionHandle"] as? String else {
                throw CalendarToolArgumentError("Choose the current calendar event first.")
            }
            let selection = try resolveCalendarTaskSelection(handle: handle,
                generation: body["selectionGeneration"] as? String)
            calendar = try writableCalendarInfo(selection.calendarID)
            let current = try await currentDirectEditableEvent(selection)
            let fields = try directCalendarFields(body["fields"], allowed: Self.directUpdateFields)
            var draft = try directDraft(fields, sourceText: "Direct edit of \(current.title)")
            let changed = changedFields(before: current.draft, after: draft)
            guard !changed.isEmpty else { throw CalendarToolArgumentError("Change at least one event detail before saving.") }
            draft.changedFieldNames = changed
            proposal = CalendarActionProposal(draft: draft, operation: .update,
                                              targetEventIdentifier: current.eventIdentifier,
                                              before: current.draft)
            if current.isRecurring == true { proposal.targetOccurrence = current }
        default:
            guard body["fields"] == nil || (body["fields"] is NSNull) else {
                throw CalendarToolArgumentError("Delete uses the selected event only.")
            }
            guard let handle = body["selectionHandle"] as? String else {
                throw CalendarToolArgumentError("Choose the current calendar event first.")
            }
            let selection = try resolveCalendarTaskSelection(handle: handle,
                generation: body["selectionGeneration"] as? String)
            calendar = try writableCalendarInfo(selection.calendarID)
            let current = try await currentDirectEditableEvent(selection)
            proposal = CalendarActionProposal(draft: current.draft, operation: .delete,
                                              targetEventIdentifier: current.eventIdentifier,
                                              before: current.draft)
            proposal.sourceDestinationID = calendar.id
            proposal.sourceCalendarName = calendar.title
            if current.isRecurring == true { proposal.targetOccurrence = current }
        }
        proposal.targetDestinationID = calendar.id
        proposal.targetCalendarName = calendar.title
        let result = try await model.directCalendarWriter.apply(proposal, destinationID: calendar.id, calendarName: calendar.title)
        guard let receipt = result.receipt else { throw CalendarToolArgumentError("Couldn’t confirm the change in \(calendar.title).") }
        calendarChange = .object([
            "operation": .string(operation),
            "title": .string(operation == "delete" ? (result.before?.title ?? result.draft.title) : result.draft.title),
            "calendarName": .string(receipt.calendarName),
            "thisDateOnly": .bool(result.targetOccurrence?.isRecurring == true),
        ])
    }
    private static let directCreateFields: Set<String> = ["title", "date", "allDay", "startTime", "endTime", "timeZone", "calendarID", "location", "url", "notes"]
    private static let directUpdateFields: Set<String> = ["title", "date", "allDay", "startTime", "endTime", "timeZone", "location", "url", "notes"]
    private func writableCalendarInfo(_ id: String) throws -> CalendarDestinationInfo {
        guard !id.hasPrefix("shared:"), !id.hasPrefix("friend:"),
              let calendar = model.destinations.first(where: { $0.id == id && !$0.isReadOnly && !$0.id.hasPrefix("unavailable:") }) else {
            throw CalendarToolArgumentError("Choose an available writable calendar.")
        }
        return calendar
    }
    private func currentDirectEditableEvent(_ selection: CalendarTaskSelection) async throws -> CalendarEventSnapshot {
        _ = try writableCalendarInfo(selection.calendarID)
        guard let current = try await model.calendarService.event(matching: selection.snapshot, in: .resolve(identifier: selection.calendarID)) else {
            throw CalendarToolArgumentError("This event changed or disappeared. Refresh Calendar and select it again.")
        }
        guard try CalshotModel.taskSourceFingerprint(current) == selection.fingerprint else {
            throw CalendarToolArgumentError("This event changed after you opened it. Refresh Calendar and select it again.")
        }
        return current
    }
    private func directCalendarFields(_ value: Any?, allowed: Set<String>) throws -> [String: Any] {
        guard let fields = value as? [String: Any],
              Set(fields.keys).isSubset(of: allowed) else {
            throw CalendarToolArgumentError("Use the supported calendar fields.")
        }
        return fields
    }
    private func requiredString(_ fields: [String: Any], _ key: String, limit: Int, message: String) throws -> String {
        guard let value = fields[key] as? String else { throw CalendarToolArgumentError(message) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit else { throw CalendarToolArgumentError(message) }
        return trimmed
    }
    private func optionalString(_ fields: [String: Any], _ key: String, limit: Int) throws -> String? {
        guard let value = fields[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw CalendarToolArgumentError("Use text for \(key).") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= limit else { throw CalendarToolArgumentError("Keep \(key) under \(limit) characters.") }
        return trimmed.isEmpty ? nil : trimmed
    }
    private func directDraft(_ fields: [String: Any], sourceText: String) throws -> EventDraft {
        let title = try requiredString(fields, "title", limit: 500, message: "Enter an event title up to 500 characters.")
        let day = try requiredString(fields, "date", limit: 10, message: "Choose the event date.")
        let zoneID = try requiredString(fields, "timeZone", limit: 128, message: "Choose a valid time zone.")
        guard let timeZone = TimeZone(identifier: zoneID) else {
            throw CalendarToolArgumentError("Choose a valid time zone, such as America/Toronto.")
        }
        guard let allDayRaw = fields["allDay"], let allDay = allDayRaw as? Bool,
              CFGetTypeID(allDayRaw as CFTypeRef) == CFBooleanGetTypeID() else {
            throw CalendarToolArgumentError("Choose all-day or a start and end time.")
        }
        let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian); dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"; dateFormatter.isLenient = false
        guard let date = dateFormatter.date(from: day), dateFormatter.string(from: date) == day else {
            throw CalendarToolArgumentError("Choose the event date.")
        }
        let start: Date
        let end: Date
        if allDay {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            start = calendar.startOfDay(for: date)
            end = calendar.date(byAdding: .day, value: 1, to: start)!
        } else {
            let startText = try requiredString(fields, "startTime", limit: 5, message: "Choose a start time.")
            let endText = try requiredString(fields, "endTime", limit: 5, message: "Choose a later end time.")
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"; formatter.isLenient = false
            guard let parsedStart = formatter.date(from: day + "T" + startText),
                  let parsedEnd = formatter.date(from: day + "T" + endText),
                  parsedEnd > parsedStart,
                  formatter.string(from: parsedStart) == day + "T" + startText,
                  formatter.string(from: parsedEnd) == day + "T" + endText else {
                throw CalendarToolArgumentError("Choose valid start and end times, with the end after the start.")
            }
            start = parsedStart; end = parsedEnd
        }
        let urlText = try optionalString(fields, "url", limit: 2048)
        let url = urlText.flatMap(URL.init(string:))
        guard urlText == nil || (url?.host != nil && ["http", "https"].contains(url?.scheme?.lowercased() ?? "")) else {
            throw CalendarToolArgumentError("Enter a valid https or http link.")
        }
        return EventDraft(title: title, startDate: start, endDate: end, isAllDay: allDay,
                          timeZoneIdentifier: zoneID,
                          location: try optionalString(fields, "location", limit: 500),
                          url: url,
                          notes: try optionalString(fields, "notes", limit: 8000),
                          sourceText: sourceText, confidence: 1, ambiguities: [])
    }
    private func changedFields(before: EventDraft, after: EventDraft) -> [String] {
        var fields: [String] = []
        if before.title != after.title { fields.append("title") }
        if before.startDate != after.startDate { fields.append(before.isAllDay || after.isAllDay ? "date" : "startTime") }
        if before.endDate != after.endDate { fields.append(before.isAllDay || after.isAllDay ? "date" : "endTime") }
        if before.isAllDay != after.isAllDay { fields.append("allDay") }
        if before.timeZoneIdentifier != after.timeZoneIdentifier { fields.append("timeZone") }
        if before.location != after.location { fields.append("location") }
        if before.url != after.url { fields.append("url") }
        if before.notes != after.notes { fields.append("notes") }
        return Array(Set(fields)).sorted()
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
        googleReady = true
    }
    func publish() {
        guard ready else { return }
        if wasConnecting && !model.calendarAccountIsConnecting { refreshAccounts() }
        wasConnecting = model.calendarAccountIsConnecting
        let friendToken = model.friendAccessToken
        if lastFriendAccessToken != friendToken {
            lastFriendAccessToken = friendToken
            calendarViewRequestID = UUID()
            calendarTaskSelections = [:]; calendarTaskNotices = [:]
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
        viewState["calendarTaskNotices"] = model.account.canUseWorkspace ? .object(calendarTaskNotices) : .object([:])
        viewState["calendarChange"] = model.account.canUseWorkspace ? calendarChange : .null
        viewState["directWriteNotice"] = model.directWriteNotice.map(JSONValue.string) ?? .null
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
        guard !calendarTaskLinkBusy, !calendarDirectActionBusy, !model.isSaving, !model.isCapturing, !model.agentIsRunning, !model.isRecognizing else { throw CalendarToolArgumentError("Finish or stop the current task first.") }
    }
    /// An open conversation doesn't block your own edits; the coordinator rejects any row it makes stale.
    private func requireCalendarDirectWrite() throws {
        guard model.account.canUseWorkspace else { throw CalendarToolArgumentError("Sign in and connect a calendar first.") }
        guard !calendarTaskLinkBusy, !calendarDirectActionBusy, !model.isSaving, !model.directCalendarWriter.isWriting else {
            throw CalendarToolArgumentError("Wait for the current save to finish.")
        }
    }
    private func resetConversation() {
        model.analysisTask?.cancel(); model.analysisTask = nil; model.ocrTask?.cancel(); model.ocrTask = nil
        model.selectedEventContext = nil
        model.activeAgentRunID = nil; model.agentCommand = ""
        comparisons = [:]; model.currentCaptureSessionID = UUID(); model.currentMemoryRecordID = nil
        model.image = nil; model.previousCaptureImage = nil; model.recognizedText = ""
        model.screenRecognition = ScreenTextRecognition(lines: []); model.currentAgentSourceID = nil
        model.agentMessages = []; model.agentTranscriptPrefix = []
        model.agentSummary = nil; model.agentStreamingText = ""; model.agentError = nil; model.agentStatus = nil; model.status = nil
        model.agentRetryPrompt = nil; model.calendarActions.replace(with: []); model.workspaceSelection = .chat
        model.cancelAgentTaskReview(reason: "New task."); model.agentTaskOutcome = nil
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
           ["refreshCalendars", "connectGoogle", "selectCalendar", "calendarSettings", "internetAccountsSettings"].contains(action) {
            throw CalendarToolArgumentError("Set up your AI service before confirming calendars.")
        }
        switch action {
        case "startVoice", "stopVoice", "setVoiceDrawing", "acknowledgeVoiceBilling", "voiceSettings", "voiceMicrophoneSettings", "voiceShortcut", "voiceAISettings", "voiceShortcutRecording":
            let voice = model.voiceSession
            var fields: Set<String> = ["action", "id", "token"]
            if action == "setVoiceDrawing" { fields.insert("drawing") }
            if action == "voiceShortcutRecording" { fields.insert("enabled") }
            if action == "voiceSettings" { fields.formUnion(["model", "voice", "cap"]) }
            if action == "voiceShortcut" { fields.formUnion(["keyCode", "modifiers", "label"]) }
            guard Set(body.keys).isSubset(of: fields) else { throw CalendarToolArgumentError("Invalid voice control.") }
            guard body["token"] as? String == voice.token else { throw CalendarToolArgumentError("Voice controls changed. Try again.") }
            if action == "voiceAISettings" { settingsSection = "ai"; model.openSettings() }
            else if action == "startVoice" { guard model.account.canUseWorkspace else { throw CalendarToolArgumentError("Sign in and finish onboarding to use voice.") }; await voice.toggle() }
            else if action == "stopVoice" { voice.stop() }
            else if action == "setVoiceDrawing" { guard let raw = body["drawing"], CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID(), let drawing = raw as? Bool else { throw CalendarToolArgumentError("Choose a drawing state.") }; voice.setDrawing(drawing) }
            else if action == "acknowledgeVoiceBilling" { voice.acknowledge() }
            else if action == "voiceMicrophoneSettings" { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
            else {
                guard !isNotch, model.workspaceSelection == .settings, !voice.active else { throw CalendarToolArgumentError("Stop voice and change its preferences in Settings.") }
                if action == "voiceShortcutRecording" {
                    guard let value = body["enabled"], CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let enabled = value as? Bool else { throw CalendarToolArgumentError("Choose a recording state.") }
                    model.setShortcutRecording(enabled)
                    return
                } else if action == "voiceShortcut" {
                    guard let code = body["keyCode"] as? UInt32, code < 128, let modifiers = body["modifiers"] as? UInt32, modifiers > 0, modifiers & ~UInt32(0x1F00) == 0,
                          let label = body["label"] as? String, (1...40).contains(label.count), code != model.shortcut.keyCode || modifiers != model.shortcut.modifiers else { throw CalendarToolArgumentError("Choose a different modified shortcut.") }
                    model.voiceShortcut = GlobalShortcut(keyCode: code, modifiers: modifiers, label: label)
                    model.setShortcutRecording(false)
                } else {
                    guard let name = body["model"] as? String, (1...100).contains(name.count), name.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil,
                          let selectedVoice = body["voice"] as? String, ["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse", "marin", "cedar"].contains(selectedVoice),
                          let cap = body["cap"] as? Double, cap.isFinite, (0...10000).contains(cap) else { throw CalendarToolArgumentError("Choose a valid voice, model and monthly cap ($0–10,000).") }
                    voice.defaults.set(name, forKey: "voice.model"); voice.defaults.set(selectedVoice, forKey: "voice.voice"); voice.defaults.set(cap, forKey: "voice.cap")
                }
                voice.invalidateControls()
            }
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
            model.cancelCalendarConnection()
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
            if model.isRecordingShortcut { model.setShortcutRecording(false) }
            guard let raw = body["page"] as? String, let page = WorkspaceSection(rawValue: raw) else { return }
            if page == .settings {
                let section = body["section"] as? String ?? "general"
                guard ["general", "calendars", "friends", "ai", "voice", "privacy"].contains(section) else { throw CalendarToolArgumentError("Unknown settings section.") }
                settingsSection = section
            }
            model.workspaceSelection = page
            if page == .settings && settingsSection == "friends" { Task { await model.refreshSharing() } }
            if page == .tasks { model.loadTasks(); Task { await model.recoverDirectCalendarWrites(); await model.syncTasks() } }
            if page == .library { model.refreshMemory() }
            if page == .settings && ["privacy", "ai"].contains(settingsSection) && !isNotch { Task { _ = try? await model.openAgentPermissionStore() } }
            if page == .calendars || (page == .settings && settingsSection == "calendars") {
                Task { await model.loadCalendars(); refreshAccounts(); if page == .calendars { await model.recoverDirectCalendarWrites() } }
            }
        case "saveTask":
            guard !isNotch, model.workspaceSelection == .tasks else { throw CalendarToolArgumentError("Manage tasks on the Tasks page.") }
            try await model.saveTask(body)
        case "completeTask", "reorderTask", "archiveTask":
            guard !isNotch, model.workspaceSelection == .tasks else { throw CalendarToolArgumentError("Manage tasks on the Tasks page.") }
            try model.changeTask(body)
        case "publishTaskDeadline":
            guard !isNotch, model.workspaceSelection == .tasks else { throw CalendarToolArgumentError("Open Tasks to update this deadline.") }
            try model.validateTaskAction(body)
            guard Set(body.keys).isSubset(of: ["id", "action", "token", "taskID", "allowDuplicate"]),
                  let raw = body["taskID"] as? String, let id = UUID(uuidString: raw) else { throw CalendarToolArgumentError("Choose a task.") }
            var allowDuplicate = false
            if let flag = body["allowDuplicate"] {
                guard let value = flag as? Bool, CFGetTypeID(flag as CFTypeRef) == CFBooleanGetTypeID() else { throw CalendarToolArgumentError("Choose a task.") }
                allowDuplicate = value
            }
            await model.publishTaskDeadline(id, allowDuplicate: allowDuplicate)
        case "deleteTask":
            guard !isNotch, model.workspaceSelection == .tasks else { throw CalendarToolArgumentError("Manage tasks on the Tasks page.") }
            try await model.deleteTask(body)
        case "syncTasks", "keepTaskCopies":
            guard !isNotch, model.workspaceSelection == .tasks else { throw CalendarToolArgumentError("Sync tasks on the Tasks page.") }
            try model.validateTaskAction(body); await model.syncTasks(keepBoth: action == "keepTaskCopies")
        case "reloadTasks":
            guard !isNotch, model.workspaceSelection == .tasks else { throw CalendarToolArgumentError("Open Tasks first.") }; try requireIdle(); model.loadTasks()
        case "taskNotificationSettings":
            guard !isNotch, model.workspaceSelection == .tasks else { throw CalendarToolArgumentError("Open Tasks first.") }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
        case "approveTaskChange", "cancelTaskChange":
            // Task-only review. Allowed in the notch; never prepares or approves a calendar write.
            guard Set(body.keys).isSubset(of: ["id", "action", "reviewID", "token", "digest"]),
                  let reviewID = (body["reviewID"] as? String).flatMap(UUID.init(uuidString:)), let token = body["token"] as? String else {
                throw CalendarToolArgumentError("This task review is no longer current.")
            }
            if action == "approveTaskChange" {
                guard let digest = body["digest"] as? String else { throw CalendarToolArgumentError("This task review is no longer current.") }
                try model.approveAgentTaskReview(id: reviewID, token: token, digest: digest)
            } else { try model.declineAgentTaskReview(id: reviewID, token: token) }
        case "loadAgentPermissions":
            guard !isNotch, model.workspaceSelection == .settings else { throw CalendarToolArgumentError("Task permissions are in Settings.") }
            _ = try await model.openAgentPermissionStore()
        case "saveAgentPermissions":
            guard !isNotch, model.workspaceSelection == .settings else { throw CalendarToolArgumentError("Change task permissions in Settings.") }
            try requireIdle()
            guard Set(body.keys).isSubset(of: ["id", "action", "revision", "families", "days", "renew"]),
                  let revisionNumber = body["revision"] as? NSNumber, CFGetTypeID(revisionNumber) != CFBooleanGetTypeID(), revisionNumber.int64Value >= 0,
                  let days = body["days"] as? Int, let raw = body["families"] as? [String: Any] else {
                throw CalendarToolArgumentError("Choose valid task permissions.")
            }
            var families: [String: Bool] = [:]
            for (key, value) in raw {
                guard let flag = value as? Bool, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { throw CalendarToolArgumentError("Choose valid task permissions.") }
                families[key] = flag
            }
            let renew = (body["renew"] as? Bool) == true && CFGetTypeID((body["renew"] ?? false) as CFTypeRef) == CFBooleanGetTypeID()
            try await model.saveAgentTaskPermissions(revision: UInt64(revisionNumber.int64Value), families: families, days: days, renew: renew)
        case "linkCalendarEventTask": try await linkCalendarEventTask(body)
        case "changeCalendarEvent": try await changeCalendarEvent(body)
        case "dismissCalendarChange": calendarChange = .null
        case "dismissDirectWriteNotice": model.directWriteNotice = nil
        case "loadCalendarEvents": try await loadCalendarView(body)
        case "dismissNotice": notice = nil
        case "capture":
            guard !model.isSaving, !model.isCapturing else { throw CalendarToolArgumentError("Wait for the current action to finish.") }
            model.taskUsesNotch = isNotch
            Task { await model.capture(quick: isNotch, appendToBatch: body["append"] as? Bool == true, askAfterCapture: isNotch) }
        case "startCalendarTask":
            guard !isNotch, model.workspaceSelection == .calendars else { throw CalendarToolArgumentError("Start calendar questions from Calendar.") }
            guard Set(body.keys).isSubset(of: ["id", "action", "text", "eventHandle", "viewToken"]) else { throw CalendarToolArgumentError("Unsupported calendar question fields.") }
            let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 8000 else { throw CalendarToolArgumentError("Enter a message up to 8,000 characters.") }
            try requireIdle()
            guard model.agentQuestion == nil, !model.agentIsWaitingForApproval, !model.calendarActions.isCheckingDuplicates else { throw CalendarToolArgumentError("Finish or stop the current task first.") }
            let selection: CalendarTaskSelection?
            if body["eventHandle"] != nil || body["viewToken"] != nil {
                selection = try resolveCalendarTaskSelection(handle: body["eventHandle"] as? String, generation: body["viewToken"] as? String)
            } else { selection = nil }
            let record = try selection.map { _ in try model.memoryStore.recordCommand(text) }
            resetConversation()
            if let selection, let record, let captureID = model.currentCaptureSessionID {
                model.currentMemoryRecordID = record.id
                model.selectedEventContext = CalshotSelectedEventContext(ownerID: selection.ownerID, storeURL: selection.storeURL,
                    snapshot: selection.snapshot, destinationID: selection.calendarID, fingerprint: selection.fingerprint,
                    recordID: record.id, captureID: captureID)
                model.refreshMemory()
            }
            model.taskUsesNotch = false
            let sessionID = model.currentCaptureSessionID
            Task { [weak model] in
                guard let model, model.currentCaptureSessionID == sessionID else { return }
                await model.startAgentCommand(prompt: text, expectedSessionID: sessionID)
            }
        case "importCapturedScreenshot":
            guard isNotch, model.image != nil, model.currentCaptureSessionID != nil,
                  Set(body.keys).isSubset(of: ["id", "action"]) else {
                throw CalendarToolArgumentError("Capture a screenshot in the notch before importing it.")
            }
            try requireIdle()
            guard model.agentQuestion == nil, !model.agentIsWaitingForApproval, model.agentTaskReview == nil else {
                throw CalendarToolArgumentError("Finish or stop the current task first.")
            }
            model.taskUsesNotch = true
            let sessionID = model.currentCaptureSessionID
            Task { [weak model] in
                await model?.startAgentCommand(prompt: CalendarAgent.screenshotPrompt, expectedSessionID: sessionID, isTypedRequest: false)
            }
            onNotchCollapse?()
        case "send":
            let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 8000 else { throw CalendarToolArgumentError("Enter a message up to 8,000 characters.") }
            if let question = model.agentQuestion {
                guard body["questionID"] as? String == question.id.uuidString else { throw CalendarToolArgumentError("This question changed. Answer the current question.") }
                model.answerAgentQuestion(text)
            } else {
                try requireIdle(); model.taskUsesNotch = isNotch
                Task { await model.startAgentCommand(prompt: text) }
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
        case "selectInboxTaskImport":
            try requireReview(body)
            guard model.taskImportIsCurrent, let id=(body["taskID"] as? String).flatMap(UUID.init(uuidString:)), let selected=body["selected"] as? Bool,
                  CFGetTypeID(body["selected"] as CFTypeRef)==CFBooleanGetTypeID(), model.taskImport?.items.contains(where:{$0.id==id && $0.dueDate==nil}) == true else { throw CalendarToolArgumentError("This task import is no longer current.") }
            if selected { model.taskImport?.selectedInboxIDs.insert(id) } else { model.taskImport?.selectedInboxIDs.remove(id) }
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
            guard (model.taskImport != nil ? model.canApproveTaskImport : model.calendarActions.canApprove) else { throw CalendarToolArgumentError("Select ready events and an available destination first.") }
            if isNotch { onNotchCollapse?() }
            await model.saveEvents()
        case "skipApproval":
            try requireReview(body)
            if model.agentIsWaitingForApproval { model.skipAgentApproval() } else { model.calendarActions.skipAll() }
        case "editProposal": try edit(body)
        case "retryAgent": try requireIdle(); model.taskUsesNotch = isNotch; Task { await model.retryAgentCommand() }
        case "addMemory", "editMemory", "forgetMemory", "approveMemory", "rejectMemory", "clearMemory":
            try model.handlePersonalMemoryAction(action, body: body, isNotch: isNotch)
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
            model.connectCalendarAccount(.google, clientID: CalendarAccountConnection.googleClientID)
        case "cancelConnection": model.cancelCalendarConnection()
        case "disconnectAccount":
            try requireIdle()
            guard let id = (body["accountID"] as? String).flatMap(UUID.init(uuidString:)) else { return }
            await model.disconnectCalendarAccount(id); refreshAccounts()
        case "screenSettings": model.openScreenCaptureSettings()
        case "internetAccountsSettings":
            try requireIdle()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.internetaccounts")!)
            model.calendarAccountError = false
            model.calendarAccountMessage = "Choose Google in Internet Accounts, turn on Calendars, then return to Calshot and refresh your calendars."
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
        case "notchEnabled":
            guard !isNotch, let enabled = body["enabled"] as? Bool else { throw CalendarToolArgumentError("Turn the notch on or off in Settings.") }
            model.notchEnabled = enabled
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
        if row.draft.taskID != nil, fields["allDay"] as? Bool != true { throw CalendarToolArgumentError("Task deadlines stay all-day and free. Edit the exact due time on Tasks.") }
        model.calendarActions.edit(id) { draft in
            draft.title = title; draft.startDate = start; draft.endDate = end; draft.isAllDay = fields["allDay"] as? Bool == true
            draft.timeZoneIdentifier = zone; draft.location = fields["location"] as? String; draft.url = url; draft.notes = fields["notes"] as? String
            if draft.isAllDay {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
                draft.startDate = calendar.startOfDay(for: start)
                let endDay = calendar.startOfDay(for: end)
                draft.endDate = endDay > draft.startDate! ? endDay : calendar.date(byAdding: .day, value: 1, to: draft.startDate!)
            }
            if draft.taskID != nil {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
                draft.endDate = calendar.date(byAdding: .day, value: 1, to: draft.startDate!)
                if let dueTime = draft.taskDeadlineTime {
                    let suffix = " · due " + dueTime
                    if !draft.title.hasSuffix(suffix) { draft.title += suffix }
                }
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
