import AppKit
import Carbon.HIToolbox
import Security
import ScreenCaptureKit
import SwiftUI
import Combine

@main
struct CalshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Calshot", systemImage: "viewfinder") {
            MenuBarView(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appSettings) {
                SoftwareUpdateMenuItem(controller: appDelegate.model.softwareUpdates)

                Button("Open Quick Menu") {
                    appDelegate.model.showNotchLauncher()
                    appDelegate.model.notchLauncherController?.openQuickMenu()
                }.keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: CalshotModel = {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--sharing-preview") { return CalshotModel.sharingPreviewModel() }
        if ProcessInfo.processInfo.arguments.contains("--calendar-agent-demo") {
            return CalshotModel(calendarService: CalendarDemoService(), memoryStore: MemoryStore(directoryURL:
                FileManager.default.temporaryDirectory.appendingPathComponent("CalshotCalendarDemo")), loadsAIConnection: false,
                agentClient: CalendarAgentDemoClient())
        }
        if ProcessInfo.processInfo.arguments.contains("--calendar-demo") {
            return CalshotModel(calendarService: CalendarDemoService(), memoryStore: MemoryStore(directoryURL:
                FileManager.default.temporaryDirectory.appendingPathComponent("CalshotCalendarDemo")), loadsAIConnection: false)
        }
#endif
        return CalshotModel()
    }()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        model.appearanceMode.apply()
        if NSClassFromString("XCTestCase") == nil { model.softwareUpdates.start() }
        HotKeyController.shared.onPress = { [weak model = self.model] in
            Task { @MainActor in
                model?.taskUsesNotch = true
                await model?.capture(quick: true, askAfterCapture: true)
            }
        }
        model.registerShortcut()

        DispatchQueue.main.async { [weak self] in
            self?.model.showNotchLauncher()
            self?.model.openPanel()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--calendar-demo") || ProcessInfo.processInfo.arguments.contains("--calendar-agent-demo") { self?.model.loadCalendarDemo() }
            if ProcessInfo.processInfo.arguments.contains("--calendar-agent-demo") {
                self?.model.calendarActions.replace(with: [])
                self?.model.agentCommand = "Read this syllabus and add its deadlines and exams."
                Task { await self?.model.startAgentCommand() }
            }
#endif
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.softwareUpdates.hasPendingInstallation || model.softwareUpdates.installing || model.softwareUpdates.updater?.sessionInProgress == true else { return .terminateNow }
        guard model.canRestartForSoftwareUpdate else {
            model.softwareUpdates.explainDeferredQuit()
            model.openPanel()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        model.showNotchLauncher()
        if !hasVisibleWindows { model.openPanel() }
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "calshot" {
            model.openPanel()
            Task { await model.account.handleCallback(url) }
        }
    }

}

@MainActor
final class CalshotModel: ObservableObject {
    let softwareUpdates: SoftwareUpdateController
    private var updateObservation: AnyCancellable?
    let account: CalshotAccountService
    private var accountObservation: AnyCancellable?
    @Published var appearanceMode: AppAppearance = .saved {
        didSet {
            if persistsAISelection {
                UserDefaults.standard.set(appearanceMode.rawValue, forKey: AppAppearance.defaultsKey)
            }
            appearanceMode.apply()
        }
    }
    @Published var sidebarExpanded = UserDefaults.standard.object(forKey: "sidebarExpanded") as? Bool ?? true {
        didSet { if persistsAISelection { UserDefaults.standard.set(sidebarExpanded, forKey: "sidebarExpanded") } }
    }
    @Published var sidebarWidth = min(320, max(184, UserDefaults.standard.object(forKey: "sidebarWidth") as? Double ?? 228)) {
        didSet { if persistsAISelection { UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth") } }
    }
    var captureAsksForCommand = false
    @Published var image: NSImage?
    @Published var recognizedText = ""
    @Published var agentStatus: String?
    @Published var agentSummary: String?
    @Published var agentMessages: [AgentTurn] = []
    @Published var agentStreamingText = ""
    @Published var agentError: String?
    @Published var agentRetryPrompt: String?
    @Published var agentUseAPIKey = false {
        didSet { if persistsAISelection { UserDefaults.standard.set(agentUseAPIKey, forKey: "agentUseAPIKey") } }
    }
    private var persistsAISelection = true
    @Published var agentIsRunning = false
    @Published var agentIsWaitingForApproval = false
    @Published var agentQuestion: AgentQuestion?
    @Published var agentCommand = ""
    var calendarAgent: CalendarAgent?
    var agentToolExecutor: CalendarAgentToolExecutor?
    var agentSubscriptions = Set<AnyCancellable>()
    var activeAgentRunID: UUID?
    var agentTranscriptPrefix: [AgentTurn] = []
    var currentAgentPrompt = ""
    var currentAgentSourceID: UUID?
    var screenRecognition = ScreenTextRecognition(lines: [])
    var ocrTask: Task<ScreenTextRecognition, Error>?
    var ocrObserverTask: Task<Void, Never>?
    let agentClient: (any CalendarAgentModelClient)?
    let calendarActions: CalendarActionCoordinator
    @Published var isCapturing = false
    @Published var isRecognizing = false
    @Published var status: String?
    @Published var screenCapturePermissionNeeded = false
    var screenPermissionWindow: NSWindowController?
    var workspaceWindowController: WorkspaceWindowController?
    var taskUsesNotch = false
    var notchLauncherController: NotchExperienceController?
    @Published var workspaceSelection: WorkspaceSection = .capture
    @Published var selectionOverlay: RegionSelectionOverlay?
    @Published var destinations: [CalendarDestinationInfo] = []
    @Published var readableCalendars: [CalendarDestinationInfo] = []
    var persistsCalendarSelection = true
    @Published var calendarAccountMessage: String?
    @Published var calendarAccountIsConnecting = false
    @Published var connectingCalendarProvider: CalendarAccountConnection.Provider?
    @Published var calendarAccountError = false
    var calendarConnectionTask: Task<Void, Never>?
    @Published var calendarConnectionMessage: String?
    @Published var selectedCalendarID: String? {
        didSet { if persistsCalendarSelection { UserDefaults.standard.set(selectedCalendarID, forKey: "selectedCalendarID") } }
    }
    var isSaving: Bool { calendarActions.isExecuting }
    @Published var saveMessage: String?
    @Published var hasOpenAIAPIKey = false
    @Published var chatGPTAccount: ChatGPTConnection.Account?
    @Published var chatGPTConnectionError: String?
    @Published var chatGPTModels: [ChatGPTConnection.ModelOption] = []
    @Published var chatGPTUsage: [ChatGPTConnection.UsageRecord] = CalshotModel.loadChatGPTUsage()
    @Published var openAIAnalysisEnabled = UserDefaults.standard.bool(forKey: "openAIAnalysisEnabled") {
        didSet { UserDefaults.standard.set(openAIAnalysisEnabled, forKey: "openAIAnalysisEnabled") }
    }
    @Published var analyzedWithOpenAI = false
    @Published var shortcut: GlobalShortcut = CalshotModel.loadShortcut() {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) {
                UserDefaults.standard.set(data, forKey: "globalShortcut")
            }
            if !isRecordingShortcut { registerShortcut() }
        }
    }
    @Published var shortcutRegistrationStatus: OSStatus = -1
    @Published var isRecordingShortcut = false
    @Published var memoryRecords: [MemoryCaptureRecord] = []
    @Published var memoryRecordToOpen: UUID?
    @Published var memoryLocationMessage: String?
    @Published var lastAnalysisProvider: String?
    @Published var lastOCRStatus = "No OCR run yet"
    @Published var lastCaptureSummary = "No capture yet"
    let calendarService: any CalendarDestinationService
    var memoryStore: MemoryStore
    var activeLocalAccountID: UUID?
    var accountMemoryRoot: MemoryStore
    var accountSyncTask: Task<Void, Never>?
    var accountSyncTimer: Timer?
    @Published var accountSyncBusy = false
    @Published var accountSyncStatus = "Not synced yet"
    @Published var accountSyncError: String?
    @Published var accountSyncLastDate: Date?
    @Published var accountSyncDevices: [String: AccountSyncDevice] = [:]
    @Published var accountDisplayName = ""
    @Published var macCalendarMirrors: [MacCalendarMirror] = []
    @Published var macCalendarSyncBusy = false
    @Published var macCalendarSyncError: String?
    var macCalendarRPC: ((String, JSONValue, UUID) async throws -> JSONValue)?
    @Published var calendarSharing = CalendarSharingState()
    @Published var sharingLoaded = false
    @Published var sharingBusy = false
    @Published var sharingError: String?
    var sharingRPC: ((String, JSONValue, UUID) async throws -> JSONValue)?
    private var calendarObservation: AnyCancellable?
    var currentMemoryRecordID: UUID?
    var currentCaptureSessionID: UUID?
    private var shortcutSuspendedForSelection = false
    private var currentCaptureIsQuick = false
    var isAppendingCapture = false
    var previousCaptureImage: NSImage?
    var analysisTask: Task<Void, Never>?

    init(calendarService: any CalendarDestinationService = ConnectedCalendarService(), memoryStore: MemoryStore = .shared, loadsAIConnection: Bool = true, agentClient: (any CalendarAgentModelClient)? = nil) {
        softwareUpdates = SoftwareUpdateController(enabled: loadsAIConnection)
        account = CalshotAccountService(enabled: loadsAIConnection)
        persistsCalendarSelection = loadsAIConnection
        persistsAISelection = loadsAIConnection
        if loadsAIConnection { agentUseAPIKey = UserDefaults.standard.bool(forKey: "agentUseAPIKey") }
        self.agentClient = agentClient
        self.calendarService = calendarService
        self.memoryStore = memoryStore
        self.accountMemoryRoot = memoryStore
        calendarActions = CalendarActionCoordinator(service: calendarService)
        calendarActions.persist = { [weak self] items in
            guard let self, let id = self.currentMemoryRecordID,
                  try self.memoryStore.updateProposals(for: id, proposals: items) != nil else {
                throw CalendarDestinationError.invalidDraft("capture history is unavailable; retake the screenshot before saving")
            }
            self.refreshMemory()
        }
        softwareUpdates.canRestart = { [weak self] in self?.canRestartForSoftwareUpdate == true }
        updateObservation = softwareUpdates.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        calendarObservation = calendarActions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        accountObservation = account.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        account.onShowWindow = { [weak self] in self?.openPanel() }
        account.onAuthenticated = { [weak self] provider in
            Task { @MainActor in
                guard let self, let signedInUser = self.account.userID else { return }
                if self.activeLocalAccountID != signedInUser {
                    self.cancelCalendarConnection()
                    self.stopAgent(); self.analysisTask?.cancel(); self.ocrTask?.cancel()
                    self.activeAgentRunID = nil; self.currentCaptureSessionID = UUID(); self.currentMemoryRecordID = nil
                    self.image = nil; self.recognizedText = ""; self.agentMessages = []; self.agentTranscriptPrefix = []
                    self.agentSummary = nil; self.agentStreamingText = ""; self.agentError = nil; self.agentStatus = nil
                    self.calendarActions.replace(with: [])
                    self.accountSyncDevices = [:]; self.accountSyncLastDate = nil
                    self.macCalendarMirrors = []; self.macCalendarSyncError = nil
                    self.calendarSharing = CalendarSharingState(); self.sharingLoaded = false; self.sharingBusy = false; self.sharingError = nil
                }
                do {
                    self.memoryStore = try self.accountMemoryRoot.accountStore(for: signedInUser)
                    self.activeLocalAccountID = signedInUser
                    self.refreshMemory()
                } catch { self.accountSyncError = "Couldn’t open this account’s local history. Sync has not started."; return }
                if self.account.onboarded || self.account.aiSetupConfirmed { await self.loadCalendars() }
                guard self.account.userID == signedInUser else { return }
                self.startAccountSync()
                self.openPanel()

            }
        }
        if loadsAIConnection { selectedCalendarID = UserDefaults.standard.string(forKey: "selectedCalendarID") }
        guard loadsAIConnection else { return }
        let calendarAccount = account
        Task {
            await CalendarAccountConnection.shared.configureGoogleTokenExchange { fields in
                try await calendarAccount.exchangeGoogleCalendarToken(fields)
            }
        }
        hasOpenAIAPIKey = (try? OpenAIAPIKeyStore.load()) != nil
        chatGPTAccount = ChatGPTConnection.savedAccount()
        if chatGPTAccount?.canUsePlan == true {
            Task { [weak self] in
                guard let self else { return }
                do {
                    self.chatGPTAccount = try await ChatGPTConnection.shared.refreshPreferredModel()
                    self.chatGPTConnectionError = nil
                } catch { self.chatGPTAccount = ChatGPTConnection.savedAccount(); self.chatGPTConnectionError = error.localizedDescription }
            }
        }
    }

    func openPanel() {
        if workspaceWindowController == nil { workspaceWindowController = WorkspaceWindowController(model: self) }
        workspaceWindowController?.show()
    }

    func presentTask(compact: Bool = false) {
        if taskUsesNotch {
            showNotchLauncher()
            // Task updates may notify, but only hover or an explicit quick-menu
            // command may reveal the panel or take keyboard focus.
            if compact { notchLauncherController?.collapse() }
        }
        else { openPanel() }
    }

    func showNotchLauncher() {
        if notchLauncherController == nil {
            notchLauncherController = NotchExperienceController(model: self)
        }
        notchLauncherController?.show()
    }

    func openSettings() {
        workspaceSelection = .settings
        openPanel()
    }

    func registerShortcut() {
        shortcutRegistrationStatus = HotKeyController.shared.register(shortcut)
    }

    func setShortcutRecording(_ recording: Bool) {
        guard isRecordingShortcut != recording else { return }
        isRecordingShortcut = recording
        if recording {
            HotKeyController.shared.unregister()
        } else {
            registerShortcut()
        }
    }

    func updateShortcut(_ newShortcut: GlobalShortcut) {
        shortcut = newShortcut
    }

    func testOpenAIConnection(using draftKey: String? = nil) async throws -> String {
        let key = draftKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? draftKey : try OpenAIAPIKeyStore.load()
        guard let key else { throw OpenAIEventAnalyzer.AnalyzerError.apiError(statusCode: 0, message: "Save an API key first.") }
        return try await OpenAIEventAnalyzer.testConnection(apiKey: key)
    }

    func refreshMemory() { memoryRecords = memoryStore.listRecords(); scheduleAccountSync() }

    var memoryDirectoryURL: URL { memoryStore.locationURL }

    func revealMemoryFolder() {
        do {
            try FileManager.default.createDirectory(at: memoryStore.locationURL,
                                                    withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([memoryStore.locationURL])
            memoryLocationMessage = nil
        } catch {
            memoryLocationMessage = "Couldn’t open the Memory folder: \(error.localizedDescription)"
        }
    }

    func chooseMemoryLocation() {
        let picker = NSOpenPanel()
        picker.title = "Choose a folder for Calshot Memory"
        picker.message = "Calshot will create a Calshot/Memory folder here and move your capture history into it."
        picker.prompt = "Choose Folder"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.begin { [weak self] response in
            guard response == .OK, let parent = picker.url else { return }
            Task { @MainActor in self?.moveMemory(toParentFolder: parent) }
        }
    }

    private func moveMemory(toParentFolder parent: URL) {
        let destination = parent.appendingPathComponent("Calshot", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
        do {
            try memoryStore.move(to: destination)
            accountMemoryRoot = MemoryStore(directoryURL: memoryStore.locationURL)
            refreshMemory()
            memoryLocationMessage = "Memory moved to \(destination.path)"
        } catch {
            memoryLocationMessage = "Couldn’t move Memory: \(error.localizedDescription)"
        }
    }

    func deleteMemoryRecord(_ id: UUID) {
        guard !isSaving else { return }
        do { try memoryStore.deleteRecord(id: id); refreshMemory() }
        catch { status = "Couldn’t delete capture history: \(error.localizedDescription)" }
    }

    func deleteAllMemory() {
        guard !isSaving else { return }
        do { try memoryStore.deleteAll(); refreshMemory() }
        catch { status = "Couldn’t clear capture history: \(error.localizedDescription)" }
    }

    func openMemoryCapture(_ id: UUID) {
        refreshMemory()
        guard memoryRecords.contains(where: { $0.id == id }) else { return }
        memoryRecordToOpen = id
        workspaceSelection = .library
        openPanel()
    }

    private static func loadShortcut() -> GlobalShortcut {
        guard let data = UserDefaults.standard.data(forKey: "globalShortcut"),
              let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data) else { return .default }
        return shortcut
    }

    func capture(quick: Bool = false, appendToBatch: Bool = false, visibleScreen: Bool = false, askAfterCapture: Bool = false) async {
        guard !softwareUpdates.installing else { return }
        guard account.canUseWorkspace else { openPanel(); return }
        guard selectionOverlay == nil, !isCapturing, !isSaving else { return }
        stopAgent()
        await Task.yield()
        calendarAgent?.invalidateSession()
        analysisTask?.cancel()
        ocrTask?.cancel()
        ocrObserverTask?.cancel()
        isRecognizing = false
        agentStatus = nil
        agentSummary = nil
        agentMessages = []; agentStreamingText = ""; agentError = nil; agentRetryPrompt = nil
        isAppendingCapture = appendToBatch && currentMemoryRecordID != nil && !quick
        previousCaptureImage = isAppendingCapture ? image : nil
        let captureSessionID = UUID()
        currentCaptureSessionID = captureSessionID
        currentCaptureIsQuick = quick
        captureAsksForCommand = quick && askAfterCapture
        isCapturing = true
        status = nil
        analyzedWithOpenAI = false
        screenCapturePermissionNeeded = false
        saveMessage = nil
        if !isAppendingCapture {
            image = nil
            recognizedText = ""
            calendarActions.replace(with: [])
            currentMemoryRecordID = nil
        }
        workspaceWindowController?.hide()
        notchLauncherController?.hide()
        try? await Task.sleep(nanoseconds: 120_000_000)
        do {
            let capture = try await ScreenCaptureService.captureMainDisplayWithScreen()
            guard currentCaptureSessionID == captureSessionID else { return }
            isCapturing = false
            if visibleScreen {
                isRecognizing = true
                analysisTask = Task { await self.analyze(capture.image, sessionID: captureSessionID) }
                return
            }
            let overlay = RegionSelectionOverlay(image: capture.image, screen: capture.screen) { [weak self] result in
                guard let self else { return }
                guard self.currentCaptureSessionID == captureSessionID else { return }
                self.selectionOverlay = nil
                switch result {
                case .success(let selectedImage):
                    if self.currentCaptureIsQuick {
                        self.isRecognizing = true
                        Task { await self.finishQuickCapture(selectedImage, sessionID: captureSessionID) }
                    } else {
                        self.isRecognizing = true
                        self.analysisTask = Task { await self.analyze(selectedImage, sessionID: captureSessionID) }
                    }
                case .failure(.cancelled):
                    self.resumeShortcutAfterSelection()
                    self.currentCaptureSessionID = nil
                    self.currentCaptureIsQuick = false
                    if self.isAppendingCapture {
                        self.image = self.previousCaptureImage
                        self.isAppendingCapture = false
                        self.previousCaptureImage = nil
                        self.presentTask()
                    } else { self.image = nil; self.calendarActions.replace(with: []) }
                    self.status = nil
                    self.isCapturing = false
                    self.showNotchLauncher()
                case .failure(let error):
                    self.resumeShortcutAfterSelection()
                    self.currentCaptureSessionID = nil
                    self.currentCaptureIsQuick = false
                    self.status = error.localizedDescription
                    self.presentTask()
                }
            }
            selectionOverlay = overlay
            suspendShortcutForSelection()
            overlay.show()
        } catch {
            guard currentCaptureSessionID == captureSessionID else { return }
            if isAppendingCapture { image = previousCaptureImage; isAppendingCapture = false; previousCaptureImage = nil }
            isCapturing = false
            currentCaptureSessionID = nil
            currentCaptureIsQuick = false
            if let captureError = error as? ScreenCaptureService.CaptureError,
               captureError == .permissionDenied {
                screenCapturePermissionNeeded = true
                status = "Screen Recording is still denied for this signed Calshot build. Remove the old Calshot entry under System Settings → Privacy & Security → Screen & System Audio Recording, add this build again, then quit and reopen Calshot."
            } else if let captureError = error as? ScreenCaptureService.CaptureError,
                      captureError == .noDisplay {
                status = "Couldn’t capture the screen: \(error.localizedDescription)"
            } else {
                status = "Couldn’t capture the screen: \(error.localizedDescription)"
            }
            presentTask()
        }
    }

    private func suspendShortcutForSelection() {
        guard !shortcutSuspendedForSelection else { return }
        shortcutSuspendedForSelection = true
        HotKeyController.shared.unregister()
    }

    func resumeShortcutAfterSelection() {
        guard shortcutSuspendedForSelection else { return }
        shortcutSuspendedForSelection = false
        if !isRecordingShortcut { registerShortcut() }
    }

    private func analyze(_ cgImage: CGImage, sessionID: UUID) async {
        await analyzeWithCalendarAgent(cgImage, sessionID: sessionID)
    }

    private func finishQuickCapture(_ cgImage: CGImage, sessionID: UUID) async {
        guard currentCaptureSessionID == sessionID else { return }
        let image = NSImage(cgImage: cgImage, size: .zero)
        let copied = CaptureClipboard.automaticallyCopyCapture && CaptureClipboard.copy(image)
        guard let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            isRecognizing = false
            currentCaptureSessionID = nil
            currentCaptureIsQuick = false
            resumeShortcutAfterSelection()
            status = "The screenshot was captured but could not be saved to Memory."
            return
        }
        do {
            let record = try memoryStore.recordCapture(imageData: png,
                                                       analysisProvider: "Quick screenshot",
                                                       createdAt: .now)
            currentMemoryRecordID = record.id
            refreshMemory()
            lastCaptureSummary = "Quick screenshot saved"
            isRecognizing = false
            currentCaptureSessionID = nil
            currentCaptureIsQuick = false
            resumeShortcutAfterSelection()
            if captureAsksForCommand {
                captureAsksForCommand = false
                restoreCalendarReview(record)
                workspaceSelection = .chat
                agentStatus = "Screenshot ready. Tell Calshot what you want to do."
                return
            }
            showNotchLauncher()
            notchLauncherController?.showQuickPreview(image: image, recordID: record.id,
                                                       copiedToClipboard: copied)
        } catch {
            isRecognizing = false
            currentCaptureSessionID = nil
            currentCaptureIsQuick = false
            resumeShortcutAfterSelection()
            status = "Couldn’t save screenshot to Memory: \(error.localizedDescription)"
            presentTask()
        }
    }

    func saveOpenAIAPIKey(_ key: String) throws {
        try OpenAIAPIKeyStore.save(key)
        hasOpenAIAPIKey = true
        openAIAnalysisEnabled = true
    }

    @Published var chatGPTIsConnecting = false
    private var chatGPTSignInTask: Task<ChatGPTConnection.Account, Error>?
    func cancelChatGPTSignIn() { chatGPTSignInTask?.cancel() }
    func connectChatGPT() async throws {
        guard !chatGPTIsConnecting else { throw CalendarToolArgumentError("Finish the current ChatGPT sign-in first.") }
        chatGPTIsConnecting = true
        let task = Task { try await ChatGPTConnection.shared.connect() }
        chatGPTSignInTask = task
        defer { chatGPTSignInTask = nil; chatGPTIsConnecting = false; openPanel() }
        let account = try await task.value
        chatGPTAccount = account
        openAIAnalysisEnabled = account.canUsePlan || hasOpenAIAPIKey
        chatGPTConnectionError = await ChatGPTConnection.shared.modelAvailabilityError
        if chatGPTConnectionError == nil { await refreshChatGPTModels() }
        else { chatGPTModels = [] }
    }

    func refreshChatGPTModels() async {
        guard chatGPTAccount?.canUsePlan == true else { chatGPTModels = []; return }
        chatGPTConnectionError = nil
        do {
            chatGPTModels = try await ChatGPTConnection.shared.availableModels()
        } catch {
            chatGPTModels = []
            chatGPTAccount = ChatGPTConnection.savedAccount()
            chatGPTConnectionError = error.localizedDescription
            status = "Couldn’t load ChatGPT models: \(error.localizedDescription)"
        }
    }

    func selectChatGPTModel(_ slug: String) async throws {
        let account = try await ChatGPTConnection.shared.selectModel(slug)
        chatGPTAccount = account
    }

    private static let chatGPTUsageKey = "chatGPTPlanUsage.v1"
    private static func loadChatGPTUsage() -> [ChatGPTConnection.UsageRecord] {
        guard let data = UserDefaults.standard.data(forKey: chatGPTUsageKey),
              let records = try? JSONDecoder().decode([ChatGPTConnection.UsageRecord].self, from: data) else { return [] }
        return records
    }

    private func recordChatGPTUsage(model: String, inputTokens: Int, outputTokens: Int) {
        let today = Calendar.current.startOfDay(for: .now)
        if let index = chatGPTUsage.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: today) }) {
            chatGPTUsage[index].model = model
            chatGPTUsage[index].requestCount += 1
            chatGPTUsage[index].inputTokens += inputTokens
            chatGPTUsage[index].outputTokens += outputTokens
        } else {
            chatGPTUsage.append(.init(date: today, model: model,
                                      inputTokens: inputTokens, outputTokens: outputTokens))
        }
        chatGPTUsage.sort { $0.date < $1.date }
        if chatGPTUsage.count > 365 { chatGPTUsage.removeFirst(chatGPTUsage.count - 365) }
        if let data = try? JSONEncoder().encode(chatGPTUsage) {
            UserDefaults.standard.set(data, forKey: Self.chatGPTUsageKey)
        }
    }

    func disconnectChatGPT() async throws {
        do { try await ChatGPTConnection.shared.disconnect() }
        catch {
            chatGPTAccount = nil
            chatGPTModels = []
            if !hasOpenAIAPIKey { openAIAnalysisEnabled = false }
            throw error
        }
        chatGPTAccount = nil
        chatGPTModels = []
        if !hasOpenAIAPIKey { openAIAnalysisEnabled = false }
    }

    func removeOpenAIAPIKey() throws {
        try OpenAIAPIKeyStore.delete()
        hasOpenAIAPIKey = false
        if chatGPTAccount?.canUsePlan != true { openAIAnalysisEnabled = false }
    }

    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
        if screenPermissionWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Allow Screen Recording"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.contentView = NSHostingView(rootView: ScreenRecordingPermissionHelp())
            window.center()
            screenPermissionWindow = NSWindowController(window: window)
        }
        screenPermissionWindow?.showWindow(nil)
    }

    func dismiss() {
        workspaceWindowController?.hide()
        showNotchLauncher()
    }

    func cancelAnalysis() {
        stopAgent()
        ocrTask?.cancel()
        ocrObserverTask?.cancel()
        analysisTask?.cancel()
        analysisTask = nil
        currentCaptureSessionID = nil
        isRecognizing = false
        isCapturing = false
        resumeShortcutAfterSelection()
        if isAppendingCapture {
            image = previousCaptureImage
            previousCaptureImage = nil
            isAppendingCapture = false
            status = "Additional capture cancelled. Your previous batch is ready to review."
        } else { cancelReview() }
    }

    func storedImage(for record: MemoryCaptureRecord) -> NSImage? {
        memoryStore.imageData(for: record).flatMap(NSImage.init(data:))
    }

    func sourceImage(for item: CalendarActionProposal) -> NSImage? {
        guard let id = currentMemoryRecordID,
              let record = memoryRecords.first(where: { $0.id == id }),
              let data = memoryStore.imageData(for: record, sourceID: item.sourceCaptureID) else { return nil }
        return NSImage(data: data)
    }

    func cancelReview() {
        stopAgent()
        guard !isSaving else { calendarActions.requestStop(); return }
        analysisTask?.cancel()
        analysisTask = nil
        isAppendingCapture = false
        previousCaptureImage = nil
        currentCaptureSessionID = nil
        currentCaptureIsQuick = false
        selectionOverlay?.cancel()
        selectionOverlay = nil
        resumeShortcutAfterSelection()
        currentMemoryRecordID = nil
        image = nil
        calendarActions.replace(with: [])
        isCapturing = false
        isRecognizing = false
        status = nil
        saveMessage = nil
        dismiss()
    }

    var onboardingAIReady: Bool {
        openAIAnalysisEnabled && (agentUseAPIKey ? hasOpenAIAPIKey : chatGPTAccount?.canUsePlan == true && chatGPTConnectionError == nil)
    }
    func confirmOnboardingAI(_ provider: String) throws {
        guard !account.requiresLogin, ["api", "chatgpt"].contains(provider) else { throw CalendarToolArgumentError("Sign in and choose an AI service first.") }
        guard provider == "api" ? hasOpenAIAPIKey : chatGPTAccount?.canUsePlan == true && chatGPTConnectionError == nil else {
            throw CalendarToolArgumentError(provider == "api" ? "Save an API key before continuing." : "Connect an available ChatGPT plan before continuing.")
        }
        agentUseAPIKey = provider == "api"; openAIAnalysisEnabled = true
        account.confirmAISetup()
    }
    func loadCalendars() async {
        guard !account.requiresLogin, !account.enabled || account.onboarded || account.aiSetupConfirmed else { return }
        guard !isSaving else { return }
        saveMessage = nil
        calendarConnectionMessage = "Connecting to macOS calendars…"
        do {
            readableCalendars = try await calendarService.availableDestinations()
            destinations = readableCalendars.filter { !$0.isReadOnly }
            if !destinations.contains(where: { $0.id == selectedCalendarID }) { selectedCalendarID = destinations.first?.id }
            calendarConnectionMessage = destinations.isEmpty ? (readableCalendars.isEmpty ? "No calendars connected. Connect an account in Settings → Calendar accounts." : "Connected calendars are read-only or unavailable. Search can use readable calendars; adding events needs a writable destination.") : nil
            if destinations.isEmpty { saveMessage = calendarConnectionMessage }
        } catch {
            destinations = []; readableCalendars = []
            calendarConnectionMessage = error.localizedDescription
            saveMessage = error.localizedDescription
        }
    }

    func saveEvents() async {
        guard account.canUseWorkspace else { calendarActions.message = "Sign in and connect a calendar before approving changes."; openPanel(); return }
        guard let selectedCalendarID,
              let destination = destinations.first(where: { $0.id == selectedCalendarID }) else {
            calendarActions.message = "Choose a writable calendar to continue."
            return
        }
        if agentIsWaitingForApproval && !calendarActions.needsDuplicateCheck(destinationID: selectedCalendarID) {
            let selected = calendarActions.proposals.filter { $0.isSelected && !$0.isFinished && calendarActions.isInApprovalScope($0.id) }
            agentStatus = selected.count == 1 && selected.first?.operation == .update ? "Updating 1 event" : "Saving approved calendar actions"
        }
        await calendarActions.execute(destinationID: selectedCalendarID, calendarName: destination.title)
    }

    func restoreCalendarReview(_ record: MemoryCaptureRecord) {
        guard !isSaving, !isRecognizing, !isCapturing,
              !agentIsRunning else { return }
        stopAgent()
        let sourceID = record.additionalScreenshots?.last?.id
        let restoredImage = memoryStore.imageData(for: record, sourceID: sourceID).flatMap(NSImage.init(data:))
        ocrTask?.cancel(); ocrTask = nil
        screenRecognition = ScreenTextRecognition(lines: [])
        refreshMemory()
        currentCaptureSessionID = UUID()
        currentMemoryRecordID = record.id
        image = restoredImage
        recognizedText = record.additionalScreenshots?.last?.recognizedText ?? record.recognizedText ?? ""
        lastAnalysisProvider = record.analysisProvider
        calendarActions.replace(with: record.calendarProposals)
        agentTranscriptPrefix = record.agentTranscript ?? []
        agentMessages = agentTranscriptPrefix; agentStreamingText = ""; agentError = nil; agentRetryPrompt = nil
        agentSummary = agentTranscriptPrefix.last(where: { $0.role == "assistant" && $0.toolName == nil })?.content
        agentStatus = record.agentTranscript == nil ? nil : "Conversation restored. Send a command to continue; pending writes still require approval."
        currentAgentSourceID = sourceID
        status = nil
        saveMessage = nil
        workspaceSelection = restoredImage == nil && record.agentTranscript != nil ? .chat : .capture
        presentTask()
    }

}

struct MenuBarView: View {
    @ObservedObject var model: CalshotModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image("CalshotMark").resizable().scaledToFit()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calshot").font(.system(size: 15, weight: .semibold))
                    Text("Capture, read, remember").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Button {
                dismiss()
                Task { await model.capture() }
            } label: {
                    HStack { Image(systemName: "camera.viewfinder"); Text("New Capture"); Spacer(); Text(model.shortcut.label).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.65)) }
                    .padding(.horizontal, 12).padding(.vertical, 11).contentShape(Rectangle())
            }.buttonStyle(.plain).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11)).foregroundStyle(.white)
            Button {
                dismiss()
                Task { await model.capture(quick: true) }
            } label: {
                Label("Quick Screenshot", systemImage: "camera")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .buttonStyle(.bordered)
            .disabled(model.isCapturing || model.isRecognizing)
            Toggle(isOn: $model.openAIAnalysisEnabled) {
                Label("Send captured image to OpenAI", systemImage: "cloud")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!model.hasOpenAIAPIKey && model.chatGPTAccount?.canUsePlan != true)
            if !model.hasOpenAIAPIKey && model.chatGPTAccount?.canUsePlan != true {
                Text("Connect ChatGPT or add an API key to enable OpenAI analysis.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            Button { model.openSettings() } label: {
                Label("Settings…", systemImage: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button { model.openPanel() } label: {
                Label("Open Workspace", systemImage: "macwindow")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button { model.showNotchLauncher() } label: {
                Label("Show notch launcher", systemImage: "capsule.portrait")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            HStack(spacing: 7) {
                Circle().fill(model.openAIAnalysisEnabled ? .orange : .green).frame(width: 6, height: 6)
                Text(model.openAIAnalysisEnabled ? "OpenAI analysis · captured image sent online" : "Private by design · processed on your Mac")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(14).frame(width: 310)
    }
}

enum OpenAIAPIKeyStore {
    private static let service = "com.calshot.openai"
    private static let account = "api-key"

    static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.operationFailed(status)
        }
        return value
    }

    static func save(_ key: String) throws {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw KeychainError.emptyKey }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(cleaned.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.operationFailed(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.operationFailed(status)
        }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status)
        }
    }

    enum KeychainError: LocalizedError {
        case emptyKey
        case operationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .emptyKey: "Enter an API key first."
            case .operationFailed(let status): "Could not update the API key in Keychain (\(status))."
            }
        }
    }
}

enum ScreenCaptureService {
    struct CaptureResult {
        let image: CGImage
        let screen: NSScreen
    }

    static func captureMainDisplayWithScreen() async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pointer = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else {
            throw CaptureError.noDisplay
        }
        let displayID = targetScreen.deviceDescription[ NSDeviceDescriptionKey("NSScreenNumber") ] as? CGDirectDisplayID
        let display = displayID.flatMap { id in content.displays.first(where: { $0.displayID == id }) } ?? content.displays.first
        guard let display else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CaptureResult(image: image, screen: targetScreen)
    }
    enum CaptureError: LocalizedError, Equatable {
        case permissionDenied
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Screen Recording permission is off for this Calshot build."
            case .noDisplay: "No display is available to capture."
            }
        }
    }
}

struct SoftwareUpdateMenuItem: View {
    @ObservedObject var controller: SoftwareUpdateController
    var body: some View {
        Button("Check for Updates…") { try? controller.check() }
            .disabled(controller.updater?.canCheckForUpdates != true || controller.installing)
    }
}
