import AppKit
import Combine
import SwiftUI
import WebKit

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Compact native shell; the embedded React view shares the workspace's validated tools.
@MainActor
final class NotchExperienceController: ObservableObject {
    private let panel: NotchPanel
    let workspace: WebWorkspaceController
    private weak var model: CalshotModel?
    @Published private(set) var isExpanded = false
    @Published private(set) var launcherSize = NSSize(width: 184, height: 24)
    @Published private(set) var expandedWidth: CGFloat = 520
    @Published private(set) var cameraInset: CGFloat = 24
    @Published private(set) var activity = NotchActivity.idle
    private var detail = false
    private var detailHeight: CGFloat = 490
    private var pointerInside = false
    private var collapseWorkItem: DispatchWorkItem?
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
            let opening = detail && !self.detail
            if let height { self.detailHeight = CGFloat(height) }
            self.detail = detail
            if opening && model.taskUsesNotch && !model.isCapturing { self.isExpanded = true; self.panel.orderFrontRegardless() }
            self.position()
        }
        workspace.onNotchCollapse = { [weak self] in self?.collapse() }
        panel.contentView = NSHostingView(rootView: NotchExperienceView(controller: self, model: model))
        Publishers.Merge(model.objectWillChange, model.calendarActions.objectWillChange)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshActivity() }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.position() }
        }
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
    func hide() { collapse(); panel.orderOut(nil) }
    func collapse() {
        collapseWorkItem?.cancel(); isExpanded = false; workspace.resetNotchPresentation(); panel.resignKey(); position()
    }
    func openQuickMenu() {
        model?.taskUsesNotch = true
        isExpanded = true; position(); panel.makeKeyAndOrderFront(nil)
    }
    func pointerChanged(_ inside: Bool) {
        pointerInside = inside; collapseWorkItem?.cancel()
        if inside { isExpanded = true; position() }
        else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.pointerInside, !self.panel.isKeyWindow else { return }
                self.collapse()
            }
            collapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
    private func position() {
        let screen = panel.screen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }
        cameraInset = max(24, screen.safeAreaInsets.top)
        expandedWidth = min(detail ? 560 : 520, screen.frame.width - 32)
        var closedWidth: CGFloat = 184
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            closedWidth = max(closedWidth, right.minX - left.maxX)
        }
        launcherSize = NSSize(width: activity.phase == .idle ? closedWidth : max(340, closedWidth + 24), height: activity.phase == .idle ? cameraInset : cameraInset + 26)
        let size = isExpanded ? NSSize(width: expandedWidth, height: expandedHeight) : launcherSize
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
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
        let previous = activity.phase
        activity = NotchActivity.resolve(model, completion: completionMessage)
        if model.taskUsesNotch, previous != activity.phase, activity.phase == .question || activity.phase == .approval {
            isExpanded = true; panel.orderFrontRegardless()
        }
        if panel.isVisible { position() }
    }
}

struct NotchActivity: Equatable {
    enum Phase { case idle, working, question, approval, failed, completed }
    let phase: Phase
    let label: String
    let symbol: String
    static let idle = NotchActivity(phase: .idle, label: "", symbol: "")
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
            if controller.isExpanded {
                VStack(spacing: 0) {
                    Color.black.frame(height: controller.cameraInset)
                    NotchWebContent(controller: controller.workspace)
                }
                .frame(width: controller.expandedWidth, height: controller.expandedHeight)
                .background(.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
            } else if controller.activity.phase != .idle {
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
        .contentShape(Rectangle()).onHover { controller.pointerChanged($0) }
        .preferredColorScheme(model.appearanceMode.colorScheme)
    }
}
