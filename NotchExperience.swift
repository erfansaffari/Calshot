import AppKit
import SwiftUI

/// A small, fixed notch launcher that grows into an action menu while the pointer is over it.
@MainActor
final class NotchExperienceController: ObservableObject {
    private let panel: NSPanel
    private weak var model: CalshotModel?
    @Published private(set) var isExpanded = false
    private var isPointerInside = false
    private var collapseWorkItem: DispatchWorkItem?

    private let compactSize = NSSize(width: 184, height: 38)
    private let expandedSize = NSSize(width: 286, height: 164)

    init(model: CalshotModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: NotchExperienceView(
            controller: self,
            model: model,
            pointerChanged: { [weak self] inside in self?.pointerChanged(inside) },
            expand: { [weak self] in self?.setExpanded(true) },
            capture: { [weak self] in self?.capture() },
            openApp: { [weak self] in self?.openApp() },
            openSettings: { [weak self] in self?.openSettings() },
            close: { [weak self] in self?.hide() }
        ))
        position(on: NSScreen.main)
    }

    func show() {
        position(on: NSScreen.main)
        panel.orderFrontRegardless()
    }

    func hide() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        isPointerInside = false
        setExpanded(false)
        panel.orderOut(nil)
    }

    private func capture() {
        hide()
        guard let model else { return }
        Task { @MainActor in await model.capture() }
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
            setExpanded(true)
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
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        let size = expanded ? expandedSize : compactSize
        let origin = origin(for: size, on: NSScreen.main)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private func position(on screen: NSScreen?) {
        let size = isExpanded ? expandedSize : compactSize
        panel.setFrame(NSRect(origin: origin(for: size, on: screen), size: size), display: true)
    }

    private func origin(for size: NSSize, on screen: NSScreen?) -> NSPoint {
        guard let screen else { return NSPoint(x: 0, y: 0) }
        let x = screen.frame.midX - size.width / 2
        // A notched display reports a top safe-area inset. Keep the pill centered at the
        // physical top edge and grow the menu downward from the same fixed top anchor.
        let y: CGFloat
        if screen.safeAreaInsets.top > 0 {
            let topAnchor = screen.frame.maxY - max(2, screen.safeAreaInsets.top - 4)
            y = topAnchor - size.height
        } else {
            y = screen.visibleFrame.maxY - size.height - 6
        }
        return NSPoint(x: x, y: y)
    }
}

private struct NotchExperienceView: View {
    @ObservedObject var controller: NotchExperienceController
    @ObservedObject var model: CalshotModel
    let pointerChanged: (Bool) -> Void
    let expand: () -> Void
    let capture: () -> Void
    let openApp: () -> Void
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Image("CalshotMark")
                    .resizable().scaledToFit()
                    .padding(4)
                    .frame(width: 27, height: 27)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                Text("Calshot")
                    .font(.system(size: 12, weight: .semibold))
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

            if controller.isExpanded {
                actionRow("Capture", symbol: "camera.viewfinder", action: capture, prominent: true)
                actionRow("Open App", symbol: "macwindow", action: openApp)
                actionRow("Settings", symbol: "gearshape", action: openSettings)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, controller.isExpanded ? 10 : 5)
        .frame(width: controller.isExpanded ? 286 : 184,
               height: controller.isExpanded ? 164 : 38,
               alignment: .top)
        .background(Color(red: 0.035, green: 0.04, blue: 0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .onHover(perform: pointerChanged)
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

/// An AppKit tracking area covers the whole hosting view, including the controls.
private struct PointerTrackingView: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self,
                                      userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}
