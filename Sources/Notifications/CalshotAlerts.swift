import AppKit
import AVFoundation
import Combine
import CoreAudio
import UserNotifications

/// Device-local notification choices. They never sync and never grant anything.
struct CalshotAlertPreferences: Codable, Equatable, Sendable {
    /// Calshot shows event alerts and task reminders in the notch.
    var enabled = true
    /// The Calshot chime plays with an alert (never during a call).
    var sound = true
    /// The voice agent says the alert aloud. Off until the user turns it on.
    var spoken = false
    /// The agent picks alerts for events and tasks it creates when the user did not say.
    var smartAlerts = true

    static let key = "calshot.alerts.preferences.v1"
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? .init()
    }
    func save(_ defaults: UserDefaults = .standard) { defaults.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

/// One alert moment: an event alert (start minus one provider alert) or a task reminder.
struct CalshotAlert: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case event, task }
    /// Stable per occurrence and lead time, so a relaunch or refresh never repeats it.
    let id: String
    let kind: Kind
    let title: String
    let start: Date
    let end: Date?
    let fireAt: Date
    let isAllDay: Bool
    let location: String?
    let joinURL: URL?
    let calendarName: String?
    let taskID: UUID?
    let leadMinutes: Int
    var snoozed = false

    /// Meeting cards with a link stay until acted on (or five minutes after the start); others leave after a few seconds.
    var persists: Bool { kind == .event && joinURL != nil }
    var symbol: String { kind == .task ? "checklist" : joinURL != nil ? "video.fill" : "calendar" }

    /// "in 10 min · 3:00 PM · Room 4", "Now · 3:00 PM", "Due 5:00 PM".
    func subtitle(now: Date = .now, locale: Locale = .current) -> String {
        let time = DateFormatter(); time.locale = locale; time.timeZone = .current
        time.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(start, inSameDayAs: now) ? "jmm" : "EEEjmm")
        if kind == .task { return "Due " + time.string(from: start) }
        if isAllDay {
            let day = DateFormatter(); day.locale = locale; day.setLocalizedDateFormatFromTemplate("EEEMMMd")
            return Calendar.current.isDate(start, inSameDayAs: now) ? "Today" : day.string(from: start)
        }
        let seconds = start.timeIntervalSince(now)
        let when: String
        if seconds > 59 * 60 * 24 { when = time.string(from: start) }
        else if seconds > 90 * 60 { when = "in \(Int((seconds / 3600).rounded())) h" }
        else if seconds >= 60 { when = "in \(Int((seconds / 60).rounded())) min" }
        else if seconds > -60 { when = "Now" }
        else { when = "Started \(Int((-seconds / 60).rounded())) min ago" }
        return [when + (seconds > 59 * 60 * 24 ? "" : " · " + time.string(from: start)), location?.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.prefix(2).joined(separator: " · ")
    }
    /// A short sentence for the voice agent and for accessibility.
    func spokenSummary(now: Date = .now) -> String {
        "\(kind == .task ? "Task reminder" : "Event alert"): \(title), \(subtitle(now: now))" + (joinURL != nil ? ", with a meeting link" : "") + "."
    }
}

/// Pure planning: which alerts exist and which are due. Native data only; nothing here writes.
enum CalshotAlertPlanner {
    /// Alerts missed while the Mac slept or was locked still show for this long after their time.
    static let catchUpWindow: TimeInterval = 10 * 60
    static let horizon: TimeInterval = 26 * 3600
    /// Events are read this far ahead so a "1 week before" alert of a later event is known in time.
    static let readAhead: TimeInterval = 8 * 86_400

    static func eventAlerts(_ events: [CalendarEventSnapshot], now: Date) -> [CalshotAlert] {
        var seen = Set<String>(), result: [CalshotAlert] = []
        for event in events where !isTaskDeadline(event) && !(event.isAllDay && event.isFree == true) {
            for lead in event.alertMinutes ?? [] {
                let fire = event.start.addingTimeInterval(-Double(lead) * 60)
                guard fire <= now.addingTimeInterval(horizon), event.end > now || fire > now.addingTimeInterval(-catchUpWindow) else { continue }
                // The same invitation can appear in two calendars; one alert is enough.
                let identity = (event.externalEventIdentifier ?? event.eventIdentifier) + "|" + String(Int(event.start.timeIntervalSince1970)) + "|" + String(lead)
                guard seen.insert(identity).inserted else { continue }
                result.append(CalshotAlert(id: "event|" + identity, kind: .event, title: event.title.isEmpty ? "Untitled event" : event.title,
                    start: event.start, end: event.end, fireAt: fire, isAllDay: event.isAllDay, location: event.location,
                    joinURL: joinURL(event), calendarName: event.calendarName, taskID: nil, leadMinutes: lead))
            }
        }
        return result.sorted { $0.fireAt < $1.fireAt }
    }

    /// Reminders this Mac delivers, from the same fire date the system notification uses.
    static func taskAlerts(_ tasks: [CalshotTask], deviceID: String, now: Date) -> [CalshotAlert] {
        tasks.compactMap { task in
            guard !task.deleted, !task.completed, task.reminderDeviceID == deviceID, let minutes = task.reminderMinutes,
                  let fire = task.reminderFireDate(now: now.addingTimeInterval(-catchUpWindow)),
                  fire <= now.addingTimeInterval(horizon), let day = task.dueDate,
                  let due = try? CalshotTask.date(day, time: task.dueTime ?? task.reminderTime, zone: task.timeZone) else { return nil }
            return CalshotAlert(id: "task|\(task.id.uuidString)|\(task.version.uuidString)|\(Int(fire.timeIntervalSince1970))", kind: .task, title: task.title,
                start: due, end: nil, fireAt: fire, isAllDay: false, location: nil, joinURL: nil, calendarName: nil, taskID: task.id, leadMinutes: minutes)
        }
    }

    /// Alerts whose moment has come and that were not shown yet. A long sleep never produces a burst: only alerts
    /// within the catch-up window, or for an event that has not started more than five minutes ago, remain.
    static func due(_ alerts: [CalshotAlert], delivered: Set<String>, now: Date) -> [CalshotAlert] {
        alerts.filter { alert in
            guard alert.fireAt <= now, !delivered.contains(alert.id) else { return false }
            if now.timeIntervalSince(alert.fireAt) <= catchUpWindow { return true }
            return alert.kind == .event && !alert.isAllDay && now < alert.start.addingTimeInterval(5 * 60)
        }.sorted { $0.fireAt < $1.fireAt }
    }

    static func isTaskDeadline(_ event: CalendarEventSnapshot) -> Bool { (event.notes ?? "").contains("Calshot task:") }

    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "around.co", "facetime.apple.com", "chime.aws", "gotomeeting.com", "meet.jit.si"]
    /// A video-meeting link from the event's URL, location or notes. Only https links on known meeting hosts.
    static func joinURL(_ event: CalendarEventSnapshot) -> URL? {
        if let url = event.url, isMeeting(url) { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        guard text.localizedCaseInsensitiveContains("https://"), let detector = linkDetector else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first(where: isMeeting)
    }
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    static func isMeeting(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Plays the bundled Calshot chime. Falls back to a quiet system sound when the file is missing.
enum CalshotAlertSound {
    static let fileName = "CalshotAlert.wav"
    @MainActor private static var sound: NSSound? = {
        guard let url = Bundle.main.url(forResource: "CalshotAlert", withExtension: "wav") else { return NSSound(named: "Glass") }
        return NSSound(contentsOf: url, byReference: true)
    }()
    @MainActor static func play() { sound?.stop(); sound?.volume = 0.7; sound?.play() }
    /// The same chime for task reminders macOS delivers while Calshot is not running; none when sound is off.
    static func notificationSound(enabled: Bool) -> UNNotificationSound? {
        guard enabled else { return nil }
        return Bundle.main.url(forResource: "CalshotAlert", withExtension: "wav") != nil ? UNNotificationSound(named: UNNotificationSoundName(fileName)) : .default
    }
}

/// Signals that make sound or speech inappropriate. Read on demand; nothing is monitored continuously.
enum CalshotAlertEnvironment {
    /// True when another app holds the default microphone, usually a call.
    static func microphoneInUseElsewhere(excludingVoice voiceActive: Bool) -> Bool {
        guard !voiceActive else { return false }
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return false }
        var running = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }
}

/// Schedules and shows Calshot's own alerts on this Mac: event alerts read from the user's calendars and the
/// task reminders this Mac delivers. It reads only; snooze and dismiss are local and never write a calendar.
@MainActor
final class CalshotAlertCenter: ObservableObject {
    @Published private(set) var preferences: CalshotAlertPreferences
    @Published private(set) var current: CalshotAlert?
    @Published private(set) var queued: [CalshotAlert] = []
    @Published private(set) var upcoming: [CalshotAlert] = []
    @Published private(set) var readError: String?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var systemPermission = "unknown"
    /// Whether voice could say an alert now. Checked with the permission, never per snapshot (it reads the Keychain).
    @Published private(set) var voiceReady = false
    var checkVoiceReady: () -> Bool = { false }
    /// Called after `current` changes so the notch can grow or shrink.
    var onPresentationChange: (() -> Void)?
    /// Asks the voice agent to say an alert; returns whether it will.
    var announce: ((CalshotAlert) async -> Bool)?
    var voiceActive: () -> Bool = { false }
    var clock: () -> Date = { Date() }

    private weak var model: CalshotModel?
    private let defaults: UserDefaults
    private var eventAlerts: [CalshotAlert] = []
    private var delivered: [String: Date]
    private var snoozed: [CalshotAlert] = []
    private var fireTimer: Timer?
    private var refreshTimer: Timer?
    private var dismissWork: DispatchWorkItem?
    private var hovering = false
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = UUID()
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var spokenTimes: [Date] = []
    static let deliveredKey = "calshot.alerts.delivered.v1"
    static let displayDuration: TimeInterval = 8

    init(model: CalshotModel?, defaults: UserDefaults = .standard) {
        self.model = model; self.defaults = defaults
        preferences = .load(defaults)
        delivered = (defaults.dictionary(forKey: Self.deliveredKey) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }
    deinit { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) } }

    func start() {
        guard observers.isEmpty, let model else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.fireDue() } })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        }
        // Calendar edits, connected calendars and task saves re-plan; repeated snapshots coalesce.
        Publishers.Merge3(model.$calendarContentToken.map { _ in () }, model.$readableCalendars.map { _ in () }, model.$taskDocument.map { _ in () })
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer.tolerance = 30; RunLoop.main.add(timer, forMode: .common); refreshTimer = timer
        refresh()
        Task { await refreshSystemPermission() }
    }

    func update(_ next: CalshotAlertPreferences) {
        guard next != preferences else { return }
        let turnedOn = next.enabled && !preferences.enabled
        preferences = next; next.save(defaults)
        if !next.enabled { clearPresentation() }
        if turnedOn { refresh() } else { reschedule() }
        model?.refreshTaskReminders()
    }

    /// Reads the next day of events from the user's own calendars and re-plans. Failures keep the last plan.
    func refresh() {
        guard let model, model.account.canUseWorkspace else { eventAlerts = []; reschedule(); return }
        refreshTask?.cancel()
        let generation = UUID(); refreshGeneration = generation
        let calendars = model.readableCalendars.filter { !$0.id.hasPrefix("unavailable:") }
        let service = model.calendarService, now = clock()
        refreshTask = Task { [weak self] in
            var events: [CalendarEventSnapshot] = [], failed: [String] = []
            await withTaskGroup(of: (String, [CalendarEventSnapshot]?).self) { group in
                for calendar in calendars {
                    group.addTask {
                        let found = try? await service.searchEvents(query: nil, start: now.addingTimeInterval(-CalshotAlertPlanner.catchUpWindow - 3600),
                                                                   end: now.addingTimeInterval(CalshotAlertPlanner.readAhead), in: .resolve(identifier: calendar.id))
                        return (calendar.title, found)
                    }
                }
                for await (title, found) in group { if let found { events += found } else { failed.append(title) } }
            }
            guard let self, !Task.isCancelled, self.refreshGeneration == generation else { return }
            self.eventAlerts = CalshotAlertPlanner.eventAlerts(events, now: self.clock())
            self.readError = failed.isEmpty ? nil : "Couldn’t read " + failed.sorted().prefix(3).joined(separator: ", ") + ". Alerts from \(failed.count == 1 ? "it" : "them") may be missing until it reconnects."
            self.lastRefresh = self.clock()
            self.reschedule()
        }
    }

    private var plan: [CalshotAlert] {
        guard let model, preferences.enabled else { return [] }
        let tasks = CalshotAlertPlanner.taskAlerts(model.taskDocument.items, deviceID: CalshotModel.syncDeviceID, now: clock())
        return (eventAlerts + tasks + snoozed).sorted { $0.fireAt < $1.fireAt }
    }

    /// One timer to the next alert. Task reminders fire a few seconds early so the system banner can be withdrawn.
    private func reschedule() {
        fireTimer?.invalidate(); fireTimer = nil
        let now = clock(), all = plan
        upcoming = all.filter { $0.fireAt > now && $0.fireAt <= now.addingTimeInterval(24 * 3600) && delivered[$0.id] == nil }.prefix(20).map { $0 }
        pruneDelivered(now: now)
        fireDue()
        // Task reminders fire three seconds early; one already inside that margin fires on the next turn.
        guard let target = all.filter({ delivered[$0.id] == nil && $0.fireAt > now }).map({ $0.kind == .task ? $0.fireAt.addingTimeInterval(-3) : $0.fireAt }).min() else { return }
        let next = max(target, now.addingTimeInterval(0.25))
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in Task { @MainActor in self?.fireDue(early: 3) } }
        timer.tolerance = 0.5; RunLoop.main.add(timer, forMode: .common); fireTimer = timer
    }

    private func fireDue(early: TimeInterval = 0) {
        guard preferences.enabled else { return }
        let now = clock()
        // A task reminder is due a few seconds early; events exactly on time.
        let due = CalshotAlertPlanner.due(plan, delivered: Set(delivered.keys), now: now.addingTimeInterval(early))
            .filter { $0.kind == .task || $0.fireAt <= now }
        guard !due.isEmpty else { if early > 0 { reschedule() }; return }
        // A locked screen can't show the notch: tasks keep their system notification, events wait for unlock.
        if CalshotAlertEnvironment.screenLocked { scheduleRetry(); return }
        for alert in due { delivered[alert.id] = now; snoozed.removeAll { $0.id == alert.id } }
        persistDelivered()
        // After a sleep only the newest few are shown, never a burst.
        let shown = Array(due.suffix(3))
        for alert in shown { enqueue(alert) }
        for alert in due where alert.kind == .task { withdrawSystemReminder(alert) }
        reschedule()
    }
    private func scheduleRetry() {
        fireTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in Task { @MainActor in self?.fireDue() } }
        RunLoop.main.add(timer, forMode: .common); fireTimer = timer
    }

    private func enqueue(_ alert: CalshotAlert) {
        if current == nil { present(alert) }
        else if current?.id != alert.id && !queued.contains(where: { $0.id == alert.id }) { queued = Array((queued + [alert]).suffix(3)) }
    }

    private func present(_ alert: CalshotAlert) {
        current = alert; hovering = false
        let onCall = CalshotAlertEnvironment.microphoneInUseElsewhere(excludingVoice: voiceActive())
        // During a call Calshot stays silent: the card shows, nothing plays or speaks.
        if !onCall && !alert.id.hasPrefix("sample|") && preferences.spoken { Task { await speak(alert) } }
        else if !onCall && preferences.sound { CalshotAlertSound.play() }
        armDismiss()
        onPresentationChange?()
    }

    /// Spoken alerts are rate-limited and only for events starting soon and task reminders.
    private func speak(_ alert: CalshotAlert) async {
        let now = clock()
        spokenTimes = spokenTimes.filter { now.timeIntervalSince($0) < 3600 }
        let soon = alert.kind == .task || (!alert.isAllDay && alert.start.timeIntervalSince(now) <= 15 * 60)
        guard soon, spokenTimes.count < 3, let announce else { if preferences.sound { CalshotAlertSound.play() }; return }
        if preferences.sound { CalshotAlertSound.play() }
        if await announce(alert) { spokenTimes.append(now) }
    }

    private func armDismiss() {
        dismissWork?.cancel()
        guard let alert = current, !hovering else { return }
        let deadline = alert.persists ? max(Self.displayDuration, alert.start.addingTimeInterval(5 * 60).timeIntervalSince(clock())) : Self.displayDuration
        let id = alert.id
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in if self?.current?.id == id { self?.dismiss() } } }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline, execute: work)
    }

    func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        if value { dismissWork?.cancel() } else { armDismiss() }
    }

    func dismiss() {
        dismissWork?.cancel()
        current = nil
        if !queued.isEmpty { present(queued.removeFirst()) } else { onPresentationChange?() }
    }

    /// Local snooze: the same alert again later. Never a calendar or task write.
    func snooze(minutes: Int? = nil) {
        guard let alert = current else { return }
        let now = clock()
        let delay: TimeInterval
        if let minutes { delay = Double(minutes) * 60 }
        else if alert.kind == .event, alert.start.timeIntervalSince(now) > 90 { delay = alert.start.timeIntervalSince(now) - 60 }
        else { delay = alert.kind == .task ? 3600 : 300 }
        let again = CalshotAlert(id: alert.id + "|snooze|" + String(Int(now.timeIntervalSince1970)), kind: alert.kind, title: alert.title, start: alert.start,
            end: alert.end, fireAt: now.addingTimeInterval(delay), isAllDay: alert.isAllDay, location: alert.location, joinURL: alert.joinURL,
            calendarName: alert.calendarName, taskID: alert.taskID, leadMinutes: alert.leadMinutes, snoozed: true)
        snoozed.append(again)
        dismiss(); reschedule()
    }
    func snoozeLabel(_ alert: CalshotAlert, now: Date = .now) -> String {
        if alert.kind == .task { return "1 hour" }
        return alert.start.timeIntervalSince(now) > 90 ? "1 min before" : "5 min"
    }

    func join() {
        guard let url = current?.joinURL, CalshotAlertPlanner.isMeeting(url) else { return }
        NSWorkspace.shared.open(url); dismiss()
    }

    /// Opens the event's day in Calendar, or Tasks, in the workspace.
    func open() {
        guard let alert = current, let model else { return }
        model.workspaceSelection = alert.kind == .task ? .tasks : .calendars
        if alert.kind == .task { model.loadTasks() }
        model.openPanel(); NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }

    /// A fictional sample from Settings, so the user can see and hear an alert. Nothing is read or written.
    func presentSample() {
        let now = clock()
        present(CalshotAlert(id: "sample|" + UUID().uuidString, kind: .event, title: "Sample alert", start: now.addingTimeInterval(10 * 60), end: now.addingTimeInterval(40 * 60),
            fireAt: now, isAllDay: false, location: nil, joinURL: nil, calendarName: nil, taskID: nil, leadMinutes: 10))
    }

    func clearPresentation() {
        dismissWork?.cancel(); queued = []; snoozed = []
        if current != nil { current = nil; onPresentationChange?() }
    }
    /// Sign-out or an account change: nothing from the previous account stays on screen or scheduled.
    func reset() {
        refreshTask?.cancel(); refreshGeneration = UUID(); eventAlerts = []; upcoming = []; readError = nil
        clearPresentation(); fireTimer?.invalidate(); fireTimer = nil
    }

    /// True when Calshot already showed this task's reminder, so macOS must not schedule it again.
    func showedReminder(for task: CalshotTask, now: Date = .now) -> Bool {
        guard let fire = task.reminderFireDate(now: now.addingTimeInterval(-CalshotAlertPlanner.catchUpWindow)) else { return false }
        return delivered["task|\(task.id.uuidString)|\(task.version.uuidString)|\(Int(fire.timeIntervalSince1970))"] != nil
    }
    private func withdrawSystemReminder(_ alert: CalshotAlert) {
        guard let id = alert.taskID?.uuidString else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(CalshotTask.reminderPrefix) && $0.hasSuffix(id) }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            let shown = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(CalshotTask.reminderPrefix) && $0.hasSuffix(id) }
            center.removeDeliveredNotifications(withIdentifiers: shown)
        }
    }

    private func pruneDelivered(now: Date) {
        let before = delivered.count
        delivered = delivered.filter { now.timeIntervalSince($0.value) < 2 * 86_400 }
        if delivered.count != before { persistDelivered() }
    }
    private func persistDelivered() { defaults.set(delivered.mapValues(\.timeIntervalSince1970), forKey: Self.deliveredKey) }

    func refreshSystemPermission() async {
        voiceReady = checkVoiceReady()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: systemPermission = "allowed"
        case .denied: systemPermission = "denied"
        case .notDetermined: systemPermission = "notDetermined"
        @unknown default: systemPermission = "unknown"
        }
    }
    func requestSystemPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshSystemPermission()
        model?.refreshTaskReminders()
    }
}

@MainActor
extension CalshotModel {
    func makeAlertCenter() -> CalshotAlertCenter {
        let center = CalshotAlertCenter(model: self)
        center.voiceActive = { [weak self] in self?.voiceSession.active == true }
        center.checkVoiceReady = { [weak self] in self.map { $0.voiceSession.active || $0.voiceSession.readyForProactiveStart } ?? false }
        center.onPresentationChange = { [weak self] in self?.alertPresentationChanged() }
        center.announce = { [weak self] alert in await self?.announceAlert(alert) ?? false }
        alertCenterSubscription = center.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return center
    }
    /// The notch grows into the alert card and returns to whatever it showed before.
    func alertPresentationChanged() {
        if alertCenter.current != nil {
            if notchLauncherController == nil { notchLauncherController = NotchExperienceController(model: self) }
            notchLauncherController?.showAlert()
        } else if voiceSession.active || voiceSession.needsAcknowledgement || voiceSession.error != nil {
            notchLauncherController?.showVoice()
        } else if notchEnabled {
            notchLauncherController?.show()
        } else if !agentIsWaitingForApproval && agentTaskReview == nil {
            notchLauncherController?.hide()
        }
    }
    /// Spoken alerts reuse an open voice session, or open one only when nothing would need the user first.
    func announceAlert(_ alert: CalshotAlert) async -> Bool {
        let session = voiceSession
        if !session.active {
            guard session.readyForProactiveStart, !agentIsRunning, !agentIsWaitingForApproval, agentTaskReview == nil, !isSaving,
                  agentQuestion == nil, !isRecognizing, !isCapturing else { return false }
        }
        return await session.announce(alert.spokenSummary())
    }
}
