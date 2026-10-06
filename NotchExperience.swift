import AppKit
import QuartzCore
import SwiftUI

/// A small, fixed notch launcher that grows into an action menu while the pointer is over it.
@MainActor
final class NotchExperienceController: ObservableObject {
    struct QuickPreview {
        let image: NSImage
        let recordID: UUID
        let copiedToClipboard: Bool
    }

    private let panel: NSPanel
    private weak var model: CalshotModel?
    @Published private(set) var isExpanded = false
    @Published private(set) var launcherSize = NSSize(width: 184, height: 24)
    @Published private(set) var quickPreview: QuickPreview?
    private var isPointerInside = false
    private var collapseWorkItem: DispatchWorkItem?
    private var previewDismissWorkItem: DispatchWorkItem?
    private var screenChangeObserver: NSObjectProtocol?

    private var compactSize = NSSize(width: 184, height: 24)
    private let expandedSize = NSSize(width: 340, height: 230)
    private let previewSize = NSSize(width: 380, height: 290)

    init(model: CalshotModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: NotchExperienceView(
            controller: self,
            model: model,
            pointerChanged: { [weak self] inside in self?.pointerChanged(inside) },
            expand: { [weak self] in self?.setExpanded(true) },
            capture: { [weak self] in self?.capture(quick: false) },
            quickCapture: { [weak self] in self?.capture(quick: true) },
            openPreview: { [weak self] in self?.openQuickPreview() },
            openApp: { [weak self] in self?.openApp() },
            openSettings: { [weak self] in self?.openSettings() },
            close: { [weak self] in self?.hide() }
        ))
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenConfigurationChanged() }
        }
        position(on: screenUnderPointer() ?? NSScreen.main)
    }

    func show() {
        previewDismissWorkItem?.cancel()
        previewDismissWorkItem = nil
        quickPreview = nil
        position(on: screenUnderPointer() ?? NSScreen.main)
        panel.orderFrontRegardless()
    }

    func showQuickPreview(image: NSImage, recordID: UUID, copiedToClipboard: Bool) {
        previewDismissWorkItem?.cancel()
        quickPreview = QuickPreview(image: image, recordID: recordID,
                                    copiedToClipboard: copiedToClipboard)
        position(on: screenUnderPointer() ?? NSScreen.main)
        panel.orderFrontRegardless()
        setExpanded(true)
        schedulePreviewDismiss(after: 4.5)
    }

    func hide() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        previewDismissWorkItem?.cancel()
        previewDismissWorkItem = nil
        isPointerInside = false
        setExpanded(false)
        quickPreview = nil
        panel.orderOut(nil)
    }

    private func capture(quick: Bool) {
        hide()
        guard let model else { return }
        Task { @MainActor in await model.capture(quick: quick) }
    }

    private func openQuickPreview() {
        guard let recordID = quickPreview?.recordID else { return }
        hide()
        model?.openMemoryCapture(recordID)
    }

    private func openApp() {
        setExpanded(false)
        model?.openPanel()
    }

    private func openSettings() {
        setExpanded(false)
        model?.openSettings()
    }

    private func pointerChanged(_ inside: Bool) {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        isPointerInside = inside
        if inside {
            previewDismissWorkItem?.cancel()
            previewDismissWorkItem = nil
            setExpanded(true)
        } else if quickPreview != nil {
            schedulePreviewDismiss(after: 0.9)
        } else {
            // Give the pointer time to cross the edge while the panel is changing size.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if !self.isPointerInside && !self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.setExpanded(false)
                }
            }
            collapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else {
            if expanded {
                let screen = screenForPanel() ?? NSScreen.main
                let size = quickPreview == nil ? expandedSize : previewSize
                let frame = NSRect(origin: origin(for: size, on: screen), size: size)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.28
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(frame, display: true)
                }
            }
            return
        }
        isExpanded = expanded
        let size = expanded ? (quickPreview == nil ? expandedSize : previewSize) : compactSize
        let screen = screenForPanel() ?? NSScreen.main
        let frame = NSRect(origin: origin(for: size, on: screen), size: size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = expanded ? 0.32 : 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func schedulePreviewDismiss(after delay: TimeInterval) {
        previewDismissWorkItem?.cancel()
        let recordID = quickPreview?.recordID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.quickPreview?.recordID == recordID else { return }
            let pointerIsInside = self.panel.frame.contains(NSEvent.mouseLocation)
            if !self.isPointerInside && !pointerIsInside {
                self.hide()
            } else {
                self.schedulePreviewDismiss(after: 0.9)
            }
        }
        previewDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func position(on screen: NSScreen?) {
        guard let screen else { return }
        compactSize = closedSize(on: screen)
        launcherSize = compactSize
        let size = isExpanded ? (quickPreview == nil ? expandedSize : previewSize) : compactSize
        panel.setFrame(NSRect(origin: origin(for: size, on: screen), size: size), display: true, animate: false)
    }

    private func origin(for size: NSSize, on screen: NSScreen?) -> NSPoint {
        guard let screen else { return NSPoint(x: 0, y: 0) }
        let x = screen.frame.midX - size.width / 2
        // Keep the panel's top edge at the physical top of the display. The closed
        // frame then exactly overlays the notch, while expansion unfolds downward.
        return NSPoint(x: x, y: screen.frame.maxY - size.height)
    }

    private func closedSize(on screen: NSScreen) -> NSSize {
        // Auxiliary top areas describe the actual camera housing width on notched Macs.
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            return NSSize(width: max(150, screen.frame.width - left.width - right.width + 2),
                          height: max(1, screen.safeAreaInsets.top))
        }
        // On displays without a notch, use the centered menu bar band as the hover target.
        return NSSize(width: 184, height: max(22, screen.frame.maxY - screen.visibleFrame.maxY))
    }

    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func screenForPanel() -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(panel.frame) }
    }

    private func screenConfigurationChanged() {
        guard panel.isVisible else { return }
        position(on: screenUnderPointer() ?? screenForPanel() ?? NSScreen.main)
    }
}

private struct NotchExperienceView: View {
    @ObservedObject var controller: NotchExperienceController
    @ObservedObject var model: CalshotModel
    let pointerChanged: (Bool) -> Void
    let expand: () -> Void
    let capture: () -> Void
    let quickCapture: () -> Void
    let openPreview: () -> Void
    let openApp: () -> Void
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            if controller.isExpanded {
                HStack(spacing: 8) {
                    Text(controller.quickPreview == nil ? "Calshot" : "Screenshot ready")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 2)
                    Text(model.shortcut.label)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 20, height: 20)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide Calshot")
                    .accessibilityLabel("Hide Calshot")
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: expand)

                if let preview = controller.quickPreview {
                    Button(action: openPreview) {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(nsImage: preview.image)
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: 178)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            HStack(spacing: 6) {
                                Image(systemName: preview.copiedToClipboard ? "checkmark.circle.fill" : "internaldrive")
                                    .foregroundStyle(preview.copiedToClipboard ? Color.green : Color.secondary)
                                Text(preview.copiedToClipboard ? "Saved · copied to clipboard" : "Saved to Memory")
                                    .foregroundStyle(.white.opacity(0.78))
                                Spacer(minLength: 0)
                                Text("Open")
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            .font(.system(size: 10, weight: .medium))
                        }
                        .padding(8)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Open this screenshot in Calshot")
                } else {
                    actionRow("Capture & Analyze", symbol: "viewfinder", action: capture, prominent: true)
                    actionRow("Quick Screenshot", symbol: "camera", action: quickCapture)
                    actionRow("Open App", symbol: "macwindow", action: openApp)
                    actionRow("Settings", symbol: "gearshape", action: openSettings)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, controller.isExpanded ? 12 : 0)
        .frame(width: controller.isExpanded ? (controller.quickPreview == nil ? 340 : 380) : controller.launcherSize.width,
               height: controller.isExpanded ? (controller.quickPreview == nil ? 230 : 290) : controller.launcherSize.height,
               alignment: .top)
        .background {
            if controller.isExpanded {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black.opacity(0.76)))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            } else {
                // Leave the closed hit region transparent. On a notched display the
                // physical camera housing supplies the black surface; other displays
                // remain visually untouched.
                Color.clear
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: pointerChanged)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: controller.isExpanded)
        .preferredColorScheme(.dark)
    }

    private func actionRow(_ title: String, symbol: String, action: @escaping () -> Void, prominent: Bool = false) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: prominent ? .semibold : .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(prominent ? Color.accentColor : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
