import AppKit
import SwiftUI
import Combine

@MainActor
final class WorkspaceWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var webWorkspace: WebWorkspaceController?
    private weak var model: CalshotModel?
    private var material: NSView?
    private var materialObservation: AnyCancellable?
    private var accessibilityObserver: NSObjectProtocol?

    init(model: CalshotModel) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.model = model
        super.init()
        window.title = "Calshot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // Keep traffic lights, but let the workspace paint through the titlebar.
        // A narrow native drag region handles movement without swallowing web controls.
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 920, height: 650)
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.appearance = nil
        window.delegate = self
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--compact-workspace") { window.setContentSize(NSSize(width: 920, height: 650)) }
#endif
        window.setFrameAutosaveName("CalshotWorkspace")
        window.center()
        if Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebUI") != nil {
            let workspace = WebWorkspaceController(model: model)
            webWorkspace = workspace
            let container = NSView(frame: window.contentView?.bounds ?? .zero)
            let background: NSView
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: container.bounds)
                glass.style = .regular
                glass.cornerRadius = 16
                // Neutral tint so glass stays dark in dark appearance while the windows behind still show.
                glass.tintColor = NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.black.withAlphaComponent(0.2) : NSColor.white.withAlphaComponent(0.15)
                }
                background = glass
            } else {
                let glass = NSVisualEffectView(frame: container.bounds)
                glass.material = .underWindowBackground
                glass.blendingMode = .behindWindow
                glass.state = .followsWindowActiveState
                background = glass
            }
            background.autoresizingMask = [.width, .height]
            material = background
            container.addSubview(background)
            let webView = workspace.webView!
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
            let dragRegion = WorkspaceDragRegion(frame: NSRect(x: 84, y: container.bounds.height - 24, width: max(0, container.bounds.width - 84), height: 24))
            dragRegion.autoresizingMask = [.width, .minYMargin]
            container.addSubview(dragRegion)
            window.contentView = container
            materialObservation = model.$glassAppearance.sink { [weak self] value in self?.applyMaterial(value) }
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let model = self.model else { return }
                    self.applyMaterial(model.glassAppearance)
                }
            }
        } else {
            // Native recovery surface remains available when frontend resources are absent.
            window.contentView = NSHostingView(rootView: CalshotWorkspaceView(model: model))
        }
    }

    private func applyMaterial(_ value: GlassAppearance) {
        let enabled = value.enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        material?.isHidden = !enabled
        window.isOpaque = !enabled
        window.backgroundColor = enabled ? .clear : .windowBackgroundColor
        window.invalidateShadow()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window.orderOut(nil) }

}

/// Transparent header strip; controls below it keep their normal WebKit gestures.
@MainActor
private final class WorkspaceDragRegion: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
