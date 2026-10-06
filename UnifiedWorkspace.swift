import AppKit
import SwiftUI

/// The single-window home for capture, local history, and preferences.
struct CalshotWorkspaceView: View {
    @ObservedObject var model: CalshotModel
    @State private var settingsSection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            mainContent
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(Color(red: 0.055, green: 0.06, blue: 0.075))
        .preferredColorScheme(.dark)
        .onAppear { model.refreshMemory() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 11) {
                Image("CalshotMark").resizable().scaledToFit().padding(6)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calshot").font(.system(size: 15, weight: .semibold))
                    Text("SCREEN MEMORY").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.1).foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("WORKSPACE").font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.bottom, 3)
                navRow(.capture)
                navRow(.library)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("PREFERENCES").font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.bottom, 3)
                navRow(.settings)
                if model.workspaceSelection == .settings {
                    ForEach(SettingsSection.allCases) { item in
                        Button { settingsSection = item } label: {
                            HStack(spacing: 9) {
                                Image(systemName: item.symbol).frame(width: 16)
                                Text(item.title)
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(settingsSection == item ? .white : .white.opacity(0.5))
                            .padding(.leading, 28).frame(height: 30, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(model.isCapturing || model.isRecognizing ? .orange : .green).frame(width: 7, height: 7)
                Text(model.isCapturing ? "Capturing" : model.isRecognizing ? "Reading selection" : "Ready")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }.padding(.horizontal, 11)
        }
        .padding(.horizontal, 15).padding(.top, 24).padding(.bottom, 18)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.018))
    }

    private func navRow(_ item: WorkspaceSection) -> some View {
        Button {
            model.workspaceSelection = item
            if item == .library { model.refreshMemory() }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol).font(.system(size: 13, weight: .medium)).frame(width: 18)
                Text(item.title).font(.system(size: 12, weight: .medium))
                Spacer()
                if item == .library, !model.memoryRecords.isEmpty {
                    Text("\(model.memoryRecords.count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(model.workspaceSelection == item ? .white : .white.opacity(0.63))
            .padding(.horizontal, 11).frame(height: 37)
            .background(model.workspaceSelection == item ? .white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
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
                        .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 15).frame(height: 38)
                }
                .buttonStyle(.borderedProminent).tint(Color(red: 0.36, green: 0.37, blue: 0.95))
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
                        if !model.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Recognized text").font(.system(size: 15, weight: .semibold))
                                    Spacer()
                                    Button("Copy Text") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(model.recognizedText, forType: .string)
                                    }.buttonStyle(.bordered)
                                }
                                Text(model.recognizedText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(17)
                            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
                        }
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
