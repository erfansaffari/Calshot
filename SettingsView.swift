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
        Form {
            Section("Capture") {
                Toggle("Copy captures to the clipboard automatically", isOn: $automaticallyCopyCapture)
                Text("When enabled, each selected screenshot is copied as an image as soon as capture finishes.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Global shortcut") {
                    HStack(spacing: 10) {
                        ShortcutRecorder(shortcut: model.shortcut, isRecording: $isRecordingShortcut, model: model) { newShortcut in
                            model.updateShortcut(newShortcut)
                        }
                        Button("Reset") { model.updateShortcut(.default) }
                            .disabled(model.shortcut == .default || model.isRecordingShortcut)
                    }
                }
                Text("Press the shortcut, select a screen region, then press Return. Press Escape to cancel.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Registration") {
                    Text(model.isRecordingShortcut ? "Listening for shortcut…" : model.shortcutRegistrationStatus == noErr
                         ? "Active" : "Couldn’t register (status \(model.shortcutRegistrationStatus))")
                        .foregroundStyle(model.isRecordingShortcut ? Color.accentColor : model.shortcutRegistrationStatus == noErr ? Color.green : Color.orange)
                }
                LabeledContent("Last capture") {
                    Text(model.lastCaptureSummary).foregroundStyle(.secondary)
                }
            }
            Section("Privacy") {
                Label("Screenshots and recognized text are saved in the folder shown in Memory settings.", systemImage: "externaldrive.badge.icloud")
                Text("If you choose a cloud-synced folder, that service may sync these files too.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Delete captures any time from the Memory tab. If OpenAI analysis is enabled, only the selected region and its OCR text are sent to OpenAI.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 10)
    }

    private var aiTab: some View {
        Form {
            Section("Analysis provider") {
                Toggle("Send the selected image directly to OpenAI", isOn: $model.openAIAnalysisEnabled)
                    .disabled(!model.hasOpenAIAPIKey)
                LabeledContent("Connection") {
                    HStack(spacing: 7) {
                        Circle().fill(model.hasOpenAIAPIKey ? .green : .secondary).frame(width: 8, height: 8)
                        Text(model.hasOpenAIAPIKey ? "API key saved in Keychain" : "Not configured")
                    }
                }
                LabeledContent("Model") { Text(OpenAIEventAnalyzer.modelName).foregroundStyle(.secondary) }
                Text("GPT-6 Luna is the current cost-efficient OpenAI model for screenshot analysis.")
                    .font(.callout).foregroundStyle(.secondary)
                if let connectionMessage {
                    Text(connectionMessage).font(.callout)
                        .foregroundStyle(connectionMessage.hasPrefix("Connected") ? .green : .secondary)
                        .textSelection(.enabled)
                }
            }
            Section("API key") {
                SecureField(model.hasOpenAIAPIKey ? "Replace saved API key" : "Paste API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save in Keychain") {
                        do {
                            try model.saveOpenAIAPIKey(apiKey)
                            apiKey = ""
                            connectionMessage = "Key saved. Test the connection to check model access."
                        } catch { connectionMessage = error.localizedDescription }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        isTestingConnection = true
                        let testKey = apiKey.isEmpty ? nil : apiKey
                        Task {
                            defer { isTestingConnection = false }
                            do { connectionMessage = try await model.testOpenAIConnection(using: testKey) }
                            catch { connectionMessage = error.localizedDescription }
                        }
                    } label: {
                        if isTestingConnection { ProgressView().controlSize(.small) }
                        else { Text("Test connection") }
                    }
                    .disabled(isTestingConnection || (apiKey.isEmpty && !model.hasOpenAIAPIKey))
                    if model.hasOpenAIAPIKey {
                        Button("Remove key", role: .destructive) {
                            do {
                                try model.removeOpenAIAPIKey()
                                connectionMessage = "Key removed from Keychain."
                            } catch { connectionMessage = error.localizedDescription }
                        }
                    }
                }
            }
            Section("Accuracy diagnostics") {
                LabeledContent("Last analysis", value: model.lastCaptureSummary)
                if let provider = model.lastAnalysisProvider {
                    LabeledContent("Provider", value: provider)
                }
                LabeledContent("Vision OCR", value: model.lastOCRStatus)
                Text("Calshot runs Vision OCR and includes the recognized text with the screenshot for OpenAI to cross-check. For local analysis, the same OCR text goes to Apple’s on-device model when available, then the local parser.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Data and cost") {
                Text("Connection testing checks access to the model without sending a screenshot. Captures sent for analysis may incur OpenAI API charges. The key stays in macOS Keychain.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 10)
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
                    .disabled(model.memoryRecords.isEmpty)
                Button { model.refreshMemory() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh history")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Storage location", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Show in Finder") { model.revealMemoryFolder() }
                    Button("Change…") { model.chooseMemoryLocation() }
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
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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
            DisclosureGroup("Recognized source text · \(record.analysisProvider ?? "unknown provider")") {
                ScrollView { Text(record.recognizedText ?? record.event?.sourceText ?? "No OCR text saved.")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                    .frame(maxHeight: 180).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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
