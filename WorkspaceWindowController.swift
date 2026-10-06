import AppKit
import SwiftUI

@MainActor
final class WorkspaceWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(model: CalshotModel) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1050, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Calshot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 920, height: 650)
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: CalshotWorkspaceView(model: model))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window.orderOut(nil) }
}
