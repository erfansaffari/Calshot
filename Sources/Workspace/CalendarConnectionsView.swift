import SwiftUI

struct CalendarConnectionsView: View {
    @ObservedObject var model: CalshotModel
    @AppStorage("outlookCalendarClientID") private var outlookClientID = ""
    @State private var setupExpanded = false
    @State private var iCloudExpanded = false
    @State private var email = ""
    @State private var password = ""
    @State private var refreshing = false
    @State private var disconnecting: CalendarAccountConnection.Account?

    private var systemCalendars: [CalendarDestinationInfo] {
        model.readableCalendars.filter { !$0.id.hasPrefix("remote:") && !$0.id.hasPrefix("icloud:") && !$0.id.hasPrefix("unavailable:") }
    }
    private var activeCalendars: [CalendarDestinationInfo] {
        model.readableCalendars.filter { !$0.id.hasPrefix("unavailable:") }
    }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Calendars").font(.largeTitle.weight(.semibold))
                        Text("Manage accounts and choose where new events are added.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { refreshing = true; await model.loadCalendars(); refreshing = false } } label: {
                        Label(refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                    }.disabled(refreshing || model.calendarAccountIsConnecting)
                }
                summary
                if let message = model.calendarAccountMessage {
                    HStack(alignment: .top, spacing: 10) {
                        if model.calendarAccountIsConnecting { ProgressView().controlSize(.small) }
                        else { Image(systemName: model.calendarAccountError ? "exclamationmark.triangle.fill" : "info.circle") }
                        Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if model.calendarAccountIsConnecting { Button("Cancel sign-in") { model.cancelCalendarConnection() } }
                    }
                    .foregroundStyle(model.calendarAccountError ? Color.orange : Color.secondary)
                    .padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                if let message = model.calendarConnectionMessage {
                    Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Accounts").font(.title3.weight(.semibold))
                    Text("Accounts available through macOS are ready to use. Direct sign-in is optional.")
                        .font(.callout).foregroundStyle(.secondary)
                    providerCard(.google, icon: "g.circle", systemProvider: .google)
                    providerCard(.icloud, icon: "icloud", systemProvider: .apple)
                    providerCard(.outlook, icon: "envelope", systemProvider: .outlook)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Available calendars").font(.headline)
                        ForEach(activeCalendars) { calendar in
                            HStack(spacing: 10) {
                                Image(systemName: "calendar").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(calendar.title)
                                    Text("\(calendar.sourceName ?? calendar.provider.rawValue.capitalized) · \(isDirect(calendar) ? "Direct connection" : "via macOS")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(calendar.isReadOnly ? "Read only" : "Can add & edit").font(.caption).foregroundStyle(.secondary)
                            }
                            if calendar.id != activeCalendars.last?.id { Divider() }
                        }
                        if activeCalendars.isEmpty { Text("No calendars available. Connect an account above.").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Text("Notion Calendar uses these same Google, iCloud, and Outlook accounts. Connect its underlying account here to use its events.")
                    .font(.callout).foregroundStyle(.secondary)
                duplicateOptions
                setup.id("connection-setup")
            }.frame(maxWidth: 820).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await model.loadCalendars() }
        .onChange(of: setupExpanded) { _, expanded in
            if expanded { withAnimation { proxy.scrollTo("connection-setup", anchor: .bottom) } }
        }
        .disabled(model.agentIsRunning || model.isSaving)
        .confirmationDialog("Disconnect this account from Calshot?", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } })) {
            if let account = disconnecting {
                Button("Disconnect \(account.email)", role: .destructive) { Task { await model.disconnectCalendarAccount(account.id); disconnecting = nil } }
            }
        } message: { Text("Existing macOS connections remain available. Events will stay in your calendar.") }
        }
    }
    private var summary: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label(activeCalendars.isEmpty ? "No calendars connected" : "\(activeCalendars.count) calendars available", systemImage: activeCalendars.isEmpty ? "calendar.badge.exclamationmark" : "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(activeCalendars.isEmpty ? Color.orange : Color.green)
                Text("Calshot searches all available calendars. Changes stay on the event’s original calendar.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text("Add new events to").font(.callout)
                    Spacer()
                    Picker("Add new events to", selection: Binding(get: { model.selectedCalendarID ?? "" }, set: { model.selectedCalendarID = $0 })) {
                        Text("Choose a calendar").tag("")
                        ForEach(model.destinations) { Text("\($0.title) · \($0.sourceName ?? $0.provider.rawValue.capitalized)").tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 320).disabled(model.destinations.isEmpty)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private func providerCard(_ provider: CalendarAccountConnection.Provider, icon: String, systemProvider: CalendarDestinationInfo.Provider) -> some View {
        let native = systemCalendars.filter { $0.provider == systemProvider }
        let direct = model.directCalendarAccounts.filter { $0.provider == provider }
        let connecting = model.connectingCalendarProvider == provider
        let directUnavailable = !direct.isEmpty && direct.allSatisfy { account in model.readableCalendars.contains { $0.id == "unavailable:\(account.id.uuidString)" } }
        let needsAttention = native.isEmpty && directUnavailable
        return GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon).font(.title2).frame(width: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(provider.title).font(.headline)
                        Text(needsAttention ? "Needs attention" : native.isEmpty && direct.isEmpty ? "Not connected" : "Connected")
                            .font(.caption.weight(.medium)).foregroundStyle(needsAttention ? Color.orange : native.isEmpty && direct.isEmpty ? Color.secondary : Color.green)
                    }
                    Spacer()
                    if provider == .icloud {
                        Button(iCloudExpanded ? "Close" : "Connect another account") { iCloudExpanded.toggle() }
                            .disabled(model.calendarAccountIsConnecting)
                    } else if provider == .outlook && outlookClientID.isEmpty {
                        Text("Registration pending").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(connecting ? "Signing in…" : (native.isEmpty && direct.isEmpty ? "Connect account" : "Connect another account")) {
                            model.connectCalendarAccount(provider, clientID: provider == .google ? CalendarAccountConnection.googleClientID : outlookClientID)
                        }.disabled(model.calendarAccountIsConnecting)
                    }
                }
                if !native.isEmpty {
                    Label("\(native.count) calendars available via macOS", systemImage: "desktopcomputer").font(.callout)
                    Text(Array(Set(native.compactMap(\.sourceName))).sorted().joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(direct) { account in
                    let unavailable = model.readableCalendars.contains { $0.id == "unavailable:\(account.id.uuidString)" }
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.email).font(.callout)
                            Text(unavailable ? "Direct connection needs attention · Try reconnecting" : "Signed in directly to Calshot")
                                .font(.caption).foregroundStyle(unavailable ? Color.orange : Color.secondary)
                        }
                        Spacer()
                        Button("Disconnect") { disconnecting = account }.disabled(model.calendarAccountIsConnecting)
                    }
                }
                if provider == .google {
                    Link("Add Google through macOS", destination: URL(string: "x-apple.systempreferences:com.apple.preferences.internetaccounts")!)
                    Text("Sign in with Google and approve calendar access in your browser. No developer setup is needed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if provider == .outlook && outlookClientID.isEmpty {
                    Text("Direct sign-in is pending because the Waterloo tenant does not allow app registration.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if provider == .icloud && iCloudExpanded {
                    Divider()
                    Text("Connect directly with an Apple app-specific password.").font(.callout)
                    TextField("Apple Account email", text: $email).textFieldStyle(.roundedBorder)
                    SecureField("App-specific password", text: $password).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Connect iCloud") { model.connectICloudCalendar(email: email, appPassword: password); password = "" }
                            .disabled(email.isEmpty || password.isEmpty || model.calendarAccountIsConnecting)
                        Link("Create app-specific password", destination: URL(string: "https://account.apple.com/")!)
                    }
                    Text("Use a password in xxxx-xxxx-xxxx-xxxx format. It is stored in Keychain.").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
    private var setup: some View {
        DisclosureGroup("Connection setup", isExpanded: $setupExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Developer configuration").font(.headline)
                Text("Optional Microsoft developer configuration.").font(.caption).foregroundStyle(.secondary)
                TextField("Microsoft application client ID", text: $outlookClientID).textFieldStyle(.roundedBorder)
                Text("Outlook registration is pending.").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 12)
        }.font(.callout)
    }
    @ViewBuilder private var duplicateOptions: some View {
        let remote = activeCalendars.filter(isDirect)
        if !remote.isEmpty && !systemCalendars.isEmpty {
            DisclosureGroup("Reuse calendars already on this Mac") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("If a direct connection lists the same calendar as macOS, choose the matching account and calendar. Calshot will use one connection.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(remote) { calendar in
                        Menu("\(calendar.title) · Choose existing calendar") {
                            ForEach(systemCalendars) { existing in
                                Button("\(existing.title) · \(existing.sourceName ?? existing.provider.rawValue)") {
                                    Task { await model.reuseSystemCalendar(remoteID: calendar.id, systemID: existing.id) }
                                }
                            }
                        }
                    }
                }.padding(.top, 8)
            }
        }
    }
    private func isDirect(_ calendar: CalendarDestinationInfo) -> Bool { calendar.id.hasPrefix("remote:") || calendar.id.hasPrefix("icloud:") }
}
