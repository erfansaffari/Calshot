import XCTest
@testable import Calshot

/// Event alerts synced to providers, Calshot's own alert planning, task reminder choices and spoken alerts.
/// Fixtures are fictional; nothing writes to a real calendar.
final class EventAlertTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func draft(alerts: [Int]?) -> EventDraft {
        var draft = EventDraft(title: "Design review", startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false,
                               timeZoneIdentifier: "America/Toronto", location: nil, url: nil, notes: nil, sourceText: "fixture", confidence: 1, ambiguities: [])
        draft.alertMinutes = alerts
        return draft
    }
    private func account(_ provider: CalendarAccountConnection.Provider) -> CalendarAccountConnection.Account {
        .init(id: UUID(), provider: provider, email: "calendar@example.com", subject: "test", clientID: "desktop-test", accessToken: "fixture-token", refreshToken: "fixture-refresh", expiresAt: .distantFuture)
    }

    func testAlertValuesAreBoundedSortedAndUnique() throws {
        XCTAssertEqual(try EventAlerts.normalized([60, 10, 10]), [10, 60])
        XCTAssertThrowsError(try EventAlerts.normalized([1, 2, 3, 4, 5, 6]))
        XCTAssertThrowsError(try EventAlerts.normalized([40_321]))
        XCTAssertEqual(try EventAlerts.argument(.array([.number(15), .number(0)])), [0, 15])
        XCTAssertNil(try EventAlerts.argument(.null))
        XCTAssertThrowsError(try EventAlerts.argument(.array([.number(-5)])), "The agent can't set alerts after the start")
        XCTAssertThrowsError(try EventAlerts.argument(.array([.number(2.5)])))
        XCTAssertEqual(EventAlerts.summary([10, 1440]), "10 min before, 1 day before")
        XCTAssertEqual(EventAlerts.summary(nil), "Calendar default")
    }

    func testICalendarTriggersRoundTrip() {
        for minutes in [0, 5, 15, 60, 90, 1440, 1500, 10_080, -540] {
            XCTAssertEqual(EventAlerts.minutes(trigger: EventAlerts.trigger(minutes)), minutes, "\(minutes) → \(EventAlerts.trigger(minutes))")
        }
        XCTAssertEqual(EventAlerts.trigger(15), "-PT15M")
        XCTAssertEqual(EventAlerts.trigger(1440), "-P1D")
    }

    func testICloudWritesAndReadsAlarmsWithoutTouchingOtherAlarmsOrTheEventDescription() throws {
        var event = draft(alerts: [10, 60]); event.notes = "Agenda"
        let text = try ICS.new(event)
        XCTAssertEqual(text.components(separatedBy: "BEGIN:VALARM").count - 1, 2)
        var document = ICS(text)
        let component = try XCTUnwrap(document.events.first)
        XCTAssertEqual(component.alertMinutes, [10, 60])
        XCTAssertEqual(component.value("DESCRIPTION"), "Agenda", "An alarm's DESCRIPTION is not the event's notes")
        // Another app's fixed-date alarm survives; changing notes leaves every alarm in place.
        let fixed = ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Fixed", "TRIGGER;VALUE=DATE-TIME:20270115T090000Z", "END:VALARM"]
        let end = try XCTUnwrap(document.lines.lastIndex(of: "END:VEVENT"))
        document.lines.insert(contentsOf: fixed, at: end)
        var notesOnly = event; notesOnly.notes = "New agenda"; notesOnly.changedFieldNames = ["notes"]
        try document.change(notesOnly, recurrence: "", deleting: false)
        XCTAssertEqual(document.text.components(separatedBy: "BEGIN:VALARM").count - 1, 3)
        XCTAssertTrue(document.text.contains("DESCRIPTION:Fixed"))
        var alertsOnly = event; alertsOnly.alertMinutes = [5]; alertsOnly.changedFieldNames = ["alerts"]
        try document.change(alertsOnly, recurrence: "", deleting: false)
        let changed = try XCTUnwrap(ICS(document.text).events.first)
        XCTAssertEqual(changed.alertMinutes, [5])
        XCTAssertTrue(document.text.contains("TRIGGER;VALUE=DATE-TIME:20270115T090000Z"), "Fixed alarms are kept")
        XCTAssertEqual(changed.value("DESCRIPTION"), "New agenda")
    }

    func testGoogleAndOutlookAlertBodies() throws {
        let google = try RemoteCalendarService.body(draft(alerts: [60, 10]), provider: .google)
        let reminders = try XCTUnwrap(google["reminders"] as? [String: Any])
        XCTAssertEqual(reminders["useDefault"] as? Bool, false)
        XCTAssertEqual((reminders["overrides"] as? [[String: Any]])?.compactMap { $0["minutes"] as? Int }, [10, 60])
        XCTAssertNil(try RemoteCalendarService.body(draft(alerts: nil), provider: .google)["reminders"], "No choice keeps the calendar default")
        let outlook = try RemoteCalendarService.body(draft(alerts: [60, 10]), provider: .outlook)
        XCTAssertEqual(outlook["isReminderOn"] as? Bool, true)
        XCTAssertEqual(outlook["reminderMinutesBeforeStart"] as? Int, 10, "Outlook keeps the alert nearest the start")
        XCTAssertEqual(try RemoteCalendarService.body(draft(alerts: []), provider: .outlook)["isReminderOn"] as? Bool, false)
    }

    func testProviderSnapshotsReportEffectiveAlerts() throws {
        let route = RemoteCalendarService.Route(accountID: UUID(), calendarID: "Work")
        var calendar = CalendarDestinationInfo(id: route.calendarIdentifier, title: "Work", provider: .google, isReadOnly: false, timeZone: "America/Toronto")
        calendar.defaultAlertMinutes = [30]
        var value: [String: Any] = ["id": "e1", "summary": "Standup", "start": ["dateTime": "2027-01-15T09:00:00-05:00"], "end": ["dateTime": "2027-01-15T09:15:00-05:00"],
                                    "reminders": ["useDefault": true]]
        XCTAssertEqual(try RemoteCalendarService.snapshot(value, route: route, account: account(.google), calendar: calendar).alertMinutes, [30])
        value["reminders"] = ["useDefault": false, "overrides": [["method": "email", "minutes": 1440], ["method": "popup", "minutes": 5]]]
        XCTAssertEqual(try RemoteCalendarService.snapshot(value, route: route, account: account(.google), calendar: calendar).alertMinutes, [5], "Email reminders don't alert on this Mac")
        let outlook: [String: Any] = ["id": "e2", "subject": "Standup", "isAllDay": false, "isReminderOn": true, "reminderMinutesBeforeStart": 15,
                                      "start": ["dateTime": "2027-01-15T09:00:00.0000000", "timeZone": "America/Toronto"], "end": ["dateTime": "2027-01-15T09:15:00.0000000", "timeZone": "America/Toronto"]]
        let outlookCalendar = CalendarDestinationInfo(id: route.calendarIdentifier, title: "Work", provider: .outlook, isReadOnly: false)
        XCTAssertEqual(try RemoteCalendarService.snapshot(outlook, route: route, account: account(.outlook), calendar: outlookCalendar).alertMinutes, [15])
    }

    @MainActor
    func testAgentAlertArgumentsMapToDraftsAndUndoableChanges() throws {
        let created = try CalendarToolDraftMapper.create(.object(["title": .string("Interview"), "date": .string("2027-01-15"), "startTime": .string("10:00"), "endTime": .string("11:00"),
            "allDay": .bool(false), "timeZone": .string("America/Toronto"), "location": .null, "url": .null, "notes": .null, "evidence": .string("Interview January 15 2027 at 10"),
            "yearInferred": .bool(false), "dateAmbiguous": .bool(false), "alerts": .array([.number(1440), .number(60)])]), context: "Interview January 15 2027 at 10")
        XCTAssertEqual(created.alertMinutes, [60, 1440])
        let before = draft(alerts: [10])
        let removed = try CalendarToolDraftMapper.update(["eventIdentifier": .string("e"), "alerts": .null], before: before)
        XCTAssertEqual(removed.alertMinutes, [], "null removes every alert")
        XCTAssertEqual(removed.changedFieldNames, ["alerts"])
        XCTAssertEqual(CalendarAgentToolExecutor.changedFields(from: removed, to: before), ["alerts"], "Undo restores the earlier alerts")
        XCTAssertTrue(CalshotModel.agentCalendarGrantFields.contains("alerts"))
    }

    @MainActor
    func testAgentToolsExposeAlertsAndReminders() {
        let tools = CalendarAgent.tools.compactMap(\.objectValue)
        func properties(_ name: String) -> [String: JSONValue] {
            tools.first { $0["name"]?.stringValue == name }?["parameters"]?.objectValue?["properties"]?.objectValue ?? [:]
        }
        let events = properties("create_events")["events"]?.objectValue?["items"]?.objectValue?["properties"]?.objectValue
        XCTAssertNotNil(events?["alerts"])
        XCTAssertNotNil(properties("update_event")["alerts"])
        let tasks = properties("create_tasks")["tasks"]?.objectValue?["items"]?.objectValue?["properties"]?.objectValue
        XCTAssertNotNil(tasks?["reminderMinutes"]); XCTAssertNotNil(tasks?["reminderTime"])
        XCTAssertTrue(CalendarAgent.instructions.contains("ALERTS AND REMINDERS"))
        XCTAssertTrue(CalendarAgent.alertContext(smart: false).contains("off"))
    }
}

final class CalshotAlertPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ title: String, in minutes: Double, alerts: [Int]?, notes: String? = nil, url: URL? = nil, uid: String? = nil, allDay: Bool = false, free: Bool? = nil) -> CalendarEventSnapshot {
        var e = CalendarEventSnapshot(eventIdentifier: UUID().uuidString, title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval(minutes * 60 + 1800),
                                      isAllDay: allDay, timeZone: nil, location: "Room 4", calendarName: "Work", url: url, notes: notes, externalEventIdentifier: uid, isFree: free)
        e.alertMinutes = alerts
        return e
    }

    func testPlansOneAlertPerOccurrenceAndLeadAndSkipsTaskDeadlines() {
        let shared = event("Standup", in: 30, alerts: [10, 5], uid: "same-invite")
        var copy = shared; copy.eventIdentifier = "other-calendar"
        let plan = CalshotAlertPlanner.eventAlerts([shared, copy, event("Deadline", in: 60, alerts: [10], notes: "Calshot task: 123"),
                                                    event("No alerts", in: 20, alerts: nil), event("Holiday", in: 600, alerts: [0], allDay: true, free: true)], now: now)
        XCTAssertEqual(plan.map(\.title), ["Standup", "Standup"])
        XCTAssertEqual(plan.map(\.leadMinutes), [10, 5])
        XCTAssertEqual(plan.first?.fireAt, now.addingTimeInterval(20 * 60))
    }

    func testDueAlertsCatchUpBrieflyAndNeverBurstAfterALongSleep() {
        let plan = CalshotAlertPlanner.eventAlerts([event("Soon", in: 2, alerts: [10]), event("Long ago", in: -120, alerts: [10]), event("Later", in: 60, alerts: [10])], now: now)
        let due = CalshotAlertPlanner.due(plan, delivered: [], now: now)
        XCTAssertEqual(due.map(\.title), ["Soon"])
        XCTAssertTrue(CalshotAlertPlanner.due(plan, delivered: Set(due.map(\.id)), now: now).isEmpty, "Delivered alerts never repeat")
        // An event that started more than five minutes ago, after the catch-up window, stays quiet.
        let missed = CalshotAlertPlanner.eventAlerts([event("Missed", in: -6, alerts: [15])], now: now.addingTimeInterval(-3600))
        XCTAssertTrue(CalshotAlertPlanner.due(missed, delivered: [], now: now).isEmpty)
    }

    func testJoinLinksComeOnlyFromKnownHttpsMeetingHosts() {
        XCTAssertEqual(CalshotAlertPlanner.joinURL(event("Call", in: 5, alerts: [5], notes: "Join: https://us02web.zoom.us/j/123 or call"))?.host, "us02web.zoom.us")
        XCTAssertEqual(CalshotAlertPlanner.joinURL(event("Call", in: 5, alerts: [5], url: URL(string: "https://meet.google.com/abc-defg-hij")))?.host, "meet.google.com")
        XCTAssertNil(CalshotAlertPlanner.joinURL(event("Call", in: 5, alerts: [5], notes: "http://zoom.us/j/1 https://evil.example/zoom.us")))
    }

    func testAlertSubtitleCountsDown() {
        let alert = CalshotAlertPlanner.eventAlerts([event("Standup", in: 10, alerts: [10])], now: now)[0]
        XCTAssertTrue(alert.subtitle(now: now, locale: Locale(identifier: "en_US")).hasPrefix("in 10 min · "))
        XCTAssertTrue(alert.subtitle(now: now.addingTimeInterval(600), locale: Locale(identifier: "en_US")).hasPrefix("Now"))
        XCTAssertTrue(alert.subtitle(now: now, locale: Locale(identifier: "en_US")).hasSuffix("Room 4"))
    }

    func testTaskRemindersUseChoicesTimesAndThisMac() throws {
        var task = CalshotTask(title: "Submit essay", dueDate: "2027-01-15", dueTime: nil, timeZone: "America/Toronto", reminderMinutes: 2880)
        task.normalizeReminder(deviceID: "this-mac")
        XCTAssertEqual(task.reminderTime, CalshotTask.defaultReminderTime, "A date-only reminder gets a time")
        XCTAssertNoThrow(try task.validate())
        let fire = try XCTUnwrap(task.reminderFireDate(now: Date(timeIntervalSince1970: 0)))
        var toronto = Calendar(identifier: .gregorian); toronto.timeZone = TimeZone(identifier: "America/Toronto")!
        let parts = toronto.dateComponents([.month, .day, .hour], from: fire)
        XCTAssertEqual([parts.month, parts.day, parts.hour], [1, 13, 9], "Two days before keeps the clock time")
        XCTAssertEqual(CalshotAlertPlanner.taskAlerts([task], deviceID: "this-mac", now: fire.addingTimeInterval(-60)).count, 1)
        XCTAssertTrue(CalshotAlertPlanner.taskAlerts([task], deviceID: "another-mac", now: fire.addingTimeInterval(-60)).isEmpty)
        task.reminderMinutes = 45
        XCTAssertThrowsError(try task.validate())
        task.dueDate = nil; task.normalizeReminder(deviceID: nil)
        XCTAssertNil(task.reminderMinutes, "No date, no reminder")
    }

    func testPreferencesPersistPerDevice() {
        let defaults = UserDefaults(suiteName: "CalshotAlertPrefs." + UUID().uuidString)!
        XCTAssertEqual(CalshotAlertPreferences.load(defaults), CalshotAlertPreferences())
        XCTAssertFalse(CalshotAlertPreferences().spoken, "Spoken alerts start off")
        var prefs = CalshotAlertPreferences(); prefs.spoken = true; prefs.sound = false; prefs.save(defaults)
        XCTAssertEqual(CalshotAlertPreferences.load(defaults), prefs)
    }
}

@MainActor
final class SpokenAlertTests: XCTestCase {
    func testAnnouncementWaitsForAnIdleSessionAndCannotCallTools() async throws {
        let defaults = UserDefaults(suiteName: "SpokenAlert." + UUID().uuidString)!
        defaults.set(VoiceSessionController.acknowledgementVersion, forKey: "voice.acknowledgementVersion")
        let mouth = PreviewVoiceMouth(), client = ScriptedModelClient()
        client.replies = [.init(text: "Standup starts in five minutes.")]
        let session = VoiceSessionController(ears: PreviewVoiceEars(), mouth: mouth, audio: PreviewVoiceAudio(), overlay: PreviewVoiceOverlay(), frames: PreviewVoiceFrames(), defaults: defaults, permission: { true }, screenPermission: { false })
        session.eligible = { true }; session.hasKey = { true }; session.microphoneAuthorized = { true }
        session.makeBrain = { _ in VoiceBrain(client: client, executor: ScriptedExecutor(), sessionID: UUID()) }
        XCTAssertTrue(session.readyForProactiveStart)
        let started = await session.announce("Event alert: Standup, in 5 min.")
        XCTAssertTrue(started); XCTAssertTrue(session.proactive)
        session.tick(now: Date())
        for _ in 0..<2000 where mouth.spoken.isEmpty { await Task.yield() }
        XCTAssertEqual(mouth.spoken, ["Standup starts in five minutes."])
        let request = try XCTUnwrap(client.turnRequests.first)
        XCTAssertEqual(request.tools, [], "The announcement can only speak")
        let words = request.conversation.last?.value.objectValue?["content"]?.stringValue ?? ""
        XCTAssertTrue(words.contains("not a user request")); XCTAssertTrue(words.contains("Standup"))
        session.stop()
        XCTAssertFalse(session.proactive)
    }
}
