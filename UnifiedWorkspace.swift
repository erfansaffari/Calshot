import AppKit
import SwiftUI

/// The single-window home for capture, local history, and preferences.
struct CalshotWorkspaceView: View {
    @ObservedObject var model: CalshotModel
    @State private var settingsSection: SettingsSection = .general
    @AppStorage("sidebarExpanded") private var sidebarExpanded = true
    @State private var hoveredNav: String?

    var body: some View {
        VStack(spacing: 0) {
            windowBar
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
                mainContent
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background {
            ZStack {
                Color(red: 0.055, green: 0.06, blue: 0.075)
                RadialGradient(colors: [Color.indigo.opacity(0.16), .clear],
                               center: .topTrailing, startRadius: 40, endRadius: 760)
            }
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { model.refreshMemory() }
    }

    private var windowBar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { sidebarExpanded.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .help(sidebarExpanded ? "Collapse sidebar" : "Expand sidebar")
            AnimatedCalshotLogo()
            Text("Calshot").font(.system(size: 15, weight: .semibold))
            Spacer()
            Button { model.workspaceWindowController?.minimize() } label: {
                Image(systemName: "minus").font(.system(size: 12, weight: .medium)).frame(width: 30, height: 30)
            }.help("Minimize")
            Button { model.workspaceWindowController?.zoom() } label: {
                Image(systemName: "square.on.square").font(.system(size: 12, weight: .medium)).frame(width: 30, height: 30)
            }.help("Zoom")
            Button { model.workspaceWindowController?.close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 30)
            }.help("Close window")
        }
        .buttonStyle(ChromeButtonStyle())
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.ultraThinMaterial)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: sidebarExpanded ? 22 : 16) {
            if sidebarExpanded {
                Text("WORKSPACE")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
            }
            VStack(alignment: .leading, spacing: 5) {
                navRow(.capture)
                navRow(.library)
            }
            VStack(alignment: .leading, spacing: 5) {
                if sidebarExpanded {
                    Text("PREFERENCES").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.bottom, 3)
                } else {
                    Rectangle().fill(.white.opacity(0.11)).frame(width: 22, height: 1).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                navRow(.settings)
                if model.workspaceSelection == .settings {
                    ForEach(SettingsSection.allCases) { item in
                        Button { settingsSection = item } label: {
                            HStack(spacing: 9) {
                                Image(systemName: item.symbol).frame(width: 18)
                                if sidebarExpanded { Text(item.title) }
                                if sidebarExpanded { Spacer(minLength: 0) }
                            }
                            .font(.system(size: sidebarExpanded ? 12 : 14, weight: .medium))
                            .foregroundStyle(settingsSection == item ? .white : .white.opacity(0.6))
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: sidebarExpanded ? .leading : .center)
                            .padding(.leading, sidebarExpanded ? 29 : 0)
                            .modifier(SidebarGlassSurface(isActive: settingsSection == item,
                                                           isHovered: hoveredNav == item.id))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .onHover { hoveredNav = $0 ? item.id : nil }
                        .help(item.title)
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(model.isCapturing || model.isRecognizing ? .orange : .green).frame(width: 7, height: 7)
                if sidebarExpanded {
                    Text(model.isCapturing ? "Capturing" : model.isRecognizing ? "Reading selection" : "Ready")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: sidebarExpanded ? .leading : .center)
                .padding(.horizontal, sidebarExpanded ? 11 : 0)
        }
        .padding(.horizontal, sidebarExpanded ? 13 : 8).padding(.top, 18).padding(.bottom, 17)
        .frame(width: sidebarExpanded ? 204 : 60)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }

    private func navRow(_ item: WorkspaceSection) -> some View {
        Button {
            model.workspaceSelection = item
            if item == .library { model.refreshMemory() }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol).font(.system(size: sidebarExpanded ? 14 : 17, weight: .medium)).frame(width: 18)
                if sidebarExpanded { Text(item.title).font(.system(size: 13, weight: .medium)); Spacer() }
                if sidebarExpanded, item == .library, !model.memoryRecords.isEmpty {
                    Text("\(model.memoryRecords.count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: sidebarExpanded ? .leading : .center)
            .foregroundStyle(model.workspaceSelection == item ? .white : .white.opacity(0.65))
            .padding(.horizontal, sidebarExpanded ? 11 : 0).frame(height: 38)
            .modifier(SidebarGlassSurface(isActive: model.workspaceSelection == item,
                                           isHovered: hoveredNav == item.rawValue))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hoveredNav = $0 ? item.rawValue : nil }
        .help(item.title)
    }

    @ViewBuilder private var mainContent: some View {
        switch model.workspaceSelection {
        case .capture: capturePage
        case .library: SettingsView(model: model, section: .memory, showsHeading: true)
        case .settings: SettingsView(model: model, section: settingsSection, showsHeading: true)
        }
    }

    private var capturePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Capture").font(.system(size: 25, weight: .semibold))
                    Text("Select anything on your screen. Calshot saves the image and offers a calendar event when it finds one.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.capture() } } label: {
                    Label(model.isCapturing ? "Capturing…" : "New Capture", systemImage: "viewfinder")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16).frame(height: 38)
                }
                .modifier(SystemCaptureButtonStyle())
                .disabled(model.isCapturing || model.isRecognizing)
            }
            if model.isRecognizing {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Reading the selected region…").font(.system(size: 12)).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 150).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
            } else if let image = model.image {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ScreenshotCanvasView(image: image, onRetake: { Task { await model.capture() } })
                            .frame(height: 390)
                        if let draft = model.draft { eventSuggestion(draft) }
                        else if let status = model.status { Label(status, systemImage: model.screenCapturePermissionNeeded ? "lock.shield" : "info.circle").font(.system(size: 12)).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)) }
                    }
                }
            } else {
                VStack(spacing: 13) {
                    Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 31, weight: .light)).foregroundStyle(.indigo)
                    Text("Keep what matters on your screen").font(.system(size: 16, weight: .semibold))
                    Text("Press \(model.shortcut.label) or choose New Capture, then drag over what you want to keep.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Browse Memory") { model.workspaceSelection = .library; model.refreshMemory() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.78)).padding(.top, 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(0.022), in: RoundedRectangle(cornerRadius: 17))
            }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func eventSuggestion(_ initial: EventDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suggested event").font(.system(size: 16, weight: .semibold))
                    Text("Review the details before adding anything to a calendar.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(initial.confidence * 100))% match").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            TextField("Event title", text: Binding(get: { model.draft?.title ?? initial.title }, set: { model.draft?.title = $0 }))
                .textFieldStyle(.roundedBorder)
            if model.draft?.startDate == nil || model.draft?.ambiguities.contains(where: { [.missingDate, .missingYear, .ambiguousDate].contains($0) }) == true {
                Label("Confirm the date before adding this event.", systemImage: "calendar.badge.exclamationmark")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            DatePicker("Starts", selection: Binding(get: { model.draft?.startDate ?? .now }, set: { value in
                model.draft?.startDate = value
                model.draft?.endDate = value.addingTimeInterval(3600)
                model.draft?.ambiguities.removeAll(where: { [.missingDate, .missingYear, .ambiguousDate].contains($0) })
            }), displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
            DatePicker("Ends", selection: Binding(get: { model.draft?.endDate ?? (model.draft?.startDate ?? .now).addingTimeInterval(3600) }, set: { model.draft?.endDate = $0 }), displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
            HStack {
                if model.destinations.isEmpty {
                    Button("Load calendars") { Task { await model.loadCalendars() } }.buttonStyle(.bordered)
                } else {
                    Picker("Calendar", selection: Binding(get: { model.selectedCalendarID ?? "" }, set: { model.selectedCalendarID = $0 })) {
                        ForEach(model.destinations) { destination in Text(destination.title).tag(destination.id) }
                    }.frame(maxWidth: 260)
                }
                Spacer()
                Button { Task { await model.saveEvent() } } label: {
                    Label(model.isSaving ? "Adding…" : "Add to Calendar", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSaving || model.saveMessage?.hasPrefix("Added") == true || !validDraft)
            }
            if let message = model.saveMessage { Text(message).font(.system(size: 11)).foregroundStyle(message.hasPrefix("Added") ? .green : .secondary) }
        }
        .padding(17).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
        .task { if model.destinations.isEmpty { await model.loadCalendars() } }
    }

    private var validDraft: Bool {
        guard let draft = model.draft, let start = draft.startDate, let end = draft.endDate,
              end > start, !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !draft.ambiguities.contains(where: { [.missingDate, .missingYear, .ambiguousDate].contains($0) })
    }
}

enum WorkspaceSection: String { case capture, library, settings
    var title: String { switch self { case .capture: "Capture"; case .library: "Memory"; case .settings: "Settings" } }
    var symbol: String { switch self { case .capture: "viewfinder"; case .library: "square.stack.3d.up"; case .settings: "gearshape" } }
}

private struct ChromeButtonStyle: ButtonStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26, *) {
            configuration.label
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 9))
                .opacity(configuration.isPressed ? 0.75 : 1)
        } else {
            configuration.label
                .background(configuration.isPressed ? .white.opacity(0.14) : .white.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
    }
}

private struct SidebarGlassSurface: ViewModifier {
    let isActive: Bool
    let isHovered: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if isActive || isHovered {
                content
                    .background(.white.opacity(isActive ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 10))
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10))
            } else { content }
        } else {
            content.background(isActive ? .white.opacity(0.12) : isHovered ? .white.opacity(0.065) : .clear,
                               in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct SystemCaptureButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .glassEffect(.regular.tint(.indigo.opacity(0.22)).interactive(),
                             in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 1))
        } else {
            content.buttonStyle(.borderedProminent)
                .tint(.indigo)
        }
    }
}

private struct AnimatedCalshotLogo: View {
    @State private var isHovered = false

    var body: some View {
        Image("CalshotMark")
            .resizable()
            .scaledToFit()
            .frame(width: 34, height: 34)
            .rotation3DEffect(.degrees(isHovered ? 16 : 0), axis: (x: 0, y: 1, z: 0))
            .rotationEffect(.degrees(isHovered ? -9 : 0))
            .scaleEffect(isHovered ? 1.12 : 1)
            .offset(y: isHovered ? -2 : 0)
            .shadow(color: .blue.opacity(isHovered ? 0.35 : 0), radius: isHovered ? 14 : 0)
            .onHover { isHovered = $0 }
            .animation(.spring(response: 0.34, dampingFraction: 0.57), value: isHovered)
            .accessibilityLabel("Calshot logo")
    }
}
