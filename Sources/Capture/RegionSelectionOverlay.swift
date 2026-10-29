import AppKit
import CoreGraphics

/// A full-display screenshot selector. The completion handler receives a pixel-accurate crop,
/// or a `RegionSelectionError` describing cancellation or an invalid selection.
@MainActor
final class RegionSelectionOverlay: NSObject {
    enum RegionSelectionError: LocalizedError {
        case cancelled
        case emptySelection

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Region selection was cancelled."
            case .emptySelection: return "Select a region before continuing."
            }
        }
    }

    private let image: CGImage
    private let screen: NSScreen
    private let completion: (Result<CGImage, RegionSelectionError>) -> Void
    private var window: NSWindow?
    private weak var selectorView: RegionSelectionView?
    private var keyMonitor: Any?
    private var finished = false

    init(
        image: CGImage,
        screen: NSScreen,
        completion: @escaping (Result<CGImage, RegionSelectionError>) -> Void
    ) {
        self.image = image
        self.screen = screen
        self.completion = completion
        super.init()
    }

    /// Presents the selector over the supplied screen. Retain this object until completion.
    func show() {
        guard window == nil else { return }
        let selector = RegionSelectionView(image: image, frame: NSRect(origin: .zero, size: screen.frame.size))
        selector.onAccept = { [weak self] rect in self?.accept(rect) }
        selector.onCancel = { [weak self] in self?.finish(.failure(.cancelled)) }
        selectorView = selector

        let panel = RegionSelectionWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.level = .screenSaver
        // Attach the selector to the desktop where the shortcut was invoked.
        // Joining every Space can leave this overlay associated with Calshot's
        // previous desktop, while stationary keeps it from following the active one.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.contentView = selector
        window = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(selector)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // The selector is the only time this monitor exists. Do not rely on
            // the borderless window reporting key status for these two keys.
            guard let self, self.window != nil else { return event }
            if event.keyCode == 53 {
                self.finish(.failure(.cancelled))
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                self.selectorView?.acceptSelection()
                return nil
            }
            return event
        }
    }

    func cancel() {
        finish(.failure(.cancelled))
    }

    private func accept(_ rect: CGRect) {
        guard !finished else { return }
        let viewBounds = CGRect(origin: .zero, size: screen.frame.size)
        let selection = rect.standardized.intersection(viewBounds)
        guard selection.width > 0, selection.height > 0 else {
            finish(.failure(.emptySelection))
            return
        }

        // Convert points to source pixels independently on each axis. CGImage crop rectangles use
        // a top-left origin, while the AppKit selection view uses a bottom-left origin.
        let scaleX = CGFloat(image.width) / viewBounds.width
        let scaleY = CGFloat(image.height) / viewBounds.height
        let left = floor(selection.minX * scaleX)
        let right = ceil(selection.maxX * scaleX)
        let top = floor(CGFloat(image.height) - selection.maxY * scaleY)
        let bottom = ceil(CGFloat(image.height) - selection.minY * scaleY)
        let pixelRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = image.cropping(to: pixelRect) else {
            finish(.failure(.emptySelection))
            return
        }
        finish(.success(cropped))
    }

    private func finish(_ result: Result<CGImage, RegionSelectionError>) {
        guard !finished else { return }
        finished = true
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        selectorView = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        completion(result)
    }
}

@MainActor
private final class RegionSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class RegionSelectionView: NSView {
    private let image: CGImage
    private var anchor: CGPoint?
    private var selection: CGRect?
    private let analyzeButton = NSButton(title: "Analyze Region", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var onAccept: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    init(image: CGImage, frame frameRect: NSRect) {
        self.image = image
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 1
        analyzeButton.target = self
        analyzeButton.action = #selector(acceptSelection)
        analyzeButton.bezelStyle = .rounded
        analyzeButton.keyEquivalent = "\r"
        analyzeButton.isEnabled = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelSelection)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        addSubview(cancelButton)
        addSubview(analyzeButton)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.black.withAlphaComponent(0.56).setFill()
        bounds.fill()

        if let selection {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()

            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 2
            NSColor.systemCyan.setStroke()
            outline.stroke()
            drawMeasurement(for: selection)
        }

        drawInstructions()
    }

    override func layout() {
        super.layout()
        let buttonHeight: CGFloat = 32
        // Keep controls below the menu bar and away from the Dock, which can float
        // over the bottom edge of a full-screen selector on macOS.
        let controlsY = max(18, bounds.maxY - 132)
        analyzeButton.frame = CGRect(x: bounds.midX + 5, y: controlsY, width: 132, height: buttonHeight)
        cancelButton.frame = CGRect(x: bounds.midX - 92, y: controlsY, width: 88, height: buttonHeight)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        anchor = point
        selection = CGRect(origin: point, size: .zero)
        analyzeButton.isEnabled = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        analyzeButton.isEnabled = (selection?.width ?? 0) > 0 && (selection?.height ?? 0) > 0
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        self.anchor = nil
        analyzeButton.isEnabled = (selection?.width ?? 0) > 0 && (selection?.height ?? 0) > 0
        needsDisplay = true
    }

    @objc func acceptSelection() {
        guard let selection, selection.width > 0, selection.height > 0 else {
            NSSound.beep()
            return
        }
        onAccept?(selection)
    }

    @objc private func cancelSelection() { onCancel?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?() // Escape
        case 36, 76: // Return, keypad Enter
            acceptSelection()
        default: super.keyDown(with: event)
        }
    }

    private func drawInstructions() {
        let title = "Drag to select the event details"
        let subtitle = "Press Return to analyze  ·  Esc to cancel"
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.78)
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        let subtitleSize = (subtitle as NSString).size(withAttributes: subtitleAttributes)
        let boxWidth = max(titleSize.width, subtitleSize.width) + 36
        let boxHeight: CGFloat = 62
        let box = CGRect(x: (bounds.width - boxWidth) / 2, y: bounds.height - boxHeight - 24,
                         width: boxWidth, height: boxHeight)
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        (title as NSString).draw(at: CGPoint(x: box.midX - titleSize.width / 2, y: box.minY + 35), withAttributes: titleAttributes)
        (subtitle as NSString).draw(at: CGPoint(x: box.midX - subtitleSize.width / 2, y: box.minY + 14), withAttributes: subtitleAttributes)
    }

    private func drawMeasurement(for rect: CGRect) {
        let label = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) pt"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        let labelRect = CGRect(x: rect.minX, y: max(8, rect.minY - size.height - 12),
                               width: size.width + 16, height: size.height + 8)
        NSColor.systemCyan.setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        (label as NSString).draw(at: CGPoint(x: labelRect.minX + 8, y: labelRect.minY + 4), withAttributes: attributes)
    }
}
