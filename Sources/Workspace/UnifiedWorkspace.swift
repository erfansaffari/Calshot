import AppKit
import SwiftUI

/// The single-window home for capture, local history, and preferences.
struct CalshotWorkspaceView: View {
    @ObservedObject var model: CalshotModel
    @State private var settingsSection: SettingsSection = .general
    @AppStorage("sidebarExpanded") private var sidebarExpanded = true
    @State private var hoveredNav: String?
    @State private var agentAnswer = ""
    @FocusState private var commandFocused: Bool
    @FocusState private var answerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
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
        .onAppear { model.refreshMemory() }
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
                navRow(.chat)
                navRow(.calendars)
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
                Circle().fill(model.isCapturing || model.isRecognizing || model.agentIsRunning ? .orange : .green).frame(width: 7, height: 7)
                if sidebarExpanded {
                    Text(model.isCapturing ? "Capturing" : model.agentIsRunning ? "Calendar agent" : model.isRecognizing ? "Reading selection" : "Ready")
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
        case .chat: chatPage
        case .calendars: calendarAccountsPage
        case .tasks: Text("Tasks require the web workspace. Rebuild Calshot’s bundled WebUI to restore Tasks.").padding()
        case .library: SettingsView(model: model, section: .memory, showsHeading: true)
        case .settings: SettingsView(model: model, section: settingsSection, showsHeading: true)
        }
    }

    private var capturePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Capture").font(.system(size: 25, weight: .semibold))
                    Text("Select anything on your screen. Calshot saves the image and offers calendar actions from the visible content.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 9) {
                    Button { Task { await model.capture(quick: true) } } label: {
                        Label("Screenshot Only", systemImage: "camera")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).frame(height: 38)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isCapturing || model.isSaving)
                    Menu {
                        Button("Select a region") { Task { await model.capture() } }
                        Button("Capture visible screen") { Task { await model.capture(visibleScreen: true) } }
                    } label: {
                        Label(model.isCapturing ? "Capturing…" : "New Capture", systemImage: "viewfinder")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16).frame(height: 38)
                    }
                    .modifier(SystemCaptureButtonStyle())
                    .disabled(model.isCapturing || model.isSaving)
                }
            }
            HStack {
                Label(model.agentIsWaitingForApproval ? "Review the proposed calendar actions below" : "Talk to Calshot in Chat", systemImage: "bubble.left.and.bubble.right")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(model.agentQuestion != nil ? "Answer in Chat" : "Open Chat") { model.workspaceSelection = .chat }
            }
            if let error = model.agentError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.agentIsRunning || model.agentStatus != nil { agentProgress }
            if model.isRecognizing && !model.agentIsRunning {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(model.status ?? "Reading the screenshot…").font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); Button("Cancel") { model.cancelAnalysis() } }
                    .frame(maxWidth: .infinity, minHeight: 150).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
            } else if model.agentQuestion != nil {
                if let image = model.image {
                    ScreenshotCanvasView(image: image, onRetake: { Task { await model.capture() } })
                        .frame(maxHeight: .infinity)
                } else { Spacer(minLength: 0) }
            } else if model.image != nil || !model.calendarActions.proposals.isEmpty || model.agentIsWaitingForApproval {
                CalendarBatchReviewView(model: model, coordinator: model.calendarActions)
                if let summary = model.agentSummary {
                    Text(summary).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 13) {
                    Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 31, weight: .light)).foregroundStyle(.indigo)
                    Text("Keep what matters on your screen").font(.system(size: 16, weight: .semibold))
                    Text("Press \(model.shortcut.label) or choose New Capture, then drag over what you want to keep.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let status = model.status {
                        Text(status).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center).textSelection(.enabled).padding(.horizontal, 20)
                    }
                    if let summary = model.agentSummary { Text(summary).font(.callout).textSelection(.enabled).padding(.horizontal, 20) }
                    if model.screenCapturePermissionNeeded { Button("Open Screen Recording Settings") { model.openScreenCaptureSettings() } }
                    Button("Browse Memory") { model.workspaceSelection = .library; model.refreshMemory() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.78)).padding(.top, 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(0.022), in: RoundedRectangle(cornerRadius: 17))
            }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }


    private var calendarAccountsPage: some View {
        CalendarConnectionsView(model: model)
    }

    private var chatPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chat").font(.system(size: 25, weight: .semibold))
                    Text("Find events, plan from a screenshot, or ask for calendar changes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.image != nil || !model.calendarActions.proposals.isEmpty {
                    Button("Review actions") { model.workspaceSelection = .capture }
                }
            }
            chatCalendarConnection
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.agentMessages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Your calendar assistant", systemImage: "sparkles").font(.headline)
                                Text("Try “Find today's events” or “Move Thursday's class to Friday”. Calendar writes always wait for your approval.")
                                    .foregroundStyle(.secondary)
                            }.padding(20)
                        }
                        ForEach(Array(model.agentMessages.enumerated()), id: \.offset) { _, turn in
                            chatTurn(turn)
                        }
                        if !model.agentStreamingText.isEmpty {
                            chatTurn(.init(role: "assistant", content: model.agentStreamingText))
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
                .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .onChange(of: model.agentMessages.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .onChange(of: model.agentStreamingText) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            if let error = model.agentError {
                HStack(alignment: .top) {
                    Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer()
                    if model.agentRetryPrompt != nil {
                        VStack(alignment: .trailing, spacing: 6) {
                            Button("Retry") { Task { await model.retryAgentCommand() } }.disabled(model.agentIsRunning)
                            if model.hasOpenAIAPIKey && model.chatGPTAccount?.canUsePlan == true && !model.agentUseAPIKey {
                                Button("Retry with API key") {
                                    model.agentUseAPIKey = true
                                    Task { await model.retryAgentCommand() }
                                }.disabled(model.agentIsRunning)
                                Text("API usage is billed separately").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Button("AI Settings") { model.workspaceSelection = .settings; settingsSection = .ai }
                    }
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.agentIsRunning { agentProgress }
            if let question = model.agentQuestion { agentQuestionCard(question) }
            if model.agentIsWaitingForApproval {
                HStack {
                    Text("Calendar actions are ready for your review.").font(.callout)
                    Spacer()
                    Button("Skip") { model.skipAgentApproval() }
                    Button("Review actions") { model.workspaceSelection = .capture }.buttonStyle(.borderedProminent)
                }.padding(12).background(.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.image != nil {
                Label("Current screenshot included · View it in Capture", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.agentUseAPIKey {
                HStack {
                    Text("Using API key · Billed separately").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.chatGPTAccount?.canUsePlan == true {
                        Button("Use ChatGPT plan") { model.agentUseAPIKey = false }.disabled(model.agentIsRunning)
                    }
                }
            }
            agentCommandBar
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { if !model.agentIsRunning { await model.loadCalendars() } }
    }

    private var chatCalendarConnection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !model.destinations.isEmpty {
                    Picker("Add new events to", selection: Binding(get: { model.selectedCalendarID ?? "" }, set: { model.selectedCalendarID = $0 })) {
                        ForEach(model.destinations) { calendar in Text(calendar.title).tag(calendar.id) }
                    }.frame(maxWidth: 340).disabled(model.agentIsRunning || model.isSaving)
                    Text("Searches all \(model.readableCalendars.count) connected calendars").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(model.readableCalendars.isEmpty ? "Calendar not connected" : "\(model.readableCalendars.count) calendars · No writable destination", systemImage: "calendar.badge.exclamationmark").font(.callout)
                }
                Spacer()
                Button("Refresh") { Task { await model.loadCalendars() } }.disabled(model.agentIsRunning || model.isSaving)
            }
            if let message = model.calendarConnectionMessage {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Text("Uses all connected accounts. New events use the destination above.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Manage accounts") { model.workspaceSelection = .calendars }
            }
        }.padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func chatTurn(_ turn: AgentTurn) -> some View {
        if let content = turn.content, !content.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(turn.role == "user" ? "You" : turn.role == "error" ? "Connection error" : "Calshot").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text((try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(turn.role == "user" ? Color.indigo.opacity(0.16) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        } else if turn.role == "tool", let name = turn.toolName {
            DisclosureGroup {
                Text(turn.result ?? "").font(.caption.monospaced()).textSelection(.enabled)
            } label: {
                Label(toolResultLabel(turn, name: name), systemImage: "calendar")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func toolResultLabel(_ turn: AgentTurn, name: String) -> String {
        if let raw = turn.result, let data = raw.data(using: .utf8),
           let result = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let error = result.objectValue?["error"], error != .null { return name.replacingOccurrences(of: "_", with: " ").capitalized + " · Failed" }
            if name == "search_events", let calendar = result.objectValue?["calendarName"]?.stringValue {
                return "Searched \(calendar) · \(result.objectValue?["events"]?.arrayValue?.count ?? 0) events"
            }
        }
        return name.replacingOccurrences(of: "_", with: " ").capitalized + " · Result"
    }

    private var agentCommandBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.indigo)
            TextField("Ask Calshot to add, find, move, or remove calendar events", text: $model.agentCommand)
                .textFieldStyle(.roundedBorder)
                .focused($commandFocused)
                .onSubmit { submitAgentCommand() }
                .disabled(model.isCapturing || model.isSaving || model.agentIsRunning)
            Button("Send") { submitAgentCommand() }
                .buttonStyle(.borderedProminent)
                .disabled(model.agentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isCapturing || model.isSaving || model.agentIsRunning)
        }
        .help("Use a typed command on its own, or refer to the current screenshot.")
    }

    private func submitAgentCommand() {
        guard !model.agentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.isCapturing, !model.isSaving, !model.agentIsRunning else { return }
        commandFocused = false
        Task { await model.startAgentCommand() }
    }

    private var agentProgress: some View {
        HStack(alignment: .top, spacing: 10) {
            if model.agentIsRunning { ProgressView().controlSize(.small) }
            Text(model.agentStatus ?? "Reading the screenshot")
                .font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.agentIsRunning {
                Button("Stop") { model.stopAgent() }.keyboardShortcut(".", modifiers: .command)
                    .help("Stop the agent. Events already saved stay in the calendar.")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func agentQuestionCard(_ question: AgentQuestion) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
            Label(question.question, systemImage: "questionmark.bubble")
                .font(.headline).textSelection(.enabled)
            if !question.choices.isEmpty {
                VStack(alignment: .leading, spacing: 8) { agentChoiceButtons(question) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                TextField("Your answer", text: $agentAnswer).textFieldStyle(.roundedBorder)
                    .focused($answerFocused).onSubmit { submitAgentAnswer() }
                Button("Answer") { submitAgentAnswer() }
                    .disabled(agentAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { model.cancelAgentQuestion() }
            }
            }.padding(14)
        }
        .frame(height: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .id(question.id)
        .onAppear { agentAnswer = ""; answerFocused = question.choices.isEmpty }
    }

    private func agentChoiceButtons(_ question: AgentQuestion) -> some View {
        ForEach(Array(question.choices.prefix(6).enumerated()), id: \.offset) { _, choice in
            Button { model.answerAgentQuestion(choice) } label: {
                Text(choice).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered)
        }
    }

    private func submitAgentAnswer() {
        let answer = agentAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        model.answerAgentQuestion(answer)
        agentAnswer = ""
        answerFocused = false
    }

}

/// Compact brand and sidebar control hosted beside the native traffic lights.
struct WorkspaceTitlebarAccessory: View {
    @AppStorage("sidebarExpanded") private var sidebarExpanded = true

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    sidebarExpanded.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(ChromeButtonStyle())
            .help(sidebarExpanded ? "Collapse sidebar" : "Expand sidebar")

            AnimatedCalshotLogo()
                .frame(width: 24, height: 24)
            Text("Calshot")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
        }
        .frame(width: 188, height: 40, alignment: .leading)
        .padding(.leading, 6)
        .contentShape(Rectangle())
    }
}

enum WorkspaceSection: String { case capture, chat, calendars, tasks, library, settings
    var title: String { switch self { case .capture: "Capture"; case .chat: "Chat"; case .calendars: "Calendars"; case .tasks: "Tasks"; case .library: "Memory"; case .settings: "Settings" } }
    var symbol: String { switch self { case .capture: "viewfinder"; case .chat: "bubble.left.and.bubble.right"; case .calendars: "calendar"; case .tasks: "checklist"; case .library: "square.stack.3d.up"; case .settings: "gearshape" } }
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
