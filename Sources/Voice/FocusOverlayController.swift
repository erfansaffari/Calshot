import AppKit
import QuartzCore

struct FocusMark: Equatable, Sendable {
    enum Kind: String, Sendable { case stroke, point }
    let kind: Kind
    /// AppKit global screen coordinates, in points (bottom-left origin).
    let points: [CGPoint]
    let displayID: CGDirectDisplayID
    let timestamp: Date

    static func classify(_ points: [CGPoint], threshold: CGFloat = 4) -> Kind {
        guard let first = points.first else { return .point }
        return points.contains { hypot($0.x - first.x, $0.y - first.y) >= threshold } ? .stroke : .point
    }
}

/// Shared geometry for live ink and the image annotation. Quadratic segments never overshoot
/// the sampled bounds, and retain the exact first and last points.
enum FocusInk {
    // Use the packaged shared brand token for both overlay and frame ink. Screen content
    // has its own appearance, so keep this accent stable rather than recoloring the image.
    static let color: CGColor = {
        let value = PermissionPalette(dark: false).values["--accent"] ?? "#0760ed"
        let rgb = UInt64(value.dropFirst(), radix: 16) ?? 0x0760ed
        return CGColor(red: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }()

    static func path(points: [CGPoint], kind: FocusMark.Kind, pointRadius: CGFloat = 7) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        if kind == .point {
            path.addEllipse(in: CGRect(x: first.x - pointRadius, y: first.y - pointRadius,
                                       width: pointRadius * 2, height: pointRadius * 2))
            return path
        }
        path.move(to: first)
        for index in 1..<points.count {
            let previous = points[index - 1], current = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2), control: previous)
        }
        if let last = points.last { path.addLine(to: last) }
        return path
    }

    static func animationKeys(kind: FocusMark.Kind, reduceMotion: Bool) -> [String] {
        reduceMotion ? [] : (kind == .point ? ["pulse", "settle"] : ["draw", "settle"])
    }
}

/// One panel per display, including full-screen Spaces. Only drawing mode intercepts input.
/// Retain for the voice session; end() clears marks and tears down panels/observers/timer.
@MainActor
final class FocusOverlayController {
    private(set) var marks: [FocusMark] = []
    private(set) var isActive = false
    private(set) var isDrawing = false
    var onCancel: (() -> Void)?
    var onMarksChanged: (([FocusMark]) -> Void)?
    private var explicitDrawing = false
    private var panels: [FocusPanel] = []
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    func begin() {
        guard !isActive else { return }
        isActive = true
        rebuildPanels()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildPanels() }
        }
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMotion() }
        }
        // Reading modifier state needs no Accessibility/Input Monitoring grant. Poll in common
        // modes so Option release is handled even while AppKit tracks a drag in another app.
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateDrawing() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive, event.keyCode == 53,
                  self.isDrawing || self.panels.contains(where: \.isKeyWindow) else { return event }
            self.onCancel?()
            return nil
        }
        updateDrawing()
    }

    func end() {
        explicitDrawing = false
        guard isActive else { return }
        isActive = false
        timer?.invalidate(); timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        screenObserver = nil; motionObserver = nil; keyMonitor = nil
        panels.forEach { $0.orderOut(nil); $0.contentView = nil }
        panels.removeAll()
        explicitDrawing = false; isDrawing = false
        clearMarks()
    }

    func setDrawing(_ drawing: Bool) {
        explicitDrawing = drawing
        updateDrawing()
    }

    func clearMarks() {
        marks.removeAll()
        for panel in panels { (panel.contentView as? FocusInkView)?.clear() }
        onMarksChanged?(marks)
    }

    private func updateDrawing() {
        guard isActive else { return }
        let drawing = explicitDrawing || NSEvent.modifierFlags.contains(.option)
        guard drawing != isDrawing else { return }
        isDrawing = drawing
        for panel in panels {
            panel.drawingEnabled = drawing
            panel.ignoresMouseEvents = !drawing
            if !drawing {
                (panel.contentView as? FocusInkView)?.finishStroke()
                if panel.isKeyWindow { panel.resignKey() }
            }
        }
        if drawing {
            let panel = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first
            panel?.makeKey()
            panel?.makeFirstResponder(panel?.contentView)
        }
    }

    private func rebuildPanels() {
        guard isActive else { return }
        // Finish any in-flight stroke before moving/removing its display geometry.
        panels.forEach { ($0.contentView as? FocusInkView)?.finishStroke(); $0.orderOut(nil); $0.contentView = nil }
        panels = NSScreen.screens.map { screen in
            let panel = FocusPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false, screen: screen)
            panel.title = "Calshot screen focus"
            panel.isReleasedWhenClosed = false
            panel.level = .mainMenu + 4
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.ignoresMouseEvents = true
            let view = FocusInkView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                    displayID: screen.focusDisplayID, screenOrigin: screen.frame.origin,
                                    scale: screen.backingScaleFactor)
            view.onMark = { [weak self] mark in
                guard let self, self.isActive else { return }
                self.marks.append(mark); self.onMarksChanged?(self.marks)
            }
            panel.contentView = view
            // Reconstruct settled marks without replaying animations after display changes.
            marks.filter { $0.displayID == screen.focusDisplayID }.forEach { view.show($0, animated: false) }
            panel.orderFrontRegardless()
            return panel
        }
        isDrawing = false
        updateDrawing()
    }

    private func refreshMotion() {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        panels.forEach { ($0.contentView as? FocusInkView)?.removeAnimations() }
    }

    deinit {
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        // NSWindow teardown is on the main actor, just like every public entry point.
        let windows = panels
        Task { @MainActor in windows.forEach { $0.orderOut(nil); $0.contentView = nil } }
    }
}

@MainActor
private final class FocusPanel: NSPanel {
    var drawingEnabled = false
    override var canBecomeKey: Bool { drawingEnabled }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FocusInkView: NSView {
    let displayID: CGDirectDisplayID
    let screenOrigin: CGPoint
    let scale: CGFloat
    var onMark: ((FocusMark) -> Void)?
    private var points: [CGPoint] = []
    private var current: CAShapeLayer?
    private var ink: [CAShapeLayer] = []
    private let edge = CAShapeLayer()
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: CGRect, displayID: CGDirectDisplayID, screenOrigin: CGPoint, scale: CGFloat) {
        self.displayID = displayID; self.screenOrigin = screenOrigin; self.scale = scale
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsScale = scale
        edge.path = CGPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), cornerWidth: 14, cornerHeight: 14, transform: nil)
        edge.fillColor = nil; edge.strokeColor = FocusInk.color.copy(alpha: 0.3); edge.lineWidth = 2
        edge.shadowColor = FocusInk.color; edge.shadowRadius = 12; edge.shadowOpacity = 0.55; edge.shadowOffset = .zero
        edge.contentsScale = scale
        layer?.addSublayer(edge)
        setAccessibilityLabel("Calshot can see this screen. Hold Option to draw; Escape to end.")
    }
    required init?(coder: NSCoder) { nil }

    private func newLayer() -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.fillColor = nil; shape.strokeColor = FocusInk.color; shape.lineWidth = 3
        shape.lineCap = .round; shape.lineJoin = .round; shape.contentsScale = scale
        shape.shadowColor = FocusInk.color; shape.shadowRadius = 5; shape.shadowOpacity = 0.65; shape.shadowOffset = .zero
        layer?.addSublayer(shape); ink.append(shape)
        return shape
    }
    private func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - screenOrigin.x, y: point.y - screenOrigin.y) }
    private func eventPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: screenOrigin.x + min(max(0, point.x), bounds.width),
                       y: screenOrigin.y + min(max(0, point.y), bounds.height))
    }
    override func mouseDown(with event: NSEvent) {
        points = [eventPoint(event)]; current = newLayer()
        updatePath()
    }
    override func mouseDragged(with event: NSEvent) {
        guard current != nil else { return }
        points.append(eventPoint(event)); updatePath()
    }
    override func mouseUp(with event: NSEvent) {
        guard current != nil else { return }
        points.append(eventPoint(event)); finishStroke()
    }
    private func updatePath() {
        guard let current else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        current.path = FocusInk.path(points: points.map(local), kind: FocusMark.classify(points))
        CATransaction.commit()
        if FocusInk.animationKeys(kind: .stroke, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion).contains("draw"), points.count > 1 {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = max(0, 1 - 1 / Double(points.count)); draw.toValue = 1; draw.duration = 0.06
            current.add(draw, forKey: "draw")
        }
    }
    func finishStroke() {
        guard let current, let first = points.first else { return }
        let kind = FocusMark.classify(points)
        let mark = FocusMark(kind: kind, points: kind == .point ? [first] : points, displayID: displayID, timestamp: Date())
        current.path = FocusInk.path(points: mark.points.map(local), kind: kind)
        animate(current, kind: kind)
        self.current = nil; points = []
        onMark?(mark)
    }
    func show(_ mark: FocusMark, animated: Bool) {
        let shape = newLayer()
        shape.path = FocusInk.path(points: mark.points.map(local), kind: mark.kind)
        if animated { animate(shape, kind: mark.kind) } else { shape.opacity = 0.35 }
    }
    private func animate(_ shape: CAShapeLayer, kind: FocusMark.Kind) {
        let keys = FocusInk.animationKeys(kind: kind, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard !keys.isEmpty else { return }
        if keys.contains("pulse") {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.35; pulse.duration = 0.3; pulse.autoreverses = true; pulse.repeatCount = 2
            shape.add(pulse, forKey: "pulse")
        }
        shape.opacity = 0.35
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0.35; fade.beginTime = CACurrentMediaTime() + 2.5; fade.duration = 1.5
        fade.fillMode = .backwards
        shape.add(fade, forKey: "settle")
    }
    func clear() { current = nil; points = []; ink.forEach { $0.removeFromSuperlayer() }; ink = [] }
    func removeAnimations() { ink.forEach { $0.removeAllAnimations(); $0.opacity = 1 } }
}
