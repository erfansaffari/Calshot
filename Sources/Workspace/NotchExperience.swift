import AppKit
import Combine
import SwiftUI
import WebKit

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func sendEvent(_ event: NSEvent) {
        // Focus only on an intentional click. Forward that same click exactly once.
        if event.type == .leftMouseDown && !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

/// Compact native shell; the embedded React view shares the workspace's validated tools.
@MainActor
final class NotchExperienceController: ObservableObject {
    private let panel: NotchPanel
    let workspace: WebWorkspaceController
    private weak var model: CalshotModel?
    @Published private var presentation = NotchPresentationState()
    var isExpanded: Bool { presentation.isExpanded }
    var showsNotification: Bool { presentation.showsNotification }
    @Published private(set) var presentsExpandedContent = false
    private var targetFrame: NSRect?
    private var transitionID = UUID()
    @Published private(set) var launcherSize = NSSize(width: 184, height: 24)
    /// The drawn shape. Only this animates; the window jumps to cover the transition.
    @Published private(set) var visibleSize = NSSize(width: 184, height: 24)
    /// WebKit layout size, held at the larger size during a transition so it never re-lays out per frame.
    @Published private(set) var contentSize = NSSize(width: 184, height: 24)
    /// The web view's layout size. It never shrinks to the closed notch, so the page stays attached and laid out
    /// while hidden and opening only reveals it, with no WebKit layout during the animation.
    @Published private(set) var webSize = NSSize(width: 520, height: 90)
    @Published private(set) var colorScheme: ColorScheme?
    /// Hover opens the quick menu only while the notch is on. With it off, only the voice island shows, and a
    /// click on it opens the voice controls (Stop, errors, billing confirmation, a voice review).
    @Published private(set) var quickMenuEnabled = true
    /// Read per frame by the island meter; never published, so levels never re-render the shell.
    var voiceLevels: (input: Float, output: Float) { model?.voiceSession.levels ?? (0, 0) }
    @Published private(set) var expandedWidth: CGFloat = 520
    @Published private(set) var cameraInset: CGFloat = 24
    @Published private(set) var activity = NotchActivity.idle
    @Published private(set) var voiceActivity: NotchVoiceActivity?
    @Published private(set) var geometry: NotchGeometry?
    private var detail = false
    private var detailHeight: CGFloat = 490
    private var pointerTimer: Timer?
    private var completionWorkItem: DispatchWorkItem?
    private var completionMessage: String?
    private var executionBaseline = Set<UUID>()
    private var wasExecuting = false
    private var subscriptions = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    var expandedHeight: CGFloat {
        geometry?.expandedHeight(detail: detail, detailHeight: detailHeight) ?? cameraInset + (detail ? detailHeight : 66)
    }
    /// Displays without a camera housing get a small handle in the menu bar, never a painted notch.
    var drawsClosedNotch: Bool { quickMenuEnabled && geometry.map { !$0.hasCameraHousing } ?? false }

    init(model: CalshotModel) {
        self.model = model
        workspace = WebWorkspaceController(model: model, isNotch: true)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Calshot Quick Menu"
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.isMovableByWindowBackground = false; panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.onEscape = { [weak self] in if self?.model?.voiceSession.active == true { self?.model?.voiceSession.stop() }; self?.collapse() }
        workspace.onNotchLayout = { [weak self] detail, height in
            guard let self else { return }
            if let height { self.detailHeight = CGFloat(height) }
            self.detail = detail
            self.position()
        }
        workspace.onNotchCollapse = { [weak self] in self?.collapse() }
        workspace.onNotchExpand = { [weak self] in self?.openQuickMenu() }
        let content = NSHostingView(rootView: NotchExperienceView(controller: self))
        // The animated panel owns its bounds; SwiftUI must not force the final size early.
        content.sizingOptions = []
        panel.contentView = content
        Publishers.Merge(model.objectWillChange, model.calendarActions.objectWillChange)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshActivity() }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.position() }
        }
        // WebKit child views and key-window changes can interrupt SwiftUI hover
        // callbacks. Check the actual panel zone without monitoring keyboard input.
        pointerTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPointer() }
        }
        if let pointerTimer { RunLoop.main.add(pointerTimer, forMode: .common) }
        position()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--notch-preview") {
            DispatchQueue.main.async { [weak self] in self?.openQuickMenu() }
        }
#endif
    }
    func showVoice() {
        // Audio/status snapshots must never reopen a panel the pointer just left.
        refreshActivity(); position(); panel.orderFrontRegardless()
    }
    func show() {
        guard model?.notchEnabled != false || model?.voiceSession.active == true else { return hide() }
        refreshActivity(); position(); panel.orderFrontRegardless()
    }
    func showQuickPreview(image: NSImage, recordID: UUID, copiedToClipboard: Bool) {
        guard let model, let record = model.memoryRecords.first(where: { $0.id == recordID }) else { return }
        model.taskUsesNotch = true; model.restoreCalendarReview(record); openQuickMenu()
    }
    deinit {
        pointerTimer?.invalidate()
        completionWorkItem?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
    func hide() {
        collapse()
        panel.orderOut(nil)
        position(animated: false)
    }
    func collapse() {
        var next = presentation; next.collapse()
        apply(next)
    }
    func openQuickMenu() {
        guard model?.notchEnabled != false || voiceActivity != nil || model?.voiceSession.active == true else { return }
        model?.taskUsesNotch = true
        var next = presentation; next.open()
        apply(next)
        panel.makeKeyAndOrderFront(nil)
    }
    func pointerChanged(_ inside: Bool) {
        guard panel.isVisible else { return }
        // Child-view hover callbacks can be stale during animation. The actual pointer wins.
        updatePointer(hoverRegion.contains(NSEvent.mouseLocation))
    }
    private var hoverRegion: NSRect {
        Self.pointerRegion(panelFrame: panel.frame, targetFrame: targetFrame, expanded: isExpanded)
    }
    static func pointerRegion(panelFrame: NSRect, targetFrame: NSRect?, expanded: Bool) -> NSRect {
        let target = targetFrame ?? panelFrame
        // A shrinking panel must not retain an invisible hit area from its previous size.
        return expanded ? panelFrame.intersection(target) : target
    }
    private func checkPointer() {
        guard panel.isVisible else { return }
        updatePointer(hoverRegion.contains(NSEvent.mouseLocation))
    }
    private func updatePointer(_ inside: Bool, now: Date = .now) {
        // With the notch off, hovering never opens anything; an open voice panel still closes when the pointer leaves.
        guard quickMenuEnabled || presentation.isExpanded else { return }
        var next = presentation
        next.pointerChanged(inside, now: now, location: NSEvent.mouseLocation)
        next.advance(to: now)
        apply(next)
    }
    private func apply(_ next: NotchPresentationState) {
        guard next != presentation else { return }
        let closing = presentation.isExpanded && !next.isExpanded
        presentation = next
        workspace.setNotchExpanded(next.isExpanded)
        if closing {
            workspace.resetNotchPresentation()
            panel.resignKey()
        }
        if panel.isVisible { position() }
    }
    /// An open panel stays on its display. Otherwise prefer the built-in camera housing,
    /// then the menu bar display, so a reconnected or removed display never strands the notch.
    private var targetScreen: NSScreen? {
        let screens = NSScreen.screens
        if isExpanded, let current = panel.screen, screens.contains(current) { return current }
        return screens.first(where: { NotchGeometry($0).hasCameraHousing }) ?? screens.first ?? NSScreen.main
    }
    private func position(animated: Bool = true) {
        guard let screen = targetScreen else { return }
        let geometry = NotchGeometry(screen)
        // Assign only real changes: every published write re-renders the SwiftUI shell, and this runs on each model change.
        update(\.geometry, geometry)
        update(\.cameraInset, geometry.barHeight)
        update(\.expandedWidth, geometry.expandedWidth(detail: detail))
        update(\.launcherSize, voiceActivity.map { showsIsland($0) ? geometry.voiceIslandSize : geometry.voiceIndicatorSize }
               ?? (showsNotification ? geometry.notificationSize : geometry.closedSize))
        if webSize.height <= geometry.barHeight { update(\.webSize, geometry.voiceIndicatorSize) }
        let size = isExpanded ? NSSize(width: expandedWidth, height: expandedHeight) : launcherSize
        let frame = geometry.frame(for: size)
        // Frequent agent snapshots must not restart an in-flight transition.
        guard targetFrame != frame || !animated else { return }
        let previous = targetFrame
        targetFrame = frame
        let id = UUID(); transitionID = id
        let showsWeb = isExpanded || voiceActivity.map { !showsIsland($0) } == true
        if isExpanded { presentsExpandedContent = true }
        let shouldAnimate = animated && panel.isVisible && previous != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate else {
            panel.setFrame(frame, display: true)
            contentSize = size; visibleSize = size
            if showsWeb { update(\.webSize, size) }
            presentsExpandedContent = isExpanded
            return
        }
        // Resizing a window per frame re-lays out WebKit on the main thread and stutters. Instead the
        // window covers both shapes at once, and SwiftUI springs the clipped shape on the GPU.
        let cover = panel.frame.union(frame)
        if cover != panel.frame { panel.setFrame(cover, display: false) }
        contentSize = NSSize(width: max(visibleSize.width, size.width), height: max(visibleSize.height, size.height))
        if showsWeb { update(\.webSize, contentSize) }
        // Quick and settled: the island snaps out beside the notch, the panel drops a little slower, and
        // closing never bounces.
        let growing = size.width * size.height > visibleSize.width * visibleSize.height
        let spring: Animation = isExpanded ? .spring(response: 0.3, dampingFraction: 0.86)
            : growing ? .spring(response: 0.24, dampingFraction: 0.82) : .spring(response: 0.2, dampingFraction: 1)
        withAnimation(spring, completionCriteria: .logicallyComplete) {
            visibleSize = size
        } completion: { [weak self] in
            guard let self, self.transitionID == id else { return }
            self.panel.setFrame(frame, display: true)
            self.contentSize = size
            if self.isExpanded || self.voiceActivity.map({ !self.showsIsland($0) }) == true { self.update(\.webSize, size) }
            self.presentsExpandedContent = self.isExpanded
        }
    }
    /// A voice review needs the web controls while the notch is on; with it off, it is an island like the rest.
    func showsIsland(_ activity: NotchVoiceActivity) -> Bool { activity.usesIsland || !quickMenuEnabled }
    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<NotchExperienceController, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
    private func refreshActivity() {
        guard let model else { return }
        let session = model.voiceSession
        update(\.voiceActivity, NotchVoiceActivity.resolve(state: session.state, transmittingAudio: session.transmittingAudio,
                                                            needsAttention: (session.active && session.error != nil) || session.needsAcknowledgement || session.needsKey))
        update(\.colorScheme, model.appearanceMode.colorScheme)
        update(\.quickMenuEnabled, model.notchEnabled)
        let executing = model.isSaving
        if executing && !wasExecuting {
            executionBaseline = Set(model.calendarActions.proposals.filter { $0.isFinished && $0.receipt != nil }.map(\.id))
            completionWorkItem?.cancel(); completionMessage = nil
        }
        if !executing && wasExecuting {
            let written = model.calendarActions.proposals.filter { $0.isFinished && $0.receipt != nil && !executionBaseline.contains($0.id) }
            if !written.isEmpty {
                let operations = Set(written.map(\.operation))
                let verb = operations.count == 1 ? (operations.first == .create ? "added" : operations.first == .delete ? "removed" : operations.first == .move ? "moved" : "updated") : "changes saved"
                completionMessage = "\(written.count) \(verb)"
                let work = DispatchWorkItem { [weak self] in self?.completionMessage = nil; self?.refreshActivity() }
                completionWorkItem = work; DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            }
        }
        wasExecuting = executing
        update(\.activity, NotchActivity.resolve(model, completion: completionMessage))
        var next = presentation
        next.observe(activityKey: activity.notificationKey(model), notify: model.taskUsesNotch && activity.phase != .idle, now: .now)
        next.advance(to: .now)
        apply(next)
        if panel.isVisible { position() }
    }
}

/// Timing policy independent of task lifetime, window focus and model snapshots.
/// A hidden notification never skips, cancels, or approves the pending task.
struct NotchPresentationState: Equatable {
    /// Short enough to feel immediate, long enough that sweeping to the menu bar never opens it.
    static let hoverDelay: TimeInterval = 0.35
    /// Brief overshoots past the panel edge should not snap it shut.
    static let leaveGrace: TimeInterval = 0.5
    /// "Stay on the spot": moving farther than this while collapsed restarts the dwell.
    static let dwellTolerance: CGFloat = 8
    static let notificationDuration: TimeInterval = 4
    private(set) var isExpanded = false
    private(set) var pointerInside = false
    private(set) var notificationUntil: Date?
    private var hoverAt: Date?
    private var dwellAnchor: CGPoint?
    private var leaveAt: Date?
    private var activityKey: String?
    var showsNotification: Bool { notificationUntil != nil }
    mutating func pointerChanged(_ inside: Bool, now: Date, location: CGPoint? = nil) {
        if inside, pointerInside, !isExpanded, let location {
            // Passing over the notch on the way to the menu bar never opens it; resting on it does.
            if let anchor = dwellAnchor, hypot(location.x - anchor.x, location.y - anchor.y) > Self.dwellTolerance {
                dwellAnchor = location; hoverAt = now.addingTimeInterval(Self.hoverDelay)
            } else if dwellAnchor == nil { dwellAnchor = location }
        }
        guard pointerInside != inside else { return }
        pointerInside = inside
        dwellAnchor = inside ? location : nil
        if inside { leaveAt = nil; if !isExpanded { hoverAt = now.addingTimeInterval(Self.hoverDelay) } }
        else {
            hoverAt = nil
            if isExpanded { leaveAt = now.addingTimeInterval(Self.leaveGrace) }
        }
    }
    mutating func open(now: Date = .now) {
        isExpanded = true; hoverAt = nil; notificationUntil = nil
        // A keyboard/shortcut open can start with the pointer already outside. There may
        // never be a leave edge, so arm dismissal here rather than waiting for that edge.
        leaveAt = pointerInside ? nil : now.addingTimeInterval(Self.leaveGrace)
    }
    mutating func collapse() { isExpanded = false; hoverAt = nil; leaveAt = nil; notificationUntil = nil }
    mutating func observe(activityKey key: String?, notify: Bool, now: Date) {
        guard key != activityKey else { return }
        activityKey = key
        notificationUntil = notify && key != nil && !isExpanded ? now.addingTimeInterval(Self.notificationDuration) : nil
    }
    mutating func advance(to now: Date) {
        if let hoverAt, now >= hoverAt { open(now: now) }
        if let leaveAt, now >= leaveAt { collapse() }
        if let notificationUntil, now >= notificationUntil { self.notificationUntil = nil }
    }
}

/// Panel sizes for any display: MacBooks with a camera housing (any scaling),
/// Macs without one, and external displays whose menu bar height differs.
struct NotchGeometry: Equatable {
    static let minimumClosedWidth: CGFloat = 184
    let screenFrame: NSRect
    let visibleFrame: NSRect
    let hasCameraHousing: Bool
    /// Camera housing height, or the menu bar height on displays without one.
    let barHeight: CGFloat
    let closedWidth: CGFloat
    let centerX: CGFloat

    init(frame: NSRect, visibleFrame: NSRect, safeAreaTop: CGFloat, leftAuxiliaryWidth: CGFloat?, rightAuxiliaryWidth: CGFloat?, statusBarThickness: CGFloat) {
        screenFrame = frame
        self.visibleFrame = visibleFrame
        let housingWidth = leftAuxiliaryWidth.flatMap { left in rightAuxiliaryWidth.map { frame.width - left - $0 } }
        if safeAreaTop > 0, let housingWidth, housingWidth > 0, let left = leftAuxiliaryWidth {
            hasCameraHousing = true
            barHeight = safeAreaTop
            // Match the physical housing exactly; scaled resolutions change its width in points.
            closedWidth = housingWidth
            centerX = frame.minX + left + housingWidth / 2
        } else {
            hasCameraHousing = false
            // visibleFrame excludes the menu bar unless it hides automatically.
            let menuBar = frame.maxY - visibleFrame.maxY
            barHeight = (20...44).contains(menuBar) ? menuBar : max(24, statusBarThickness)
            closedWidth = min(Self.minimumClosedWidth, frame.width * 0.3)
            centerX = frame.midX
        }
    }

    init(_ screen: NSScreen) {
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
                  leftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width, rightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width,
                  statusBarThickness: NSStatusBar.system.thickness)
    }

    var closedSize: NSSize { NSSize(width: closedWidth, height: barHeight) }
    var notificationSize: NSSize { NSSize(width: min(max(340, closedWidth + 24), screenFrame.width - 32), height: barHeight + 26) }
    var voiceIndicatorSize: NSSize { NSSize(width: expandedWidth(detail: false), height: barHeight + 66) }
    /// Voice status at menu-bar height: wings beside the camera housing, or a short tab on other displays.
    var voiceIslandSize: NSSize {
        let width = hasCameraHousing ? closedWidth + Self.islandWing * 2 : 236
        return NSSize(width: min(width, screenFrame.width - 32), height: barHeight)
    }
    static let islandWing: CGFloat = 96
    /// Bottom corners of the closed shape, close to the physical housing.
    var closedCornerRadius: CGFloat { min(10, barHeight / 3) }
    func expandedWidth(detail: Bool) -> CGFloat {
        max(min(detail ? 560 : 520, screenFrame.width - 32), min(closedWidth + 48, screenFrame.width))
    }
    func expandedHeight(detail: Bool, detailHeight: CGFloat) -> CGFloat {
        guard detail else { return barHeight + 66 }
        // Stop above the Dock and keep a small gap on short displays.
        let available = screenFrame.maxY - visibleFrame.minY - barHeight - 12
        return barHeight + max(120, min(detailHeight, available))
    }
    /// Top-aligned and centred on the housing, kept inside the display.
    func frame(for size: NSSize) -> NSRect {
        let x = min(max(centerX - size.width / 2, screenFrame.minX), screenFrame.maxX - size.width)
        return NSRect(x: x, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }
}

/// Compact activity is independent of the hover-open control panel and never shows transcripts.
enum NotchVoiceActivity: String {
    case connecting, listening, thinking, speaking, review, attention
    /// Everything but a review is a native island at menu-bar height; a review needs the web controls.
    var usesIsland: Bool { self != .review }
    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .review: "Needs review"
        case .attention: "Check voice"
        }
    }
    static func resolve(state: VoiceSessionController.State, transmittingAudio: Bool, needsAttention: Bool = false) -> Self? {
        if transmittingAudio { return .listening }
        switch state {
        case .checking, .connecting: return needsAttention ? .attention : .connecting
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .waitingForReview: return .review
        default: return needsAttention ? .attention : nil
        }
    }
}

struct NotchActivity: Equatable {
    enum Phase: String { case idle, working, question, approval, failed, completed }
    let phase: Phase
    let label: String
    let symbol: String
    static let idle = NotchActivity(phase: .idle, label: "", symbol: "")
    @MainActor func notificationKey(_ model: CalshotModel) -> String? {
        guard phase != .idle else { return nil }
        let session = model.currentCaptureSessionID?.uuidString ?? ""
        let rows = model.calendarActions.proposals.filter { model.calendarActions.isInApprovalScope($0.id) }.map { $0.id.uuidString }.sorted().joined(separator: ",")
        let context: String
        switch phase {
        case .question: context = model.agentQuestion?.id.uuidString ?? ""
        case .approval: context = rows
        case .failed: context = (model.agentError ?? "") + ":" + String(model.screenCapturePermissionNeeded) + rows
        case .completed: context = label
        default: context = ""
        }
        return session + ":" + phase.rawValue + ":" + context
    }
    @MainActor static func resolve(_ model: CalshotModel, completion: String?) -> NotchActivity {
        if model.agentQuestion != nil { return .init(phase: .question, label: "Calshot has a question", symbol: "bubble.left") }
        let pending = model.calendarActions.proposals.filter {
            !$0.isFinished && model.calendarActions.isInApprovalScope($0.id)
                && ($0.isSelected || $0.state == .failed || model.agentIsWaitingForApproval)
        }
        if model.agentIsWaitingForApproval { return .init(phase: .approval, label: "\(pending.count) \(pending.count == 1 ? "event" : "events") to review", symbol: "checklist") }
        if model.isSaving || model.agentIsRunning || model.isRecognizing || model.isCapturing {
            return .init(phase: .working, label: model.isSaving ? "Saving approved changes" : model.isCapturing ? "Capturing screenshot" : model.isRecognizing ? "Reading screenshot" : model.agentStatus ?? "Calshot is working", symbol: "sparkles")
        }
        if model.agentError != nil || model.screenCapturePermissionNeeded { return .init(phase: .failed, label: "Task needs attention", symbol: "exclamationmark.circle") }
        if pending.contains(where: { $0.state == .failed }) { return .init(phase: .failed, label: "Some events didn't save", symbol: "exclamationmark.circle") }
        if let completion { return .init(phase: .completed, label: completion, symbol: "checkmark") }
        if !pending.isEmpty { return .init(phase: .approval, label: "\(pending.count) \(pending.count == 1 ? "event" : "events") to review", symbol: "checklist") }
        return .idle
    }
}

private struct NotchWebContent: NSViewRepresentable {
    let controller: WebWorkspaceController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct NotchExperienceView: View {
    @ObservedObject var controller: NotchExperienceController
    var body: some View {
        let showsWeb = controller.presentsExpandedContent || controller.voiceActivity.map { !controller.showsIsland($0) } == true
        ZStack(alignment: .top) {
            // Always attached, laid out at its open size and revealed by an animated clip: the panel drops down
            // without WebKit reflowing or re-attaching mid-animation.
            VStack(spacing: 0) {
                Color.black.frame(height: controller.cameraInset)
                NotchWebContent(controller: controller.workspace)
                    .frame(width: controller.webSize.width, height: max(0, controller.webSize.height - controller.cameraInset))
            }
            .frame(width: controller.webSize.width, height: controller.webSize.height, alignment: .top)
            .frame(width: controller.visibleSize.width, height: controller.visibleSize.height, alignment: .top)
            .background(.black)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
            .opacity(showsWeb ? 1 : 0)
            .allowsHitTesting(showsWeb)
            .accessibilityHidden(!showsWeb)
            if !showsWeb, let voice = controller.voiceActivity {
                Button { controller.openQuickMenu() } label: {
                    VoiceIsland(activity: voice, size: controller.launcherSize,
                                housingWidth: controller.geometry?.hasCameraHousing == true ? controller.geometry?.closedWidth ?? 0 : 0,
                                levels: { controller.voiceLevels })
                        .frame(width: controller.launcherSize.width, height: controller.launcherSize.height)
                        // Fixed content revealed by the animated clip, like the panel.
                        .frame(width: controller.visibleSize.width, height: controller.visibleSize.height)
                        .background(.black)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Calshot voice: \(voice.label)")
                .accessibilityHint("Opens voice controls")
                .help("Voice controls")
            } else if !showsWeb {
                if controller.showsNotification {
                    Button { controller.openQuickMenu() } label: {
                        HStack(spacing: 8) {
                            if controller.activity.phase == .working { ProgressView().controlSize(.mini) }
                            else { Image(systemName: controller.activity.symbol).foregroundStyle(controller.activity.phase == .completed ? .green : .white) }
                            Text(controller.activity.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }.foregroundStyle(.white).padding(.horizontal, 12).padding(.bottom, 6)
                            .frame(width: controller.launcherSize.width, height: controller.launcherSize.height, alignment: .bottom)
                            .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
                    }.buttonStyle(.plain).help("Open task in notch")
                } else {
                    // A physical housing already is the notch. Elsewhere Calshot never paints a fake one: a small
                    // handle in the menu bar marks where to rest the pointer.
                    ZStack(alignment: .top) {
                        Color.clear
                        if controller.drawsClosedNotch {
                            Capsule().fill(Color.primary.opacity(0.22))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                                .frame(width: 84, height: 6)
                                .padding(.top, 5)
                        }
                    }
                    .frame(width: controller.launcherSize.width, height: controller.launcherSize.height)
                    .accessibilityElement()
                    .accessibilityLabel("Calshot. Move the pointer here to capture or ask.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle()).onHover { controller.pointerChanged($0) }
        .preferredColorScheme(controller.colorScheme)
    }
}

/// Native voice status: label on the left wing, a level meter on the right, coloured per phase
/// (blue listens, violet thinks, green speaks). Drawn by SwiftUI, never by the web view.
private struct VoiceIsland: View {
    let activity: NotchVoiceActivity
    let size: NSSize
    let housingWidth: CGFloat
    let levels: () -> (input: Float, output: Float)
    var body: some View {
        HStack(spacing: 0) {
            Text(activity.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(activity.tint)
                .lineLimit(1)
                .id(activity)
                .transition(.opacity)
            Spacer(minLength: housingWidth + 12)
            if activity == .attention || activity == .review {
                Image(systemName: activity == .review ? "checklist" : "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(activity.tint)
            } else {
                VoiceIslandMeter(activity: activity, levels: levels).frame(width: 26, height: min(16, size.height - 10))
            }
        }
        .padding(.horizontal, 14)
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.14), value: activity)
    }
}

private struct VoiceIslandMeter: View {
    let activity: NotchVoiceActivity
    let levels: () -> (input: Float, output: Float)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            Canvas { graphics, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let count = 5, gap: CGFloat = 2.5
                let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
                let level = Self.level(activity, levels())
                for index in 0..<count {
                    let i = Double(index)
                    let shape: Double
                    switch activity {
                    case .listening, .speaking: shape = 0.6 + 0.4 * sin(t * 9 + i * 1.3)
                    case .thinking: shape = 0.5 + 0.5 * sin(t * 4.2 - i * 0.9)
                    default: shape = 0.5 + 0.5 * sin(t * 2.5)
                    }
                    let height = max(width, size.height * CGFloat(reduceMotion ? 0.35 : 0.18 + 0.82 * level * shape))
                    let bar = CGRect(x: CGFloat(index) * (width + gap), y: (size.height - height) / 2, width: width, height: height)
                    graphics.fill(Path(roundedRect: bar, cornerRadius: width / 2), with: .color(activity.tint))
                }
            }
        }
        .accessibilityHidden(true)
    }
    /// Microphone RMS is small; the speaker level is already scaled. Both map to 0–1 for the bars.
    static func level(_ activity: NotchVoiceActivity, _ levels: (input: Float, output: Float)) -> Double {
        switch activity {
        case .listening: min(1, Double(levels.input).squareRoot() * 2.2)
        case .speaking: min(1, max(0.25, Double(levels.output).squareRoot() * 1.1))
        case .thinking: 0.45
        default: 0.18
        }
    }
}

private extension NotchVoiceActivity {
    var tint: Color {
        switch self {
        case .listening: Color(red: 0.43, green: 0.66, blue: 1)
        case .thinking: Color(red: 0.79, green: 0.65, blue: 1)
        case .speaking: Color(red: 0.5, green: 0.89, blue: 0.66)
        case .attention, .review: Color(red: 0.95, green: 0.81, blue: 0.45)
        case .connecting: Color(white: 0.6)
        }
    }
}
