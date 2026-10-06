import AppKit
import SwiftUI

@MainActor
final class WorkspaceWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(model: CalshotModel) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1050, height: 720),
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
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        accessory.view = NSHostingView(rootView: WorkspaceTitlebarAccessory())
        accessory.view.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        window.addTitlebarAccessoryViewController(accessory)
        window.center()
        window.contentView = NSHostingView(rootView: CalshotWorkspaceView(model: model))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window.orderOut(nil) }

}
