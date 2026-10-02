import AppKit
import Carbon.HIToolbox
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
        HotKeyController.shared.onPress = {
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.capture() }
        }
        HotKeyController.shared.register()

        // Show the review panel when the app opens from Xcode, the Dock, or Finder.
        DispatchQueue.main.async { [weak self] in
            self?.model.openPanel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { model.openPanel() }
        return true
    }

    func capture() {
        NotificationCenter.default.post(name: .calshotCaptureRequested, object: nil)
    }
}

extension Notification.Name {
    static let calshotCaptureRequested = Notification.Name("CalshotCaptureRequested")
}

@MainActor
final class CalshotModel: ObservableObject {
    @Published var image: NSImage?
    @Published var draft: EventDraft?
    @Published var isCapturing = false
    @Published var isRecognizing = false
    @Published var status: String?
    @Published var screenCapturePermissionNeeded = false
    @Published var panelController: ReviewPanelController?
    @Published var destinations: [CalendarDestinationInfo] = []
    @Published var selectedCalendarID: String?
    @Published var isSaving = false
    @Published var saveMessage: String?
    private let calendarService = EventKitCalendarService()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .calshotCaptureRequested, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.capture() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func openPanel() {
        if panelController == nil { panelController = ReviewPanelController(model: self) }
        panelController?.show()
    }

    func capture() async {
        isCapturing = true
        status = nil
        screenCapturePermissionNeeded = false
        saveMessage = nil
        image = nil
        draft = nil
        panelController?.hide()
        try? await Task.sleep(nanoseconds: 120_000_000)
        do {
            let cgImage = try await ScreenCaptureService.captureMainDisplay()
            image = NSImage(cgImage: cgImage, size: .zero)
            isCapturing = false
            openPanel()
            isRecognizing = true
            let text = try await ScreenTextRecognizer.recognize(in: cgImage)
            let candidates = await EventDraftExtractionService.extract(text)
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
                    if !first.ambiguities.contains(.missingEndTime) {
                        first.ambiguities.append(.missingEndTime)
                    }
                }
                draft = first
            }
            if candidates.isEmpty { status = text.isEmpty ? "No text found. Try selecting a page with event details." : "No event date found. You can still add the details manually." }
            isRecognizing = false
        } catch {
            isCapturing = false
            isRecognizing = false
            if let captureError = error as? ScreenCaptureService.CaptureError,
               captureError == .permissionDenied {
                screenCapturePermissionNeeded = true
                status = "Screen Recording is still denied for this signed Calshot build. Remove the old Calshot entry under System Settings → Privacy & Security → Screen & System Audio Recording, add this build again, then quit and reopen Calshot."
            } else {
                status = "Couldn’t capture the screen: \(error.localizedDescription)"
            }
            openPanel()
        }
    }

    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func dismiss() {
        panelController?.close()
        panelController = nil
    }

    func loadCalendars() async {
        do {
            destinations = try await calendarService.availableDestinations().filter { !$0.isReadOnly }
            if selectedCalendarID == nil { selectedCalendarID = destinations.first?.id }
            if destinations.isEmpty { saveMessage = "No writable calendars found. Add an account in System Settings → Internet Accounts." }
        } catch { saveMessage = error.localizedDescription }
    }

    func saveEvent() async {
        guard let draft, let selectedCalendarID,
              destinations.contains(where: { $0.id == selectedCalendarID }) else {
            saveMessage = "Choose a writable calendar to continue."; return
        }
        isSaving = true; saveMessage = nil
        do {
            _ = try await calendarService.save(draft, to: .eventKit(calendarIdentifier: selectedCalendarID))
            let calendarName = destinations.first(where: { $0.id == selectedCalendarID })?.title ?? "your calendar"
            saveMessage = "Added ‘\(draft.title)’ to \(calendarName)."
        } catch { saveMessage = error.localizedDescription }
        isSaving = false
    }
}

struct MenuBarView: View {
    @ObservedObject var model: CalshotModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "viewfinder").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calshot").font(.system(size: 15, weight: .semibold))
                    Text("Turn what you see into a calendar event").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Button { Task { await model.capture() } } label: {
                    HStack { Image(systemName: "camera.viewfinder"); Text("Capture this screen"); Spacer(); Text("⌃⇧C").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.65)) }
                    .padding(.horizontal, 12).padding(.vertical, 11).contentShape(Rectangle())
            }.buttonStyle(.plain).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11)).foregroundStyle(.white)
            Button { model.openPanel() } label: {
                Label("Open Calshot", systemImage: "macwindow")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            HStack(spacing: 7) { Circle().fill(.green).frame(width: 6, height: 6); Text("Private by design · processed on your Mac").font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(14).frame(width: 290)
    }
}

final class ReviewPanelController {
    private let panel: NSPanel
    init(model: CalshotModel) {
        let view = ReviewPanelView(model: model)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 660), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Calshot"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: view)
        panel.centerNearMenuBar()
    }
    func show() { panel.centerNearMenuBar(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func hide() { panel.orderOut(nil) }
    func close() { panel.orderOut(nil) }
}

private extension NSPanel {
    func centerNearMenuBar() {
        guard let screen = NSScreen.main else { center(); return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 10))
    }
}

struct ReviewPanelView: View {
    @ObservedObject var model: CalshotModel
    @State private var showSource = false
    @State private var expandedScreenshot = false
    @State private var saved = false
    private let ink = Color.primary

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    screenshot
                    if model.isRecognizing { HStack(spacing: 9) { ProgressView().controlSize(.small); Text("Reading event details…").font(.system(size: 12)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
                    if let draft = model.draft { eventForm(draft) }
                    else if let status = model.status {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(status, systemImage: model.screenCapturePermissionNeeded ? "lock.shield" : "info.circle")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            if model.screenCapturePermissionNeeded {
                                Button("Open Screen Recording Settings") { model.openScreenCaptureSettings() }
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    }
                    else if model.image == nil { emptyState }
                }.padding(20)
            }
            footer
        }
        .frame(width: 480, height: 660)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.28), lineWidth: 1))
        .preferredColorScheme(nil)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "viewfinder").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(width: 30, height: 30).background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) { Text("Calshot").font(.system(size: 13, weight: .semibold)); Text(model.draft == nil ? "Screen capture" : "Review event").font(.system(size: 10)).foregroundStyle(.secondary) }
            Spacer()
            Button { model.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 26, height: 26).background(.quaternary, in: Circle()) }.buttonStyle(.plain).help("Dismiss")
        }.padding(.horizontal, 19).padding(.top, 17).padding(.bottom, 11)
    }

    @ViewBuilder private var screenshot: some View {
        if let image = model.image {
            ZStack(alignment: .topTrailing) {
                Button { expandedScreenshot.toggle() } label: {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: expandedScreenshot ? .fit : .fill).frame(height: expandedScreenshot ? 330 : 148).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 13))
                }.buttonStyle(.plain).accessibilityLabel(expandedScreenshot ? "Show compact screenshot" : "Show larger screenshot").help("Click to resize screenshot preview")
                Button { Task { await model.capture() } } label: { Label("Retake", systemImage: "arrow.clockwise").font(.system(size: 10, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule()) }.buttonStyle(.plain).padding(9)
            }
        } else if model.isCapturing {
            RoundedRectangle(cornerRadius: 13).fill(.quaternary.opacity(0.55)).frame(height: 148).overlay(VStack(spacing: 9) { ProgressView(); Text("Capturing your screen…").font(.system(size: 12)).foregroundStyle(.secondary) })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 28, weight: .light)).foregroundStyle(.indigo)
            Text("Capture an event page").font(.system(size: 15, weight: .semibold))
            Text("Calshot looks for dates and event details on your screen, then gives you a chance to review everything.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            Text("Press  ⌃⇧C  anywhere to capture").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 3)
        }.frame(maxWidth: .infinity).padding(.vertical, 28)
    }

    private func eventForm(_ initial: EventDraft) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text("EVENT DETAILS").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Text(initial.confidence > 0.75 ? "Looks clear" : "Needs a closer look").font(.system(size: 9, weight: .medium)).foregroundStyle(initial.confidence > 0.75 ? .green : .orange)
            }
            VStack(spacing: 0) {
                editableRow(icon: "textformat", placeholder: "Event title", text: binding(initial, \.title))
                Divider().padding(.leading, 39)
                if initial.ambiguities.contains(.missingTime) { Label("No time detected — review as all-day or add a time.", systemImage: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange).padding(.leading, 39).padding(.vertical, 7) }
                if initial.ambiguities.contains(where: { String(describing: $0).lowercased().contains("date") || String(describing: $0).lowercased().contains("year") }) { Label("Check the date — a year may be missing", systemImage: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange).padding(.leading, 39).padding(.vertical, 7) }
                dateRow(initial)
                if let start = model.draft?.startDate,
                   let end = model.draft?.endDate, end <= start {
                    Label("End must be later than start. Adjust the end date or time above.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                        .padding(.leading, 28).padding(.vertical, 5)
                }
                Divider().padding(.leading, 39)
                editableRow(icon: "mappin.and.ellipse", placeholder: "Add location", text: optionalBinding(initial, \.location))
                if initial.url != nil {
                    Divider().padding(.leading, 39)
                    editableRow(icon: "link", placeholder: "Event link", text: Binding(get: { model.draft?.url?.absoluteString ?? initial.url?.absoluteString ?? "" }, set: { model.draft?.url = URL(string: $0) }))
                }
                if initial.notes != nil {
                    Divider().padding(.leading, 39)
                    editableRow(icon: "note.text", placeholder: "Notes", text: optionalBinding(initial, \.notes))
                }
            }.padding(.horizontal, 11).background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.055)))
            HStack {
                Text("SAVE TO").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                if model.destinations.isEmpty {
                    Button("Choose calendar…") { Task { await model.loadCalendars() } }.font(.system(size: 11))
                } else {
                    Picker("Calendar", selection: Binding(get: { model.selectedCalendarID ?? "" }, set: { model.selectedCalendarID = $0 })) {
                        ForEach(model.destinations) { calendar in Text("\(calendar.title) · \(calendar.provider == .google ? "Google" : calendar.provider == .apple ? "Apple" : "Other")").tag(calendar.id) }
                    }.labelsHidden().pickerStyle(.menu).font(.system(size: 11))
                }
            }.padding(.top, 2)
            if let message = model.saveMessage { Text(message).font(.system(size: 10)).foregroundStyle(message.hasPrefix("Added") ? .green : .secondary).frame(maxWidth: .infinity, alignment: .leading) }
            if model.destinations.contains(where: { $0.provider == .google }) { Text("Google calendars connected in macOS are available here. Add accounts in System Settings → Internet Accounts.").font(.system(size: 10)).foregroundStyle(.secondary) }
            DisclosureGroup(isExpanded: $showSource) {
                Text(initial.sourceText.isEmpty ? "No source text was found." : initial.sourceText).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 7)
            } label: { Label("Source text", systemImage: "text.quote").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
        }
    }

    private func binding(_ d: EventDraft, _ keyPath: WritableKeyPath<EventDraft, String>) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: keyPath] ?? d[keyPath: keyPath] }, set: { model.draft?[keyPath: keyPath] = $0 })
    }
    private func optionalBinding(_ d: EventDraft, _ keyPath: WritableKeyPath<EventDraft, String?>) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: keyPath] ?? d[keyPath: keyPath] ?? "" }, set: { model.draft?[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
    private func editableRow(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16); TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 12)) }.padding(.vertical, 11)
    }
    private func dateRow(_ draft: EventDraft) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 12) {
                Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                Text("Starts").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 37, alignment: .leading)
                DatePicker("Start", selection: Binding(get: { model.draft?.startDate ?? .now }, set: { value in
                    let selected = model.draft?.isAllDay == true ? Calendar.current.startOfDay(for: value) : value
                    model.draft?.startDate = selected
                    if model.draft?.isAllDay == true { model.draft?.endDate = Calendar.current.date(byAdding: .day, value: 1, to: selected) }
                    else if model.draft?.endDate == nil || (model.draft?.endDate ?? .distantPast) <= selected { model.draft?.endDate = selected.addingTimeInterval(3600) }
                }), displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]).labelsHidden().datePickerStyle(.compact).font(.system(size: 11))
                Spacer(minLength: 4)
                Toggle("All day", isOn: Binding(get: { model.draft?.isAllDay ?? false }, set: { setAllDay($0) })).labelsHidden().toggleStyle(.switch).controlSize(.mini).accessibilityLabel("All day event")
            }
            if draft.isAllDay {
                Label("Ends at midnight the following day", systemImage: "moon.zzz").font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 28).padding(.top, 2)
            } else { HStack(spacing: 12) {
                Color.clear.frame(width: 16)
                Text("Ends").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 37, alignment: .leading)
                DatePicker("End", selection: Binding(get: { model.draft?.endDate ?? (model.draft?.startDate ?? .now).addingTimeInterval(3600) }, set: { model.draft?.endDate = $0 }), displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]).labelsHidden().datePickerStyle(.compact).font(.system(size: 11))
                Spacer()
            } }
        }.padding(.vertical, 7)
    }
    private func setAllDay(_ enabled: Bool) {
        guard var value = model.draft else { return }
        value.isAllDay = enabled
        if enabled, let start = value.startDate {
            let calendar = Calendar.current
            let dayStart = calendar.startOfDay(for: start)
            value.startDate = dayStart
            value.endDate = calendar.date(byAdding: .day, value: 1, to: dayStart)
        }
        model.draft = value
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button { model.dismiss() } label: { Text("Cancel").font(.system(size: 12, weight: .medium)).frame(width: 86, height: 38) }.buttonStyle(.plain).background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 11))
            Spacer()
            if model.draft != nil {
                Button { Task { await model.saveEvent() } } label: {
                    HStack(spacing: 8) { if model.isSaving { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: model.saveMessage?.hasPrefix("Added") == true ? "checkmark" : "calendar.badge.plus") }; Text(model.isSaving ? "Adding…" : model.saveMessage?.hasPrefix("Added") == true ? "Added" : "Add to Calendar") }.font(.system(size: 12, weight: .semibold)).frame(width: 150, height: 38)
                }.buttonStyle(.plain).foregroundStyle(.white).background(model.saveMessage?.hasPrefix("Added") == true ? Color.green : Color.accentColor, in: RoundedRectangle(cornerRadius: 11)).disabled(model.isSaving || model.saveMessage?.hasPrefix("Added") == true)
            } else {
                Button { Task { await model.capture() } } label: { Label("Capture screen", systemImage: "camera.viewfinder").font(.system(size: 12, weight: .semibold)).frame(width: 150, height: 38) }.buttonStyle(.plain).foregroundStyle(.white).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11))
            }
        }.padding(.horizontal, 19).padding(.vertical, 14).background(.ultraThinMaterial)
    }
}

enum ScreenCaptureService {
    static func captureMainDisplay() async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pointer = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        let displayID = targetScreen?.deviceDescription[ NSDeviceDescriptionKey("NSScreenNumber") ] as? CGDirectDisplayID
        let display = displayID.flatMap { id in content.displays.first(where: { $0.displayID == id }) } ?? content.displays.first
        guard let display else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.capturesAudio = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
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

final class HotKeyController {
    static let shared = HotKeyController()
    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private init() {}
    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
            NSLog("Calshot: global shortcut received")
            controller.onPress?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        let hotKeyID = EventHotKeyID(signature: OSType(0x43414C53), id: 1)
        let hotKeyStatus = RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | shiftKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        NSLog("Calshot: shortcut registration handler=%d hotkey=%d", handlerStatus, hotKeyStatus)
    }
}
