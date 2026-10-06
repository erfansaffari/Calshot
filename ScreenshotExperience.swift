import AppKit
import SwiftUI

/// Clipboard support shared by screenshot capture and the screenshot review UI.
enum CaptureClipboard {
    static let defaultsKey = "automaticallyCopyCapture"

    /// New installs copy captures automatically unless the user has changed the preference.
    static var automaticallyCopyCapture: Bool {
        get {
            guard UserDefaults.standard.object(forKey: defaultsKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    @discardableResult
    static func copy(_ image: NSImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }
}

/// Main screenshot review content, sized to make the captured region easy to inspect.
struct ScreenshotCanvasView: View {
    let image: NSImage
    let onRetake: () -> Void

    @State private var copyMessage: String?
    @State private var zoomWindow: ScreenshotZoomWindowController?

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screenshot")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("\(pixelDimensions.width) × \(pixelDimensions.height) pixels")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button(action: copyImage) {
                    Label(copyMessage == "Copied" ? "Copied" : "Copy Image",
                          systemImage: copyMessage == "Copied" ? "checkmark" : "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .accessibilityHint("Copies the screenshot image to the clipboard")
                .buttonStyle(.bordered)
                Button(action: onRetake) {
                    Label("Retake", systemImage: "viewfinder")
                }
                .accessibilityHint("Capture another screenshot")
                .buttonStyle(.bordered)
            }

            Button(action: openZoomWindow) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(14)
                    .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .bottomTrailing) {
                        Label("Click to enlarge", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.84))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.68), in: Capsule())
                            .padding(24)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open screenshot at larger size")
            .accessibilityHint("Opens a resizable view where you can zoom in and out")
            .accessibilityAddTraits(.isImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let copyMessage {
                Text(copyMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copyMessage == "Copied" ? Color.green : Color.orange)
                    .accessibilityLabel(copyMessage)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(24)
        .background(Color(red: 0.075, green: 0.08, blue: 0.10))
        .preferredColorScheme(.dark)
    }

    private func copyImage() {
        copyMessage = CaptureClipboard.copy(image) ? "Copied" : "Couldn’t copy image"
        if copyMessage == "Copied" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if copyMessage == "Copied" { copyMessage = nil }
            }
        }
    }

    private var pixelDimensions: (width: Int, height: Int) {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            return (cgImage.width, cgImage.height)
        }
        return (Int(image.size.width), Int(image.size.height))
    }

    private func openZoomWindow() {
        if let zoomWindow {
            zoomWindow.show()
        } else {
            let controller = ScreenshotZoomWindowController(image: image)
            zoomWindow = controller
            controller.show()
        }
    }
}

@MainActor
private final class ScreenshotZoomWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(image: NSImage) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Screenshot Preview"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 460)
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: ScreenshotZoomView(image: image))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the hosting view alive so the same preview window can be reopened.
    }
}

private struct ScreenshotZoomView: View {
    let image: NSImage
    @State private var magnification: CGFloat = 1
    @State private var gestureMagnification: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Screenshot Preview")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("−") { setZoom(magnification / 1.2) }
                    .accessibilityLabel("Zoom out")
                Text("\(Int(magnification * 100))%")
                    .monospacedDigit()
                    .frame(minWidth: 48)
                    .accessibilityLabel("Zoom \(Int(magnification * 100)) percent")
                Button("+") { setZoom(magnification * 1.2) }
                    .accessibilityLabel("Zoom in")
                Button("Fit") { setZoom(1) }
                    .accessibilityHint("Fit the complete screenshot in the window")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider().overlay(.white.opacity(0.08))

            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: max(1, geometry.size.width * currentZoom),
                               height: max(1, geometry.size.height * currentZoom))
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        .gesture(MagnificationGesture()
                            .onChanged { gestureMagnification = $0 }
                            .onEnded { value in
                                setZoom(magnification * value)
                                gestureMagnification = 1
                            })
                }
                .background(Color.black.opacity(0.45))
            }
        }
        .background(Color(red: 0.075, green: 0.08, blue: 0.10))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var currentZoom: CGFloat { min(8, max(0.2, magnification * gestureMagnification)) }

    private func setZoom(_ value: CGFloat) { magnification = min(8, max(0.2, value)) }
}
