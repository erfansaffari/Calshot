import AppKit
import SwiftUI

// Settings tracking and native file dragging adapted from PermissionFlow (MIT).
// See ThirdPartyNotices/PermissionFlow.txt. No Accessibility permission is requested.
@MainActor
final class ScreenPermissionFlowController: NSObject, NSWindowDelegate, ObservableObject {
    @Published var allowed = CGPreflightScreenCaptureAccess()
    private var panel: PermissionPanel?
    private var timer: Timer?
    private var started = Date()
    private var sawSettings = false
    private var dragging = false
    private var preview = false
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    func show(preview: Bool = false) {
        self.preview = preview
        started = Date()
        sawSettings = false
        allowed = CGPreflightScreenCaptureAccess()
        if panel == nil {
            let panel = PermissionPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 286),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Calshot Screen Recording"
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            let host = NSHostingView(rootView: PermissionHelperView(flow: self))
            host.sizingOptions = []
            panel.contentView = host
            self.panel = panel
        }
        if !preview { openSettings() }
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        panel?.center()
        panel?.orderFrontRegardless()
        refresh()
#if DEBUG
        if preview { panel?.makeKeyAndOrderFront(nil) }
#endif
    }

    func openSettings() { preview = false; NSWorkspace.shared.open(Self.settingsURL) }
    func checkAccess() { allowed = CGPreflightScreenCaptureAccess() }
    func close() { timer?.invalidate(); timer = nil; panel?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { close() }
    func setDragging(_ value: Bool) {
        dragging = value
        panel?.ignoresMouseEvents = value
    }

    private func refresh() {
        checkAccess()
        guard !dragging, let panel else { return }
        if preview { return }
        guard let settings = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }) else {
            if sawSettings { close() }
            return
        }
        let windows = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == settings.processIdentifier &&
            ($0[kCGWindowLayer as String] as? Int) == 0
        }
        let candidates: [(CGRect, Bool)] = windows.compactMap { item in
            guard let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 320, rect.height > 240 else { return nil }
            return (rect, (item[kCGWindowIsOnscreen as String] as? Bool) == true)
        }
        guard let candidate = candidates.filter({ $0.1 }).max(by: { $0.0.width * $0.0.height < $1.0.width * $1.0.height }) else {
            if candidates.isEmpty, sawSettings, Date().timeIntervalSince(started) > 2 { close() }
            else if !candidates.isEmpty { panel.orderOut(nil) }
            return
        }
        sawSettings = true
        let frame = PermissionHelperGeometry.appKitFrame(candidate.0, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
        let screen = NSScreen.screens.max { a, b in
            a.frame.intersection(frame).width * a.frame.intersection(frame).height < b.frame.intersection(frame).width * b.frame.intersection(frame).height
        } ?? NSScreen.main
        guard let screen else { return }
        let target = PermissionHelperGeometry.placement(settings: frame, visible: screen.visibleFrame, size: panel.frame.size)
        if panel.frame != target { panel.setFrame(target, display: true) }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front == "com.apple.systempreferences" || front == Bundle.main.bundleIdentifier {
            panel.orderFrontRegardless()
        } else { panel.orderOut(nil) }
    }
}

struct PermissionHelperGeometry {
    static func appKitFrame(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }
    static func placement(settings: CGRect, visible: CGRect, size: CGSize) -> CGRect {
        let safe = visible.insetBy(dx: 12, dy: 12)
        let width = min(size.width, safe.width), height = min(size.height, safe.height)
        var point = CGPoint(x: settings.maxX - width, y: settings.minY - height - 12)
        if point.y < safe.minY {
            if settings.maxX + width + 12 <= safe.maxX { point = CGPoint(x: settings.maxX + 12, y: settings.maxY - height) }
            else if settings.minX - width - 12 >= safe.minX { point = CGPoint(x: settings.minX - width - 12, y: settings.maxY - height) }
            else { point.y = safe.minY }
        }
        return CGRect(x: min(max(point.x, safe.minX), safe.maxX - width),
                      y: min(max(point.y, safe.minY), safe.maxY - height), width: width, height: height)
    }
}

private final class PermissionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Reads the same semantic palette shipped to WebKit, rather than maintaining a native copy.
struct PermissionPalette {
    let values: [String: String]
    init(dark: Bool, css: String? = nil) {
        let source = css ?? Bundle.main.url(forResource: "native-tokens", withExtension: "css", subdirectory: "WebUI")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let selector = dark ? #":root\[data-appearance="dark"\]\s*\{([^}]+)\}"# : #":root\s*\{([^}]+)\}"#
        let regex = try! NSRegularExpression(pattern: selector)
        var values: [String: String] = [:]
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range(at: 1), in: source) else { continue }
            for entry in source[range].split(separator: ";") {
                let pair = entry.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if pair.count == 2 { values[pair[0]] = pair[1] }
            }
        }
        self.values = values
    }
    func color(_ name: String, fallback: NSColor) -> Color {
        guard let value = values[name] else { return Color(nsColor: fallback) }
        if value.hasPrefix("#"), let hex = UInt64(value.dropFirst(), radix: 16), [7, 9].contains(value.count) {
            let alpha = value.count == 9 ? Double(hex & 255) / 255 : 1
            let rgb = value.count == 9 ? hex >> 8 : hex
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: alpha)
        }
        if value.hasPrefix("rgba("), let end = value.firstIndex(of: ")") {
            let components = value[value.index(value.startIndex, offsetBy: 5)..<end].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if components.count == 4 { return Color(.sRGB, red: components[0]/255, green: components[1]/255, blue: components[2]/255, opacity: components[3]) }
        }
        return Color(nsColor: fallback)
    }
}

private struct PermissionHelperView: View {
    @ObservedObject var flow: ScreenPermissionFlowController
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let palette = PermissionPalette(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Screen Recording", systemImage: "rectangle.dashed.badge.record").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { flow.close() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("Close permission helper").keyboardShortcut(.cancelAction)
            }
            Text(flow.allowed ? "Access allowed" : "Drag Calshot into the app list, then turn its switch on.")
                .font(.system(size: 13)).foregroundStyle(flow.allowed ? palette.color("--success", fallback: .systemGreen) : palette.color("--muted", fallback: .secondaryLabelColor))
            PermissionAppDragSource(onDragging: flow.setDragging)
                .frame(height: 62)
                .background(palette.color("--surface-inset", fallback: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.color("--line", fallback: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            Text(flow.allowed ? "Return to Calshot to capture. If macOS asks, quit and reopen the app first." : "You can also use + to add this copy. If an old entry remains after an update, remove it and add Calshot again. Quit and reopen if macOS asks.")
                .font(.system(size: 11)).foregroundStyle(palette.color("--muted", fallback: .secondaryLabelColor)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                Button("Settings") { flow.openSettings() }.accessibilityLabel("Open Screen Recording settings")
                Spacer(minLength: 0)
                Button(flow.allowed ? "Done" : "Check access") { if flow.allowed { flow.close() } else { flow.checkAccess() } }
                    .buttonStyle(.borderedProminent).tint(palette.color("--primary", fallback: .systemBlue))
                    .keyboardShortcut(.defaultAction)
            }.controlSize(.small)
        }
        .padding(16)
        .foregroundStyle(palette.color("--text", fallback: .labelColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.color("--surface-solid", fallback: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(palette.color("--line", fallback: .separatorColor)))
    }
}

private struct PermissionAppDragSource: NSViewRepresentable {
    let onDragging: (Bool) -> Void
    func makeNSView(context: Context) -> PermissionAppDragView { PermissionAppDragView(onDragging: onDragging) }
    func updateNSView(_ nsView: PermissionAppDragView, context: Context) {}
}

@MainActor
private final class PermissionAppDragView: NSView, NSDraggingSource {
    private let onDragging: (Bool) -> Void
    private var down: NSPoint?
    init(onDragging: @escaping (Bool) -> Void) {
        self.onDragging = onDragging
        super.init(frame: .zero)
        let content = NSHostingView(rootView: HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Calshot").font(.system(size: 13, weight: .semibold))
                Text("Drag app to System Settings").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
        }.padding(.horizontal, 12).allowsHitTesting(false))
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Calshot app. Drag to the Screen Recording app list. Alternatively use Show in Finder.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { down = convert(event.locationInWindow, from: nil) }
    override func mouseUp(with event: NSEvent) { down = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - down.x, point.y - down.y) > 4 else { return }
        self.down = nil
        let item = NSDraggingItem(pasteboardWriter: PermissionAppPasteboardWriter(url: Bundle.main.bundleURL))
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: icon)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { onDragging(true) }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { onDragging(false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

final class PermissionAppPasteboardWriter: NSObject, NSPasteboardWriting {
    let url: URL
    init(url: URL) { self.url = url }
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] { [.fileURL, .URL, .init("NSFilenamesPboardType"), .string] }
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL: return url.absoluteString
        case .init("NSFilenamesPboardType"): return [url.path]
        case .string: return url.path
        default: return nil
        }
    }
}
