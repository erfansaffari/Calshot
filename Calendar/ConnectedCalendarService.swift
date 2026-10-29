import Foundation

/// One routing layer for macOS calendars and directly connected provider accounts.
actor ConnectedCalendarService: CalendarDestinationService {
    private let system = EventKitCalendarService()
    private let remote = RemoteCalendarService()
    private let icloud = ICloudCalendarService()
    private var systemError: String?
    func availableDestinations() async throws -> [CalendarDestinationInfo] {
        var values: [CalendarDestinationInfo] = []
        do { values = try await system.availableDestinations(); systemError = nil }
        catch { systemError = error.localizedDescription }
        values += try await remote.availableDestinations()
        values += try await icloud.availableDestinations()
        if let systemError {
            values.append(.init(id: "unavailable:macos", title: "macOS calendars · Access unavailable", provider: .apple, isReadOnly: true))
            if values.count == 1 && CalendarAccountConnection.accounts().isEmpty { throw CalendarAccountConnection.ConnectionError(message: systemError) }
        }
        let errors = await remote.accountErrors.merging(icloud.accountErrors) { first, _ in first }
        for account in CalendarAccountConnection.accounts() where errors[account.id] != nil {
            if !values.contains(where: { RemoteCalendarService.Route(identifier: $0.id)?.accountID == account.id || ICloudCalendarService.Route(id: $0.id)?.accountID == account.id }) {
                values.append(.init(id: "unavailable:\(account.id.uuidString)", title: "\(account.email) · Connection unavailable", provider: account.provider == .google ? .google : account.provider == .icloud ? .apple : .outlook, isReadOnly: true))
            }
        }
        // EventKit calendar IDs are opaque. Titles and source display names do not
        // prove a provider identity, so uncertain cross-transport aliases require
        // explicit confirmation. Reads deduplicate exact external event UID/occurrence.
        let aliases = UserDefaults.standard.dictionary(forKey: "calendarTransportAliases") as? [String: String] ?? [:]
        // Explicitly confirmed transport aliases take priority over importing a second calendar.
        let systemIDs = Set(values.filter { !$0.id.hasPrefix("remote:") && !$0.id.hasPrefix("icloud:") && !$0.id.hasPrefix("unavailable:") }.map(\.id))
        return values.filter { aliases[$0.id].map { !systemIDs.contains($0) } ?? true }
    }
    private func transport(_ destination: CalendarDestination) throws -> any CalendarDestinationService {
        let id: String
        switch destination { case .eventKit(let value), .google(let value), .direct(let value): id = value }
        if id.hasPrefix("unavailable:") { throw CalendarAccountConnection.ConnectionError(message: id == "unavailable:macos" ? systemError ?? "macOS calendar access is unavailable." : "This account could not be loaded. Reconnect it in Calendar accounts.") }
        if id.hasPrefix("icloud:") { return icloud }
        return id.hasPrefix("remote:") ? remote : system
    }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] { try await transport(destination).matchingEvents(draft, in: destination) }
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] { try await transport(destination).searchEvents(query: query, start: start, end: end, in: destination) }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? { try await transport(destination).event(identifier: identifier, in: destination) }
    func event(matching selected: CalendarEventSnapshot, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? { try await transport(destination).event(matching: selected, in: destination) }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String { try await transport(destination).save(draft, to: destination) }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String { try await transport(destination).update(draft, identifier: identifier, in: destination) }
    func delete(identifier: String, in destination: CalendarDestination) async throws { try await transport(destination).delete(identifier: identifier, in: destination) }
    func update(_ draft: EventDraft, matching selected: CalendarEventSnapshot, in destination: CalendarDestination) async throws -> String { try await transport(destination).update(draft, matching: selected, in: destination) }
    func delete(matching selected: CalendarEventSnapshot, in destination: CalendarDestination) async throws { try await transport(destination).delete(matching: selected, in: destination) }
}
