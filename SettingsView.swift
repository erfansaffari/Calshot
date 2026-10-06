import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: CalshotModel
    let section: SettingsSection
    let showsHeading: Bool
    @AppStorage("automaticallyCopyCapture") private var automaticallyCopyCapture = true
    @State private var apiKey = ""
    @State private var connectionMessage: String?
    @State private var isTestingConnection = false
    @State private var isRecordingShortcut = false
    @State private var selectedRecord: MemoryCaptureRecord?
    @State private var showingDeleteAll = false

    init(model: CalshotModel, section: SettingsSection = .general, showsHeading: Bool = true) {
        self.model = model
        self.section = section
        self.showsHeading = showsHeading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeading {
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title)
                        .font(.system(size: 23, weight: .semibold))
                    Text(section.subtitle)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            sectionContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 20)
        .background(Color(red: 0.055, green: 0.06, blue: 0.075))
        .frame(minWidth: 600, minHeight: 500)
        .preferredColorScheme(.dark)
        .onAppear { model.refreshMemory() }
        .sheet(item: $selectedRecord) { record in
            MemoryRecordDetail(model: model, record: record)
                .frame(minWidth: 900, minHeight: 700)
        }
        .alert("Delete all saved screenshots and event history?", isPresented: $showingDeleteAll) {
            Button("Delete All", role: .destructive) { model.deleteAllMemory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes Calshot’s local history from this Mac. It does not remove events from your calendar.")
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .general: generalTab
        case .ai: aiTab
        case .memory: memoryTab
        }
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsGroup("CAPTURE") {
                    HStack(spacing: 16) {
                        settingLabel("Copy captures automatically", detail: "Copy each selected screenshot to the clipboard when capture finishes.")
                        Spacer(minLength: 12)
                        Toggle("Copy captures automatically", isOn: $automaticallyCopyCapture)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.accentColor)
                    }
                    settingsDivider
                    HStack(spacing: 12) {
                        settingLabel("Global shortcut", detail: "Select a region, then press Return. Press Escape to cancel.")
                        Spacer(minLength: 12)
                        HStack(spacing: 8) {
                            ShortcutRecorder(shortcut: model.shortcut, isRecording: $isRecordingShortcut, model: model) { model.updateShortcut($0) }
                                .frame(width: 150, height: 30)
                            Button("Reset") { model.updateShortcut(.default) }
                                .buttonStyle(GlassActionButtonStyle())
                                .disabled(model.shortcut == .default || model.isRecordingShortcut)
                        }
                    }
                    settingsDivider
                    settingsValueRow("Registration", value: model.isRecordingShortcut ? "Listening…" : model.shortcutRegistrationStatus == noErr ? "Active" : "Unavailable",
                                     color: model.isRecordingShortcut ? .accentColor : model.shortcutRegistrationStatus == noErr ? .green : .orange)
                    settingsDivider
                    settingsValueRow("Last capture", value: model.lastCaptureSummary, color: .secondary)
                }
                settingsGroup("PRIVACY") {
                    settingLabel("Capture storage", detail: "Screenshots and recognized text are saved in the folder shown in Memory settings. Cloud-synced folders may sync these files.")
                    settingsDivider
                    settingLabel("OpenAI analysis", detail: "When enabled, only the selected region and its recognized text are sent to OpenAI. Delete captures any time from Memory.")
                }
            }.frame(maxWidth: 790, alignment: .leading).padding(.top, 6)
        }.scrollIndicators(.visible)
    }

    private var aiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                settingsGroup("ANALYSIS") {
                    HStack(spacing: 16) {
                        settingLabel("Analyze with OpenAI", detail: "Send selected screenshots to OpenAI for event suggestions.")
                        Spacer(minLength: 12)
                        Toggle("Analyze with OpenAI", isOn: $model.openAIAnalysisEnabled)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.accentColor)
                            .disabled(!model.hasOpenAIAPIKey)
                    }
                    settingsDivider
                    settingsValueRow("Connection", value: model.hasOpenAIAPIKey ? "Key saved" : "Add a key below", color: model.hasOpenAIAPIKey ? .green : .secondary)
                    settingsDivider
                    settingsValueRow("Model", value: OpenAIEventAnalyzer.modelName, color: .secondary)
                }
                settingsGroup("OPENAI API KEY") {
                    settingLabel("API key", detail: "Stored in macOS Keychain. Replace it here whenever you need to.")
                    SecureField(model.hasOpenAIAPIKey ? "Replace saved API key" : "Paste API key", text: $apiKey)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    HStack(spacing: 9) {
                        Button("Save key") {
                            do { try model.saveOpenAIAPIKey(apiKey); apiKey = ""; connectionMessage = "Key saved. Test the connection to check model access." }
                            catch { connectionMessage = error.localizedDescription }
                        }.buttonStyle(GlassActionButtonStyle()).disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button {
                            isTestingConnection = true
                            let testKey = apiKey.isEmpty ? nil : apiKey
                            Task {
                                defer { isTestingConnection = false }
                                do { connectionMessage = try await model.testOpenAIConnection(using: testKey) }
                                catch { connectionMessage = error.localizedDescription }
                            }
                        } label: {
                            if isTestingConnection { ProgressView().controlSize(.small) } else { Text("Test connection") }
                        }.buttonStyle(GlassActionButtonStyle()).disabled(isTestingConnection || (apiKey.isEmpty && !model.hasOpenAIAPIKey))
                        Spacer(minLength: 0)
                        if model.hasOpenAIAPIKey {
                            Button("Remove key", role: .destructive) {
                                do { try model.removeOpenAIAPIKey(); connectionMessage = "Key removed from Keychain." }
                                catch { connectionMessage = error.localizedDescription }
                            }.buttonStyle(GlassActionButtonStyle(destructive: true))
                        }
                    }.padding(.top, 12).padding(.bottom, 8)
                    if let connectionMessage {
                        Text(connectionMessage).font(.system(size: 11))
                            .foregroundStyle(connectionMessage.hasPrefix("Connected") ? .green : .secondary)
                            .textSelection(.enabled).padding(.bottom, 8)
                    }
                }
                settingsGroup("RECENT ACTIVITY") {
                    settingsValueRow("Last analysis", value: model.lastCaptureSummary, color: .secondary)
                    if let provider = model.lastAnalysisProvider { settingsDivider; settingsValueRow("Provider", value: provider, color: .secondary) }
                    settingsDivider
                    settingsValueRow("Text recognition", value: model.lastOCRStatus, color: .secondary)
                }
                Text("Connection testing does not send a screenshot. Analysis may incur OpenAI API charges.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }.frame(maxWidth: 790, alignment: .leading).padding(.top, 6)
        }.scrollIndicators(.visible)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10, weight: .bold)).tracking(1.3).foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 15).padding(.vertical, 5)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.075), lineWidth: 1))
        }
    }

    private var settingsDivider: some View { Rectangle().fill(Color.white.opacity(0.075)).frame(height: 1) }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 10)
    }

    private func settingsValueRow(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 10)
            Text(value).font(.system(size: 12)).foregroundStyle(color).multilineTextAlignment(.trailing)
        }.padding(.vertical, 11)
    }

    private struct GlassActionButtonStyle: ButtonStyle {
        var destructive = false
        @ViewBuilder
        func makeBody(configuration: Configuration) -> some View {
            if #available(macOS 26, *) {
                configuration.label.font(.system(size: 11, weight: .medium))
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 9))
                    .opacity(configuration.isPressed ? 0.8 : 1)
            } else {
                configuration.label.font(.system(size: 11, weight: .medium))
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
                    .opacity(configuration.isPressed ? 0.8 : 1)
            }
        }
    }

    private var memoryTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Capture history").font(.title2.weight(.semibold))
                    Text("Screenshots, OCR text, proposed events, and calendar saves.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Delete All…", role: .destructive) { showingDeleteAll = true }
                    .buttonStyle(GlassActionButtonStyle(destructive: true))
                    .disabled(model.memoryRecords.isEmpty)
                Button { model.refreshMemory() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(GlassActionButtonStyle())
                    .help("Refresh history")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Storage location", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Show in Finder") { model.revealMemoryFolder() }.buttonStyle(GlassActionButtonStyle())
                    Button("Change…") { model.chooseMemoryLocation() }.buttonStyle(GlassActionButtonStyle())
                }
                Text(model.memoryDirectoryURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("If this folder is cloud-synced, that service may sync your screenshots and event details.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let message = model.memoryLocationMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(message.hasPrefix("Memory moved") ? .green : .secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.075), lineWidth: 1))
            if model.memoryRecords.isEmpty {
                ContentUnavailableView("No captures yet", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Captured regions will appear here with their analysis and save status."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.memoryRecords) { record in
                        Button { selectedRecord = record } label: { MemoryRecordRow(record: record) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Show Details") { selectedRecord = record }
                                Button("Delete Capture", role: .destructive) { model.deleteMemoryRecord(record.id) }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(.top, 10)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case ai
    case memory

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .ai: "AI & OCR"
        case .memory: "Memory"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "Capture behavior and privacy"
        case .ai: "Choose how Calshot reads a selection"
        case .memory: "Browse and manage saved captures"
        }
    }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .ai: "sparkles"
        case .memory: "clock.arrow.circlepath"
        }
    }
}

private struct MemoryRecordRow: View {
    let record: MemoryCaptureRecord
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let data = MemoryStore.shared.imageData(for: record), let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").resizable().scaledToFit().padding(14).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 84, height: 56).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.event?.title ?? "Screenshot").font(.headline).lineLimit(1)
                Text(record.event?.startDate?.formatted(date: .abbreviated, time: .shortened) ?? record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(record.analysisProvider ?? "Not analyzed")
                    if let calendar = record.savedCalendarName { Text("· Added to \(calendar)") }
                }.font(.caption).foregroundStyle(record.savedToCalendarAt == nil ? Color.secondary : Color.green).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private struct MemoryRecordDetail: View {
    @ObservedObject var model: CalshotModel
    let record: MemoryCaptureRecord
    @Environment(\.dismiss) private var dismiss
    @State private var showingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.event?.title ?? "Capture details").font(.title2.weight(.semibold))
                    Text(record.createdAt.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Delete Capture…", role: .destructive) { showingDelete = true }
            }
            if let data = MemoryStore.shared.imageData(for: record), let image = NSImage(data: data) {
                ScreenshotCanvasView(image: image, onRetake: {
                    dismiss()
                    Task { await model.capture() }
                })
                    .frame(height: 420)
            }
            if let event = record.event {
                GroupBox("Event") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        if let start = event.startDate { GridRow { Text("Starts").foregroundStyle(.secondary); Text(start.formatted(date: .complete, time: .shortened)) } }
                        if let end = event.endDate { GridRow { Text("Ends").foregroundStyle(.secondary); Text(end.formatted(date: .complete, time: .shortened)) } }
                        if let location = event.location { GridRow { Text("Location").foregroundStyle(.secondary); Text(location) } }
                        GridRow { Text("Confidence").foregroundStyle(.secondary); Text("\(Int(event.confidence * 100))%") }
                        if let saved = record.savedCalendarName { GridRow { Text("Saved to").foregroundStyle(.secondary); Text(saved) } }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .alert("Delete this capture?", isPresented: $showingDelete) {
            Button("Delete", role: .destructive) { model.deleteMemoryRecord(record.id); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The local screenshot and its Calshot history entry will be removed. A saved calendar event stays in your calendar.") }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: GlobalShortcut
    @Binding var isRecording: Bool
    let model: CalshotModel
    let onChange: (GlobalShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let view = ShortcutRecorderControl()
        view.shortcut = shortcut
        view.isRecording = isRecording
        view.onRecordingChange = { recording in
            isRecording = recording
            model.setShortcutRecording(recording)
        }
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderControl, context: Context) {
        nsView.shortcut = shortcut
        nsView.isRecording = isRecording
        nsView.onRecordingChange = { recording in
            isRecording = recording
            model.setShortcutRecording(recording)
        }
        nsView.onChange = onChange
    }
}

private final class ShortcutRecorderControl: NSView {
    var shortcut = GlobalShortcut.default { didSet { needsDisplay = true } }
    var isRecording = false { didSet { needsDisplay = true } }
    var onRecordingChange: ((Bool) -> Void)?
    var onChange: ((GlobalShortcut) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.17) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
        let label = isRecording ? "Press shortcut…" : shortcut.label
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                             y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording { onRecordingChange?(false) }
        else { window?.makeFirstResponder(self); onRecordingChange?(true) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onRecordingChange?(false); return }
        guard let shortcut = GlobalShortcut.from(event) else { NSSound.beep(); return }
        onChange?(shortcut)
        onRecordingChange?(false)
    }
}
