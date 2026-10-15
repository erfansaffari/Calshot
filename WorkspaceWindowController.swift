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
        // Keep the native titlebar controls in their standard position and put
        // Calshot's compact brand/sidebar control in the titlebar accessory area.
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 920, height: 650)
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.appearance = nil
        window.delegate = self
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--compact-workspace") { window.setContentSize(NSSize(width: 920, height: 650)) }
#endif
        window.center()
        if Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebUI") != nil {
            let workspace = WebWorkspaceController(model: model)
            webWorkspace = workspace
            window.contentView = workspace.webView
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
