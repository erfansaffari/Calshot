import AppKit
import Carbon.HIToolbox
import Security
import ScreenCaptureKit
import SwiftUI

@main
struct CalshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Calshot", systemImage: "viewfinder") {
            MenuBarView(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CalshotModel()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        HotKeyController.shared.onPress = { [weak model = self.model] in
            Task { @MainActor in await model?.capture() }
        }
        model.registerShortcut()

        DispatchQueue.main.async { [weak self] in
            self?.model.showNotchLauncher()
            self?.model.openPanel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        model.showNotchLauncher()
        if !hasVisibleWindows { model.openPanel() }
        return true
    }

}

@MainActor
final class CalshotModel: ObservableObject {
    @Published var image: NSImage?
    @Published var recognizedText = ""
    @Published var draft: EventDraft?
    @Published var isCapturing = false
    @Published var isRecognizing = false
    @Published var status: String?
    @Published var screenCapturePermissionNeeded = false
    var workspaceWindowController: WorkspaceWindowController?
    var notchLauncherController: NotchExperienceController?
    @Published var workspaceSelection: WorkspaceSection = .capture
    @Published var selectionOverlay: RegionSelectionOverlay?
    @Published var destinations: [CalendarDestinationInfo] = []
    @Published var selectedCalendarID: String?
    @Published var isSaving = false
    @Published var saveMessage: String?
    @Published var hasOpenAIAPIKey = false
    @Published var chatGPTAccount: ChatGPTConnection.Account?
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
    @Published var memoryLocationMessage: String?
    @Published var lastAnalysisProvider: String?
    @Published var lastOCRStatus = "No OCR run yet"
    @Published var lastCaptureSummary = "No capture yet"
    private let calendarService = EventKitCalendarService()
    private let memoryStore = MemoryStore.shared
    private var currentMemoryRecordID: UUID?
    private var currentCaptureSessionID: UUID?
    private var shortcutSuspendedForSelection = false

    init() {
        hasOpenAIAPIKey = (try? OpenAIAPIKeyStore.load()) != nil
        chatGPTAccount = ChatGPTConnection.savedAccount()
        if chatGPTAccount?.canUsePlan == true {
            Task { [weak self] in
                guard let self,
                      let account = try? await ChatGPTConnection.shared.refreshPreferredModel() else { return }
                self.chatGPTAccount = account
            }
        }
    }

    func openPanel() {
        if workspaceWindowController == nil { workspaceWindowController = WorkspaceWindowController(model: self) }
        workspaceWindowController?.show()
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

    func refreshMemory() { memoryRecords = memoryStore.listRecords() }

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
            refreshMemory()
            memoryLocationMessage = "Memory moved to \(destination.path)"
        } catch {
            memoryLocationMessage = "Couldn’t move Memory: \(error.localizedDescription)"
        }
    }

    func deleteMemoryRecord(_ id: UUID) {
        do { try memoryStore.deleteRecord(id: id); refreshMemory() }
        catch { status = "Couldn’t delete capture history: \(error.localizedDescription)" }
    }

    func deleteAllMemory() {
        do { try memoryStore.deleteAll(); refreshMemory() }
        catch { status = "Couldn’t clear capture history: \(error.localizedDescription)" }
    }

    private static func loadShortcut() -> GlobalShortcut {
        guard let data = UserDefaults.standard.data(forKey: "globalShortcut"),
              let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data) else { return .default }
        return shortcut
    }

    func capture() async {
        guard selectionOverlay == nil, !isCapturing, !isRecognizing, !isSaving else { return }
        let captureSessionID = UUID()
        currentCaptureSessionID = captureSessionID
        isCapturing = true
        status = nil
        analyzedWithOpenAI = false
        screenCapturePermissionNeeded = false
        saveMessage = nil
        image = nil
        recognizedText = ""
        draft = nil
        currentMemoryRecordID = nil
        workspaceWindowController?.hide()
        notchLauncherController?.hide()
        try? await Task.sleep(nanoseconds: 120_000_000)
        do {
            let capture = try await ScreenCaptureService.captureMainDisplayWithScreen()
            isCapturing = false
            let overlay = RegionSelectionOverlay(image: capture.image, screen: capture.screen) { [weak self] result in
                guard let self else { return }
                guard self.currentCaptureSessionID == captureSessionID else {
                    self.resumeShortcutAfterSelection()
                    return
                }
                self.selectionOverlay = nil
                switch result {
                case .success(let selectedImage):
                    self.isRecognizing = true
                    Task { await self.analyze(selectedImage, sessionID: captureSessionID) }
                case .failure(.cancelled):
                    self.resumeShortcutAfterSelection()
                    self.currentCaptureSessionID = nil
                    self.image = nil
                    self.draft = nil
                    self.status = nil
                    self.isCapturing = false
                    self.showNotchLauncher()
                case .failure(let error):
                    self.resumeShortcutAfterSelection()
                    self.status = error.localizedDescription
                    self.openPanel()
                }
            }
            selectionOverlay = overlay
            suspendShortcutForSelection()
            overlay.show()
        } catch {
            isCapturing = false
            currentCaptureSessionID = nil
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
            openPanel()
        }
    }

    private func suspendShortcutForSelection() {
        guard !shortcutSuspendedForSelection else { return }
        shortcutSuspendedForSelection = true
        HotKeyController.shared.unregister()
    }

    private func resumeShortcutAfterSelection() {
        guard shortcutSuspendedForSelection else { return }
        shortcutSuspendedForSelection = false
        if !isRecordingShortcut { registerShortcut() }
    }

    private func analyze(_ cgImage: CGImage, sessionID: UUID) async {
        guard currentCaptureSessionID == sessionID else { return }
        image = NSImage(cgImage: cgImage, size: .zero)
        if CaptureClipboard.automaticallyCopyCapture, let image { CaptureClipboard.copy(image) }
        isCapturing = false
        workspaceSelection = .capture
        openPanel()
        showNotchLauncher()
        isRecognizing = true
        status = nil
        saveMessage = nil
        var candidates: [EventDraft]
        var fallbackStatus: String?
        let recognizedText: String
        do {
            recognizedText = try await ScreenTextRecognizer.recognize(in: cgImage)
            let characterCount = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).count
            lastOCRStatus = characterCount == 0 ? "Vision ran, but found no readable text." : "Vision recognized \(characterCount) characters."
        } catch {
            recognizedText = ""
            lastOCRStatus = "Vision OCR failed: \(error.localizedDescription)"
        }
        guard currentCaptureSessionID == sessionID else { return }
        self.recognizedText = recognizedText
        let apiKey = try? OpenAIAPIKeyStore.load()
        if openAIAnalysisEnabled, chatGPTAccount?.canUsePlan == true {
            analyzedWithOpenAI = true
            status = "Analyzing screenshot with your ChatGPT plan…"
            do {
                let access = try await ChatGPTConnection.shared.access()
                candidates = try await OpenAIEventAnalyzer.analyze(
                    image: cgImage, apiKey: access.token, model: access.model, stream: true,
                    referenceDate: .now, timeZone: .current, locale: .current,
                    recognizedText: recognizedText
                )
                lastAnalysisProvider = "ChatGPT plan (\(access.model)) + Vision OCR"
            } catch {
                analyzedWithOpenAI = false
                fallbackStatus = "ChatGPT analysis failed; used on-device analysis. \(error.localizedDescription)"
                candidates = await EventDraftExtractionService.extract(recognizedText)
                lastAnalysisProvider = "On-device fallback + Vision OCR"
            }
        } else if openAIAnalysisEnabled, let apiKey {
            analyzedWithOpenAI = true
            status = "Cross-checking screenshot and Vision OCR with OpenAI…"
            do {
                candidates = try await OpenAIEventAnalyzer.analyze(
                    image: cgImage, apiKey: apiKey, referenceDate: .now,
                    timeZone: .current, locale: .current, recognizedText: recognizedText
                )
                lastAnalysisProvider = "OpenAI (\(OpenAIEventAnalyzer.modelName)) + Vision OCR"
            } catch {
                analyzedWithOpenAI = false
                fallbackStatus = "OpenAI analysis failed; used on-device analysis. \(error.localizedDescription)"
                candidates = await EventDraftExtractionService.extract(recognizedText)
                lastAnalysisProvider = "On-device fallback + Vision OCR"
            }
        } else {
            analyzedWithOpenAI = false
            if openAIAnalysisEnabled && !hasOpenAIAPIKey && chatGPTAccount == nil {
                fallbackStatus = "Connect ChatGPT or add an OpenAI API key in Settings. Used on-device analysis instead."
            }
            candidates = await EventDraftExtractionService.extract(recognizedText)
            lastAnalysisProvider = "On-device analysis + Vision OCR"
        }
        guard currentCaptureSessionID == sessionID else { return }
        draft = candidates.first
        if var first = draft, let start = first.startDate,
           first.endDate == nil || first.endDate! <= start {
            if first.isAllDay {
                var calendar = Calendar.current
                if let zone = first.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) {
                    calendar.timeZone = zone
                }
                let dayStart = calendar.startOfDay(for: start)
                first.startDate = dayStart
                first.endDate = calendar.date(byAdding: .day, value: 1, to: dayStart)
            } else {
                first.endDate = start.addingTimeInterval(3600)
                if !first.ambiguities.contains(.missingEndTime) { first.ambiguities.append(.missingEndTime) }
            }
            draft = first
        }
        if candidates.isEmpty {
            status = fallbackStatus ?? (analyzedWithOpenAI
                ? "OpenAI didn’t find a calendar event. Try selecting a tighter region around the event details."
                : "No event date found. You can still add the details manually.")
        } else { status = fallbackStatus }
        let captureDate = Date()
        lastCaptureSummary = "\(captureDate.formatted(date: .abbreviated, time: .shortened)) · \(draft?.title ?? "No event found")"
        if let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
            do {
                let record = try memoryStore.recordCapture(imageData: png, draft: draft,
                                                           recognizedText: recognizedText,
                                                           analysisProvider: lastAnalysisProvider,
                                                           createdAt: captureDate)
                currentMemoryRecordID = record.id
                refreshMemory()
            } catch {
                status = [status, "Couldn’t save local capture history: \(error.localizedDescription)"]
                    .compactMap { $0 }.joined(separator: " ")
            }
        }
        isRecognizing = false
        resumeShortcutAfterSelection()
    }

    func saveOpenAIAPIKey(_ key: String) throws {
        try OpenAIAPIKeyStore.save(key)
        hasOpenAIAPIKey = true
        openAIAnalysisEnabled = true
    }

    func connectChatGPT() async throws {
        let account = try await ChatGPTConnection.shared.connect()
        chatGPTAccount = account
        openAIAnalysisEnabled = account.canUsePlan || hasOpenAIAPIKey
    }

    func disconnectChatGPT() async throws {
        do { try await ChatGPTConnection.shared.disconnect() }
        catch {
            chatGPTAccount = nil
            if !hasOpenAIAPIKey { openAIAnalysisEnabled = false }
            throw error
        }
        chatGPTAccount = nil
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
    }

    func dismiss() {
        workspaceWindowController?.hide()
        showNotchLauncher()
    }

    func cancelReview() {
        currentCaptureSessionID = nil
        selectionOverlay?.cancel()
        selectionOverlay = nil
        resumeShortcutAfterSelection()
        currentMemoryRecordID = nil
        image = nil
        draft = nil
        isCapturing = false
        isRecognizing = false
        isSaving = false
        status = nil
        saveMessage = nil
        dismiss()
    }

    func loadCalendars() async {
        do {
            destinations = try await calendarService.availableDestinations().filter { !$0.isReadOnly }
            if selectedCalendarID == nil { selectedCalendarID = destinations.first?.id }
            if destinations.isEmpty { saveMessage = "No writable calendars found. Add an account in System Settings → Internet Accounts." }
        } catch { saveMessage = error.localizedDescription }
    }

    func saveEvent() async {
        guard let draft,
              !draft.ambiguities.contains(where: { $0 == .missingDate || $0 == .missingYear || $0 == .ambiguousDate }),
              let startDate = draft.startDate,
              let endDate = draft.endDate,
              endDate > startDate else {
            saveMessage = "Choose a valid event date and time before adding it."
            return
        }
        guard let selectedCalendarID,
              destinations.contains(where: { $0.id == selectedCalendarID }) else {
            saveMessage = "Choose a writable calendar to continue."; return
        }
        isSaving = true; saveMessage = nil
        do {
            let eventIdentifier = try await calendarService.save(draft, to: .eventKit(calendarIdentifier: selectedCalendarID))
            let calendarName = destinations.first(where: { $0.id == selectedCalendarID })?.title ?? "your calendar"
            saveMessage = "Added ‘\(draft.title)’ to \(calendarName)."
            if let currentMemoryRecordID {
                _ = try? memoryStore.updateEventDetails(for: currentMemoryRecordID, draft: draft)
                _ = try? memoryStore.markSavedToCalendar(for: currentMemoryRecordID,
                                                         calendarName: calendarName,
                                                         eventIdentifier: eventIdentifier)
                refreshMemory()
            }
        } catch { saveMessage = error.localizedDescription }
        isSaving = false
    }
}

struct MenuBarView: View {
    @ObservedObject var model: CalshotModel

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
            Button { Task { await model.capture() } } label: {
                    HStack { Image(systemName: "camera.viewfinder"); Text("New Capture"); Spacer(); Text(model.shortcut.label).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.65)) }
                    .padding(.horizontal, 12).padding(.vertical, 11).contentShape(Rectangle())
            }.buttonStyle(.plain).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11)).foregroundStyle(.white)
            Toggle(isOn: $model.openAIAnalysisEnabled) {
                Label("Send selected image to OpenAI", systemImage: "cloud")
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
                Text(model.openAIAnalysisEnabled ? "OpenAI analysis · selected region sent online" : "Private by design · processed on your Mac")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(14).frame(width: 310)
    }
}

private enum OpenAIAPIKeyStore {
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
