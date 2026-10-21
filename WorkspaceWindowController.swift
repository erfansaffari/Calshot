import AppKit
import SwiftUI

@MainActor
final class WorkspaceWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var webWorkspace: WebWorkspaceController?

    init(model: CalshotModel) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
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
            let webView = workspace.webView!
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
            let dragRegion = WorkspaceDragRegion(frame: NSRect(x: 84, y: container.bounds.height - 24, width: max(0, container.bounds.width - 84), height: 24))
            dragRegion.autoresizingMask = [.width, .minYMargin]
            container.addSubview(dragRegion)
            window.contentView = container
        } else {
            // Native recovery surface remains available when frontend resources are absent.
            window.contentView = NSHostingView(rootView: CalshotWorkspaceView(model: model))
        }
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
