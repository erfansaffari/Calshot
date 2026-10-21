import AppKit
import Combine
import QuartzCore
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
    @Published private(set) var expandedWidth: CGFloat = 520
    @Published private(set) var cameraInset: CGFloat = 24
    @Published private(set) var activity = NotchActivity.idle
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
        let available = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 700
        return cameraInset + (detail ? min(detailHeight, available - cameraInset - 24) : 66)
    }

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
        panel.onEscape = { [weak self] in self?.collapse() }
        workspace.onNotchLayout = { [weak self] detail, height in
            guard let self else { return }
            if let height { self.detailHeight = CGFloat(height) }
            self.detail = detail
            self.position()
        }
        workspace.onNotchCollapse = { [weak self] in self?.collapse() }
        let content = NSHostingView(rootView: NotchExperienceView(controller: self, model: model))
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
    func show() { refreshActivity(); position(); panel.orderFrontRegardless() }
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
        model?.taskUsesNotch = true
        var next = presentation; next.open()
        apply(next)
        panel.makeKeyAndOrderFront(nil)
    }
    func pointerChanged(_ inside: Bool) {
        guard panel.isVisible, model?.isCapturing != true else { return }
        // Moving from the native bezel into WebKit is still inside the notch.
        updatePointer(inside || hoverRegion.contains(NSEvent.mouseLocation))
    }
    private var hoverRegion: NSRect {
        let bounds = panel.frame.union(targetFrame ?? panel.frame)
        // The camera itself cannot receive pointer events. Include a small landing
        // strip below it, so approaching from the desktop is easy and reliable.
        return isExpanded ? bounds : bounds.insetBy(dx: -24, dy: -12)
    }
    private func checkPointer() {
        guard panel.isVisible, model?.isCapturing != true else { return }
        updatePointer(hoverRegion.contains(NSEvent.mouseLocation))
    }
    private func updatePointer(_ inside: Bool, now: Date = .now) {
        var next = presentation
        next.pointerChanged(inside, now: now)
        next.advance(to: now)
        apply(next)
    }
    private func apply(_ next: NotchPresentationState) {
        guard next != presentation else { return }
        let closing = presentation.isExpanded && !next.isExpanded
        presentation = next
        if closing {
            workspace.resetNotchPresentation()
            panel.resignKey()
        }
        if panel.isVisible { position() }
    }
    private func position(animated: Bool = true) {
        let screen = panel.screen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }
        cameraInset = max(24, screen.safeAreaInsets.top)
        expandedWidth = min(detail ? 560 : 520, screen.frame.width - 32)
        var closedWidth: CGFloat = 184
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            closedWidth = max(closedWidth, right.minX - left.maxX)
        }
        launcherSize = NSSize(width: showsNotification ? max(340, closedWidth + 24) : closedWidth, height: showsNotification ? cameraInset + 26 : cameraInset)
        let size = isExpanded ? NSSize(width: expandedWidth, height: expandedHeight) : launcherSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        // Frequent agent snapshots must not restart an in-flight transition.
        guard targetFrame != frame || !animated else { return }
        let previous = targetFrame
        targetFrame = frame
        let id = UUID(); transitionID = id
        if isExpanded { presentsExpandedContent = true }
        let shouldAnimate = animated && panel.isVisible && previous != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate else {
            panel.setFrame(frame, display: true)
            presentsExpandedContent = isExpanded
            return
        }
        let growing = frame.height > panel.frame.height || frame.width > panel.frame.width
        NSAnimationContext.runAnimationGroup { context in
            context.duration = isExpanded ? (growing ? 0.22 : 0.24) : 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.18, 1)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.transitionID == id else { return }
                self.presentsExpandedContent = self.isExpanded
            }
        }
    }
    private func refreshActivity() {
        guard let model else { return }
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
        activity = NotchActivity.resolve(model, completion: completionMessage)
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
    static let hoverDelay: TimeInterval = 0.08
    static let leaveGrace: TimeInterval = 0.35
    static let notificationDuration: TimeInterval = 4
    private(set) var isExpanded = false
    private(set) var pointerInside = false
    private(set) var notificationUntil: Date?
    private var hoverAt: Date?
    private var leaveAt: Date?
    private var activityKey: String?
    var showsNotification: Bool { notificationUntil != nil }
    mutating func pointerChanged(_ inside: Bool, now: Date) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        if inside { leaveAt = nil; if !isExpanded { hoverAt = now.addingTimeInterval(Self.hoverDelay) } }
        else {
            hoverAt = nil
            if isExpanded { leaveAt = now.addingTimeInterval(Self.leaveGrace) }
        }
    }
    mutating func open() { isExpanded = true; hoverAt = nil; leaveAt = nil; notificationUntil = nil }
    mutating func collapse() { isExpanded = false; hoverAt = nil; leaveAt = nil; notificationUntil = nil }
    mutating func observe(activityKey key: String?, notify: Bool, now: Date) {
        guard key != activityKey else { return }
        activityKey = key
        notificationUntil = notify && key != nil && !isExpanded ? now.addingTimeInterval(Self.notificationDuration) : nil
    }
    mutating func advance(to now: Date) {
        if let hoverAt, now >= hoverAt { open() }
        if let leaveAt, now >= leaveAt { collapse() }
        if let notificationUntil, now >= notificationUntil { self.notificationUntil = nil }
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
        let pending = model.calendarActions.proposals.filter { !$0.isFinished && model.calendarActions.isInApprovalScope($0.id) }
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
    @ObservedObject var model: CalshotModel
    var body: some View {
        Group {
            if controller.presentsExpandedContent {
                VStack(spacing: 0) {
                    Color.black.frame(height: controller.cameraInset)
                    NotchWebContent(controller: controller.workspace)
                }
                .frame(width: controller.expandedWidth, height: controller.expandedHeight, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
            } else if controller.showsNotification {
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
                Color.clear.frame(width: controller.launcherSize.width, height: controller.launcherSize.height)
                    .accessibilityLabel("Calshot. Move the pointer here to capture or ask.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle()).onHover { controller.pointerChanged($0) }
        .preferredColorScheme(model.appearanceMode.colorScheme)
    }
}
