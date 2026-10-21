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

/// Native file dragging hands the installed bundle URL to System Settings; it never grants access.
struct ScreenRecordingPermissionHelp: View {
    @State private var allowed = CGPreflightScreenCaptureAccess()
    private let appURL = Bundle.main.bundleURL
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable().frame(width: 76, height: 76)
                .onDrag { NSItemProvider(object: appURL as NSURL) }
                .accessibilityLabel("Calshot app. Drag to Screen Recording settings.")
                .help("Drag Calshot into the app list in System Settings")
            Text(allowed ? "Screen Recording is allowed" : "Drag Calshot into the app list")
                .font(.title3.weight(.semibold))
            Text(allowed ? "You can return to Calshot and capture your screen." : "In Privacy & Security → Screen & System Audio Recording, drag the icon above into the list, or use + to add Calshot from Applications. Then turn Calshot on.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("If macOS asks, quit and reopen Calshot to finish. After an update, you may need to remove an old Calshot entry and add this copy again.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            Button("Check access") { allowed = CGPreflightScreenCaptureAccess() }
        }.padding(24).frame(width: 420, height: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in allowed = CGPreflightScreenCaptureAccess() }
    }
}
