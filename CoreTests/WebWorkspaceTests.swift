import XCTest
import AppKit
import WebKit
import Auth
@testable import Calshot

@MainActor
final class WebWorkspaceTests: XCTestCase {
    func testPermissionHelperFitsSmallAndOffsetDisplays() {
        for visible in [CGRect(x: 0, y: 24, width: 1440, height: 876), CGRect(x: -1280, y: -400, width: 1280, height: 760), CGRect(x: 0, y: 0, width: 340, height: 600)] {
            for settings in [CGRect(x: visible.minX + 80, y: visible.minY + 100, width: 720, height: 600), CGRect(x: visible.maxX - 720, y: visible.minY, width: 720, height: 600)] {
                let frame = PermissionHelperGeometry.placement(settings: settings, visible: visible, size: CGSize(width: 380, height: 286))
                XCTAssertTrue(visible.insetBy(dx: 12, dy: 12).contains(frame))
            }
        }
        XCTAssertEqual(PermissionHelperGeometry.appKitFrame(CGRect(x: -900, y: 100, width: 700, height: 500), primaryTop: 900), CGRect(x: -900, y: 300, width: 700, height: 500))
    }
    func testPermissionDragCarriesActualBundleAsFileAndLegacyFinderPayload() {
        let url = URL(fileURLWithPath: "/Applications/Calshot Example.app")
        let writer = PermissionAppPasteboardWriter(url: url)
        XCTAssertEqual(writer.pasteboardPropertyList(forType: .fileURL) as? String, url.absoluteString)
        XCTAssertEqual(writer.pasteboardPropertyList(forType: .init("NSFilenamesPboardType")) as? [String], [url.path])
        XCTAssertNil(writer.pasteboardPropertyList(forType: .png))
    }
    func testPermissionPaletteUsesPackagedSharedTokens() {
        let light = PermissionPalette(dark: false), dark = PermissionPalette(dark: true)
        XCTAssertEqual(light.values["--primary"], "#0760ed")
        XCTAssertEqual(dark.values["--primary"], "#1262db")
        XCTAssertNotEqual(light.values["--surface-solid"], dark.values["--surface-solid"])
    }
    private func fixture(service: any CalendarDestinationService = CalendarDemoService()) -> CalshotModel {
        CalshotModel(calendarService: service, memoryStore: MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), loadsAIConnection: false)
    }
    private func row() -> CalendarActionProposal {
        CalendarActionProposal(draft: EventDraft(title: "Reviewed exam", startDate: Date(timeIntervalSince1970: 1_800_000_000), endDate: Date(timeIntervalSince1970: 1_800_003_600), isAllDay: false, timeZoneIdentifier: "America/Toronto", location: nil, url: nil, notes: nil, sourceText: "Exam source", confidence: 1, ambiguities: []))
    }
    private func mirrorUser(_ model: CalshotModel, id: UUID = UUID()) -> UUID {
        model.account.onAuthenticated = nil
        model.account.accept(User(id: id, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "casey@example.invalid", createdAt: .now, updatedAt: .now), provider: "email")
        return id
    }
    func testDeferredUpdateResumesOnceAndLocksNewBridgeWork() async {
        let model = fixture()
        let controller = model.softwareUpdates
        var safe = false, installs = 0
        controller.canRestart = { safe }
        XCTAssertTrue(controller.postponeRestart { installs += 1 })
        controller.resumeIfSafe(); XCTAssertEqual(installs, 0); XCTAssertFalse(controller.installing)
        safe = true; controller.resumeIfSafe(); controller.resumeIfSafe()
        XCTAssertEqual(installs, 1); XCTAssertTrue(controller.installing)
        let workspace = WebWorkspaceController(model: model, loadsResources: false)
        do { try await workspace.handle("newTask", [:]); XCTFail("New work accepted during relaunch") } catch { }
    }
    func testUpdateRestartWaitsForTasksReviewsAndSync() {
        let model = fixture()
        XCTAssertTrue(model.canRestartForSoftwareUpdate)
        model.agentIsRunning = true; XCTAssertFalse(model.canRestartForSoftwareUpdate); model.agentIsRunning = false
        model.isCapturing = true; XCTAssertFalse(model.canRestartForSoftwareUpdate); model.isCapturing = false
        model.isRecognizing = true; XCTAssertFalse(model.canRestartForSoftwareUpdate); model.isRecognizing = false
        model.agentIsWaitingForApproval = true; XCTAssertFalse(model.canRestartForSoftwareUpdate); model.agentIsWaitingForApproval = false
        model.agentCommand = "Unsaved request"; XCTAssertFalse(model.canRestartForSoftwareUpdate); model.agentCommand = ""
        model.accountSyncBusy = true; XCTAssertFalse(model.canRestartForSoftwareUpdate); model.accountSyncBusy = false
        model.sharingBusy = true; XCTAssertFalse(model.canRestartForSoftwareUpdate); model.sharingBusy = false
        model.macCalendarSyncBusy = true; XCTAssertFalse(model.canRestartForSoftwareUpdate); model.macCalendarSyncBusy = false
        model.calendarActions.replace(with: [row()]); XCTAssertFalse(model.canRestartForSoftwareUpdate)
        model.calendarActions.replace(with: []); XCTAssertTrue(model.canRestartForSoftwareUpdate)
    }
    func testUpdateBridgeRejectsNotchAndMalformedPreferences() async {
        let model = fixture()
        let notch = WebWorkspaceController(model: model, loadsResources: false, isNotch: true)
        let workspace = WebWorkspaceController(model: model, loadsResources: false)
        for (controller, action, body) in [(notch, "checkForUpdates", [:] as [String: Any]),
                                            (workspace, "updatePreferences", ["checks": "yes", "downloads": true]),
                                            (workspace, "updatePreferences", ["checks": 1, "downloads": true])] {
            do { try await controller.handle(action, body); XCTFail("Invalid update action accepted") } catch { }
        }
        XCTAssertNil(model.softwareUpdates.updater, "Fixture must not start network checks")
    }
    func testMacCalendarAllDayDatesNormalizeInclusiveEndsAndRespectDST() throws {
        let iso = ISO8601DateFormatter()
        for (start, end, zone, expectedEnd) in [
            ("2026-10-20T00:00:00Z", "2026-10-20T23:59:59Z", "GMT", "2026-10-21T00:00:00Z"),
            ("2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z", "GMT", "2026-10-21T00:00:00Z"),
            ("2026-11-01T04:00:00Z", "2026-11-02T04:59:59Z", "America/Toronto", "2026-11-02T05:00:00Z")
        ] {
            let event = CalendarEventSnapshot(eventIdentifier: "fixture", title: "All-day fixture", start: iso.date(from:start)!, end: iso.date(from:end)!, isAllDay: true, timeZone: zone, calendarName: "School")
            let payload = MacCalendarSnapshot.payload([event], start: event.start.addingTimeInterval(-86400), end: event.end.addingTimeInterval(86400)).arrayValue!.first!.objectValue!
            XCTAssertEqual(payload["end"], .string(expectedEnd))
            XCTAssertGreaterThan(payload["endDate"]!.stringValue!, payload["date"]!.stringValue!)
        }
    }
    func testMacCalendarUploadFailureDoesNotBlockOtherSelectedCalendars() async throws {
        let model = fixture(); await model.loadCalendars(); _ = mirrorUser(model)
        model.readableCalendars.append(CalendarDestinationInfo(id: "second", title: "Second", provider: .apple, isReadOnly: true))
        let first = MacCalendarMirror(id: UUID(), sourceKey: MacCalendarSnapshot.key("demo"), generation: UUID(), enabled: true, name: "First", complete: false)
        let second = MacCalendarMirror(id: UUID(), sourceKey: MacCalendarSnapshot.key("second"), generation: UUID(), enabled: true, name: "Second", complete: false)
        var uploaded: [String] = []; var persistedFailures = 0
        model.macCalendarRPC = { name, body, _ in
            if name == "write_mac_calendar_snapshot" {
                let fields = body.objectValue!
                if fields["mirror"] == .string(first.id.uuidString) {
                    if fields["failure"] == nil { throw CalendarToolArgumentError("Fixture upload rejected") }
                    persistedFailures += 1
                } else { uploaded.append(fields["mirror"]!.stringValue!) }
                return .null
            }
            return WebWorkspaceState.encoded([first,second])
        }
        await model.syncMacCalendars(force:true)
        XCTAssertEqual(uploaded, [second.id.uuidString]); XCTAssertEqual(persistedFailures,1)
        XCTAssertEqual(model.macCalendarMirrors.first?.error, "Fixture upload rejected")
        XCTAssertNil(model.macCalendarSyncError)
    }
    func testMacCalendarSyncDoesNotUploadWithoutSelection() async throws {
        let model = fixture(); _ = mirrorUser(model)
        var calls: [String] = []
        model.macCalendarRPC = { name, _, _ in calls.append(name); return .array([]) }
        await model.syncMacCalendars(force: true)
        XCTAssertTrue(calls.allSatisfy { $0 == "read_mac_calendar_sync" })
        XCTAssertTrue(model.macCalendarMirrors.isEmpty)
    }
    func testMacCalendarSyncUploadsOnlySelectedReadOnlyCalendarAndMinimalFields() async throws {
        let now = Date()
        let event = CalendarEventSnapshot(eventIdentifier: "private-provider-id", title: "Fictional class", start: now, end: now.addingTimeInterval(3600), isAllDay: false, calendarName: "School", notes: "Never upload these notes")
        let model = fixture(service: CalendarBrowserTestService(events: [event])); await model.loadCalendars(); _ = mirrorUser(model)
        let mirror = MacCalendarMirror(id: UUID(), sourceKey: MacCalendarSnapshot.key("browse"), generation: UUID(), enabled: true, name: "School", complete: false)
        var writes: [JSONValue] = []
        model.macCalendarRPC = { name, body, _ in
            if name == "write_mac_calendar_snapshot" { writes.append(body); return .null }
            return WebWorkspaceState.encoded([mirror])
        }
        await model.syncMacCalendars(force: true)
        XCTAssertEqual(writes.count, 1)
        let items = try XCTUnwrap(writes.first?.objectValue?["items"]?.arrayValue)
        XCTAssertEqual(items.count, 1)
        let json = String(data: try JSONEncoder().encode(items), encoding: .utf8)!
        XCTAssertFalse(json.contains("private-provider-id")); XCTAssertFalse(json.contains("Never upload"))
        XCTAssertEqual(items.first?.objectValue?["title"], .string("Fictional class"))
    }
    func testMacCalendarSyncDropsReadAfterAccountChanges() async throws {
        let service = CalendarBrowserTestService(events: [], suspendFirst: true)
        let model = fixture(service: service); await model.loadCalendars(); _ = mirrorUser(model)
        let mirror = MacCalendarMirror(id: UUID(), sourceKey: MacCalendarSnapshot.key("browse"), generation: UUID(), enabled: true, name: "School", complete: false)
        var writes = 0
        model.macCalendarRPC = { name, _, _ in if name == "write_mac_calendar_snapshot" { writes += 1; return .null }; return WebWorkspaceState.encoded([mirror]) }
        let task = Task { await model.syncMacCalendars(force: true) }
        while !(await service.isSuspended) { await Task.yield() }
        _ = mirrorUser(model)
        await service.resume(); await task.value
        XCTAssertEqual(writes, 0)
    }
    func testMacCalendarSyncRejectsUnboundedBusyReadsAndPreservesRecurringOccurrences() async throws {
        let now = Date()
        let rows = (0..<40).map { i in CalendarEventSnapshot(eventIdentifier: "event-\(i)", title: "Busy fixture", start: now, end: now.addingTimeInterval(3600), isAllDay: false, calendarName: "School") }
        do { _ = try await MacCalendarSnapshot.events(service: CalendarBrowserTestService(events: rows), calendarID: "browse", start: now.addingTimeInterval(-86400), end: now.addingTimeInterval(86400)); XCTFail("Incomplete reads must not replace snapshots") } catch {}
        var recurring = rows[0]; recurring.start = now.addingTimeInterval(86400); recurring.end = recurring.start.addingTimeInterval(3600)
        XCTAssertEqual(MacCalendarSnapshot.unique([rows[0],rows[0],recurring]).count, 2)
    }
    func testMacCalendarSyncBridgeRejectsInvalidAndNotchRequests() async throws {
        let model = fixture(); _ = mirrorUser(model)
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        for body: [String: Any] in [["calendarID": "missing", "enabled": true], ["calendarID": "demo", "enabled": "true"]] {
            do { try await bridge.handle("setMacCalendarSync", body); XCTFail("Invalid sync rejected") } catch {}
        }
        let notch = WebWorkspaceController(model: model, loadsResources: false, isNotch: true)
        do { try await notch.handle("syncMacCalendars", [:]); XCTFail("Settings-only sync rejected") } catch {}
        XCTAssertFalse(WebWorkspaceController.actionsAllowedBeforeSignIn.contains("setMacCalendarSync"))
    }
    func testCalendarBrowserLoadsOccurrencesWithoutTouchingReviewOrDestination() async throws {
        let model = fixture(); await model.loadCalendars()
        let draft = row().draft
        _ = try await model.calendarService.save(draft, to: .resolve(identifier: "demo"))
        model.calendarActions.replace(with: [row()])
        let token = WebWorkspaceState.approvalToken(model)
        let destination = model.selectedCalendarID
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        let start = draft.startDate!.addingTimeInterval(-86400), end = draft.endDate!.addingTimeInterval(86400)
        try await bridge.handle("loadCalendarEvents", ["start": ISO8601DateFormatter().string(from: start), "end": ISO8601DateFormatter().string(from: end), "calendarIDs": ["demo"]])
        XCTAssertEqual(bridge.calendarView.objectValue?["loaded"], .bool(true))
        XCTAssertEqual(bridge.calendarView.objectValue?["events"]?.arrayValue?.count, 1)
        XCTAssertEqual(model.selectedCalendarID, destination)
        XCTAssertEqual(WebWorkspaceState.approvalToken(model), token)
    }
    func testCalendarBrowserValidatesRangesAndUnknownCalendars() async throws {
        let model = fixture(); await model.loadCalendars()
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        let start = Date(), end = start.addingTimeInterval(64 * 86400)
        do { try await bridge.handle("loadCalendarEvents", ["start": ISO8601DateFormatter().string(from: start), "end": ISO8601DateFormatter().string(from: end), "calendarIDs": ["demo"]]); XCTFail("Unbounded range rejected") } catch {}
        do { try await bridge.handle("loadCalendarEvents", ["start": ISO8601DateFormatter().string(from: start), "end": ISO8601DateFormatter().string(from: start.addingTimeInterval(86400)), "calendarIDs": ["unknown"]]); XCTFail("Unknown calendar rejected") } catch {}
        XCTAssertEqual(bridge.calendarView.objectValue?["loaded"], .bool(false))
    }
    func testSettingsNavigationRejectsUnknownGroups() async throws {
        let bridge = WebWorkspaceController(model: fixture(), loadsResources: false)
        try await bridge.handle("navigate", ["page": "settings", "section": "calendars"])
        do { try await bridge.handle("navigate", ["page": "settings", "section": "invalid"]); XCTFail("Unknown settings section rejected") } catch {}
    }
    func testCalendarBrowserPreservesReadOnlyEventsAndReportsPartialFailure() async throws {
        let service = CalendarBrowserTestService(events: [])
        let model = fixture(service: service); await model.loadCalendars()
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        let start = Date(), end = start.addingTimeInterval(86400)
        try await bridge.handle("loadCalendarEvents", ["start": ISO8601DateFormatter().string(from: start), "end": ISO8601DateFormatter().string(from: end), "calendarIDs": ["browse", "broken"]])
        XCTAssertEqual(bridge.calendarView.objectValue?["loaded"], .bool(true))
        XCTAssertEqual(bridge.calendarView.objectValue?["errors"]?.arrayValue?.count, 1)
        XCTAssertEqual(bridge.calendarView.objectValue?["errors"]?.arrayValue?.first?.objectValue?["calendarIdentifier"], .string("broken"))
    }
    func testCalendarBrowserSubdividesBusyRangesBeyondAgentSearchLimit() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let events = (0..<100).map { index in CalendarEventSnapshot(eventIdentifier: "item-\(index)", title: "Busy calendar event", start: start.addingTimeInterval(Double(index) * 21600), end: start.addingTimeInterval(Double(index) * 21600 + 3600), isAllDay: false, calendarName: "Read-only") }
        let model = fixture(service: CalendarBrowserTestService(events: events)); await model.loadCalendars()
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        try await bridge.handle("loadCalendarEvents", ["start": ISO8601DateFormatter().string(from: start.addingTimeInterval(-1)), "end": ISO8601DateFormatter().string(from: start.addingTimeInterval(40 * 86400)), "calendarIDs": ["browse"]])
        XCTAssertEqual(bridge.calendarView.objectValue?["events"]?.arrayValue?.count, 100)
        XCTAssertEqual(bridge.calendarView.objectValue?["truncated"], .bool(false))
    }
    func testCalendarBrowserDropsLateResultsAfterMonthChanges() async throws {
        let service = CalendarBrowserTestService(events: [], suspendFirst: true)
        let model = fixture(service: service); await model.loadCalendars()
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let old = Task { try await bridge.handle("loadCalendarEvents", ["start": ISO8601DateFormatter().string(from: start), "end": ISO8601DateFormatter().string(from: start.addingTimeInterval(86400)), "calendarIDs": ["browse"]]) }
        while !(await service.isSuspended) { await Task.yield() }
        let next = start.addingTimeInterval(30 * 86400)
        try await bridge.handle("loadCalendarEvents", ["start": ISO8601DateFormatter().string(from: next), "end": ISO8601DateFormatter().string(from: next.addingTimeInterval(86400)), "calendarIDs": ["browse"]])
        await service.resume(); try await old.value
        XCTAssertEqual(bridge.calendarView.objectValue?["start"], .string(ISO8601DateFormatter().string(from: next)))
        XCTAssertEqual(bridge.calendarView.objectValue?["loading"], .bool(false))
    }
    func testPreLoginChatGPTConnectionDoesNotAllowWorkspaceOrCalendarWrites() async throws {
        XCTAssertFalse(WebWorkspaceController.actionsAllowedBeforeSignIn.contains("authChatGPT"))
        XCTAssertFalse(WebWorkspaceController.actionsAllowedBeforeSignIn.contains("authConnectChatGPTPlan"))
        XCTAssertFalse(WebWorkspaceController.actionsAllowedBeforeSignIn.contains("authCancelChatGPTPlan"))
        for action in ["approve", "send", "capture", "provider", "connectChatGPT"] {
            XCTAssertFalse(WebWorkspaceController.actionsAllowedBeforeSignIn.contains(action))
        }
        let bridge = WebWorkspaceController(model: fixture(), loadsResources: false, isNotch: true)
        do { try await bridge.handle("authConnectChatGPTPlan", [:]); XCTFail("Account entry remains scoped to the full window") } catch {}
    }
    func testVerifiedGoogleAndEmailKeepOneCanonicalAccountAndOnboarding() throws {
        let suite = "CalshotIdentity-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let identities = ["google", "email"].map { provider in UserIdentity(id: "fictional-" + provider, identityId: UUID(), userId: id, identityData: [:], provider: provider, createdAt: .now, lastSignInAt: .now, updatedAt: .now) }
        let verified = User(id: id, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "alex@example.invalid", createdAt: .now, emailConfirmedAt: .now, updatedAt: .now, identities: identities)
        let service = CalshotAccountService(enabled: false, preferences: defaults)
        service.accept(verified, provider: "email"); service.confirmAISetup(); service.finishOnboarding()
        XCTAssertEqual(service.userID, id); XCTAssertEqual(service.signInProvider, "email")
        service.accept(verified, provider: "google")
        XCTAssertEqual(service.userID, id); XCTAssertEqual(service.signInProvider, "google")
        XCTAssertTrue(service.onboarded); XCTAssertTrue(service.aiSetupConfirmed)
        let restored = CalshotAccountService(enabled: false, preferences: defaults); restored.accept(verified, provider: "restored")
        XCTAssertEqual(restored.userID, id); XCTAssertEqual(restored.signInProvider, "google")
        let other = User(id: UUID(), appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "alex@example.invalid", createdAt: .now, updatedAt: .now)
        restored.accept(other, provider: "email")
        XCTAssertEqual(restored.userID, other.id, "Client email equality must never merge distinct server identities")
        XCTAssertFalse(restored.onboarded)
    }
    func testOnboardingAIValidationCannotAdvanceWithoutCredentials() async throws {
        let model = fixture(); let bridge = WebWorkspaceController(model: model, loadsResources: false)
        XCTAssertThrowsError(try model.confirmOnboardingAI("chatgpt"))
        XCTAssertThrowsError(try model.confirmOnboardingAI("api"))
        XCTAssertThrowsError(try model.confirmOnboardingAI("unknown"))
        do { try await bridge.handle("authFinish", [:]); XCTFail("AI and calendar setup are required") } catch {}
        model.hasOpenAIAPIKey = true
        try model.confirmOnboardingAI("api")
        XCTAssertTrue(model.agentUseAPIKey); XCTAssertTrue(model.onboardingAIReady)
    }
    func testAccountSyncSanitizesImagesAndToolCallsAndRetainsReceipts() throws {
        let store = MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var item = row(); item.state = .added
        item.receipt = CalendarActionReceipt(destinationID: "fictional", calendarName: "Test", eventIdentifier: "receipt-identifier", savedAt: .now)
        let record = try store.recordCommand("Fictional question", transcript: [AgentTurn(role: "user", content: "Fictional question"), AgentTurn(role: "assistant", toolName: "create_events", arguments: "do not replay"), AgentTurn(role: "assistant", content: "One added")])
        let saved = try XCTUnwrap(store.updateProposals(for: record.id, proposals: [item]))
        let copy = saved.accountSyncCopy()
        XCTAssertTrue(copy.screenshotFileName.isEmpty); XCTAssertNil(copy.additionalScreenshots)
        XCTAssertEqual(copy.agentTranscript?.count, 2)
        XCTAssertEqual(copy.proposals?.first?.receipt?.eventIdentifier, "receipt-identifier")
        XCTAssertFalse(copy.proposals!.first!.isSelected)
        var cloud = AccountSyncDocument(); cloud.history[copy.id.uuidString] = copy
        try store.applyAccountSync(cloud)
        XCTAssertEqual(store.listRecords().first?.agentTranscript?.count, 3, "Unchanged local journals must remain intact")
    }
    func testAccountSyncInterruptedWritesCannotRecoverAgainstAnotherDevicesCalendar() throws {
        let store = MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let record = try store.recordCommand("Fictional move")
        var item = row(); item.state = .saving; item.attemptedDestinationID = "another-device-calendar"
        let saved = try XCTUnwrap(store.updateProposals(for: record.id, proposals: [item]))
        let copy = saved.accountSyncCopy()
        XCTAssertEqual(copy.proposals?.first?.state, .failed)
        XCTAssertNil(copy.proposals?.first?.attemptedDestinationID)
        XCTAssertEqual(store.listRecords().first?.proposals?.first?.state, .saving)
    }
    func testAccountHistoryFoldersAreIsolatedAndLegacyImportDoesNotResurrectDeletes() throws {
        let root = MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let legacy = try root.recordCommand("Legacy fictional task")
        let firstID = UUID(), secondID = UUID()
        let first = try root.accountStore(for: firstID)
        XCTAssertEqual(first.listRecords().map(\.id), [legacy.id])
        let second = try root.accountStore(for: secondID)
        XCTAssertTrue(second.listRecords().isEmpty)
        try first.deleteRecord(id: legacy.id)
        XCTAssertTrue(try root.accountStore(for: firstID).listRecords().isEmpty)
        XCTAssertEqual(root.listRecords().count, 1, "Legacy backup stays available")
        _ = try first.recordCommand("Another fictional task")
        try first.deleteAll()
        XCTAssertTrue(try root.accountStore(for: firstID).listRecords().isEmpty, "Clearing history must retain the completed migration marker")
    }
    func testAccountSyncDownloadsHistoryWithoutPublishingItAsAnEmptyDeviceDeletion() throws {
        let store = MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let record = try store.recordCommand("Fictional class")
        var cloud = AccountSyncDocument(); cloud.history[record.id.uuidString] = record.accountSyncCopy()
        let result = try AccountSyncMerge.merge(remote: cloud, local: [], baseline: AccountSyncBaseline())
        XCTAssertEqual(result.history.count, 1); XCTAssertTrue(result.deleted.isEmpty)
        let other = MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try other.applyAccountSync(result)
        XCTAssertEqual(other.listRecords().first?.id, record.id)
        XCTAssertNil(other.imageData(for: record))
    }
    func testAccountSyncTombstonesPreventOfflineResurrection() throws {
        let store = MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let record = try store.recordCommand("Fictional task")
        let baseline = AccountSyncBaseline(hashes: [record.id.uuidString: try record.syncHash()])
        var cloud = AccountSyncDocument(); cloud.deleted = [record.id]
        let result = try AccountSyncMerge.merge(remote: cloud, local: [record], baseline: baseline)
        XCTAssertTrue(result.history.isEmpty)
        try store.applyAccountSync(result)
        XCTAssertTrue(store.listRecords().isEmpty)
    }
    func testAccountSyncKeepsBothConcurrentHistoryVersions() throws {
        let store = MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let record = try store.recordCommand("Fictional task")
        let baseline = AccountSyncBaseline(hashes: [record.id.uuidString: try record.syncHash()])
        var local = record; local.agentTranscript = [AgentTurn(role: "user", content: "Local edit")]
        var remote = record; remote.agentTranscript = [AgentTurn(role: "user", content: "Remote edit")]
        var cloud = AccountSyncDocument(); cloud.history[record.id.uuidString] = remote.accountSyncCopy()
        let result = try AccountSyncMerge.merge(remote: cloud, local: [local], baseline: baseline)
        XCTAssertEqual(result.history.count, 2)
        XCTAssertEqual(Set(result.history.values.compactMap { $0.agentTranscript?.first?.content }), Set(["Local edit", "Remote edit"]))
    }

    func testSharingPublicationMinimizesFieldsForEachAccessLevel() async throws {
        for permission in ["busy", "titles", "details"] {
            let now = Date()
            let event = CalendarEventSnapshot(eventIdentifier: "provider-private-id", title: "Fictional workshop", start: now, end: now.addingTimeInterval(3600), isAllDay: false, location: "Example studio", calendarName: "Studio", url: URL(string: "https://example.invalid"), notes: "Fictional private note")
            let model = fixture(service: CalendarBrowserTestService(events: [event])); await model.loadCalendars(); let user = mirrorUser(model)
            let id = UUID(); var payload: JSONValue?
            model.sharingRPC = { name, body, _ in
                if name == "publish_calendar" { payload = body.objectValue?["items"]; return .object(["calendarID": .string(id.uuidString), "revision": .number(1)]) }
                if name == "read_calendar_sharing" { return WebWorkspaceState.encoded(CalendarSharingState()) }
                return .null
            }
            _ = try await model.publishSharingCalendar("browse", permission: permission, user: user, allowNew: true)
            let fields = try XCTUnwrap(payload?.arrayValue?.first?.objectValue)
            XCTAssertEqual(fields["title"], .string(permission == "busy" ? "Busy" : "Fictional workshop"))
            XCTAssertFalse(payload!.jsonString().contains("provider-private-id"))
            XCTAssertEqual(fields["notes"] != nil, permission == "details")
            XCTAssertEqual(fields["location"] != nil, permission == "details")
        }
        XCTAssertTrue(CalshotAccountService.sharingRPCNames.contains("search_friend_calendars"))
        XCTAssertFalse(CalshotAccountService.sharingRPCNames.contains("cloud_calendar_service"))
    }
    func testSharingRejectsStaleControlsAndDropsResultsAfterAccountSwitch() async throws {
        let model = fixture(); let user = mirrorUser(model)
        model.sharingLoaded = true
        var calls = 0
        model.sharingRPC = { _, _, _ in calls += 1; return .null }
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        do { try await bridge.handle("requestCalendarShare", ["email": "riley@example.invalid", "calendarIDs": ["demo"], "permission": "titles", "sharingToken": "stale"]); XCTFail("Stale sharing controls accepted") } catch {}
        XCTAssertEqual(calls, 0)
        model.sharingRPC = { _, _, _ in
            _ = self.mirrorUser(model)
            return .object(["sources": .array([]), "shares": .array([])])
        }
        do { try await model.readSharing(user: user); XCTFail("Old account response accepted") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(model.calendarSharing.shares.isEmpty)
    }
    func testSharingDoesNotPublishWithoutAnExplicitRequestOrActiveGrant() async throws {
        let model = fixture(); _ = mirrorUser(model)
        var calls: [String] = []
        model.sharingRPC = { name, _, _ in calls.append(name); return .object(["sources": .array([]), "shares": .array([])]) }
        await model.syncSharedCalendars(force: true)
        XCTAssertEqual(calls, ["read_calendar_sharing", "read_calendar_sharing"])
        let notch = WebWorkspaceController(model: model, loadsResources: false, isNotch: true)
        do { try await notch.handle("requestCalendarShare", [:]); XCTFail("Notch changed sharing") } catch {}
    }
    func testSidebarWidthRejectsInvalidValuesAndNotchActions() async throws {
        let model = fixture()
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        try await bridge.handle("sidebarWidth", ["width": 280.0])
        XCTAssertEqual(model.sidebarWidth, 280)
        for value in [183.0, 321.0, Double.nan, Double.infinity] {
            do { try await bridge.handle("sidebarWidth", ["width": value]); XCTFail("Invalid width accepted") } catch {}
            XCTAssertEqual(model.sidebarWidth, 280)
        }
        let notch = WebWorkspaceController(model: model, loadsResources: false, isNotch: true)
        do { try await notch.handle("sidebarWidth", ["width": 240.0]); XCTFail("Notch changed workspace width") } catch {}
        XCTAssertEqual(model.sidebarWidth, 280)
    }
    func testNotchHoverIntentAndLeaveGrace() {
        let now = Date(timeIntervalSince1970: 100)
        var state = NotchPresentationState()
        state.pointerChanged(true, now: now)
        state.advance(to: now.addingTimeInterval(0.04))
        XCTAssertFalse(state.isExpanded)
        state.advance(to: now.addingTimeInterval(0.09))
        XCTAssertTrue(state.isExpanded)
        state.pointerChanged(false, now: now.addingTimeInterval(1))
        // Repeated pointer polling must not postpone the leave deadline.
        state.pointerChanged(false, now: now.addingTimeInterval(1.3))
        state.advance(to: now.addingTimeInterval(1.3))
        XCTAssertTrue(state.isExpanded)
        state.advance(to: now.addingTimeInterval(1.36))
        XCTAssertFalse(state.isExpanded)
    }
    func testNotchBriefPassAndReentryDoNotFlicker() {
        let now = Date(timeIntervalSince1970: 100)
        var state = NotchPresentationState()
        state.pointerChanged(true, now: now)
        state.pointerChanged(false, now: now.addingTimeInterval(0.04))
        state.advance(to: now.addingTimeInterval(0.2))
        XCTAssertFalse(state.isExpanded)
        state.pointerChanged(true, now: now.addingTimeInterval(1))
        state.advance(to: now.addingTimeInterval(1.1))
        state.pointerChanged(false, now: now.addingTimeInterval(2))
        state.pointerChanged(true, now: now.addingTimeInterval(2.2))
        state.advance(to: now.addingTimeInterval(3))
        XCTAssertTrue(state.isExpanded)
    }
    func testNotchNotificationExpiresWithoutReopeningOrRearming() {
        let now = Date(timeIntervalSince1970: 100)
        var state = NotchPresentationState()
        state.observe(activityKey: "session:approval:row", notify: true, now: now)
        XCTAssertTrue(state.showsNotification)
        XCTAssertFalse(state.isExpanded)
        state.observe(activityKey: "session:approval:row", notify: true, now: now.addingTimeInterval(3))
        state.advance(to: now.addingTimeInterval(4.1))
        XCTAssertFalse(state.showsNotification)
        state.observe(activityKey: "session:approval:row", notify: true, now: now.addingTimeInterval(10))
        XCTAssertFalse(state.showsNotification)
        state.observe(activityKey: "session:question:new", notify: true, now: now.addingTimeInterval(11))
        XCTAssertTrue(state.showsNotification)
        XCTAssertFalse(state.isExpanded)
    }
    func testNotchEscapeStaysCollapsedUntilPointerLeavesAndReturns() {
        let now = Date(timeIntervalSince1970: 100)
        var state = NotchPresentationState()
        state.pointerChanged(true, now: now)
        state.advance(to: now.addingTimeInterval(0.1))
        state.collapse()
        state.pointerChanged(true, now: now.addingTimeInterval(1))
        state.advance(to: now.addingTimeInterval(2))
        XCTAssertFalse(state.isExpanded)
        state.pointerChanged(false, now: now.addingTimeInterval(3))
        state.pointerChanged(true, now: now.addingTimeInterval(4))
        state.advance(to: now.addingTimeInterval(4.1))
        XCTAssertTrue(state.isExpanded)
    }
    func testNotchNotificationExpiryPreservesPendingReviewAndStableIdentity() {
        let model = fixture()
        model.currentCaptureSessionID = UUID()
        model.agentIsWaitingForApproval = true
        model.calendarActions.replace(with: [row()])
        let activity = NotchActivity.resolve(model, completion: nil)
        let key = activity.notificationKey(model)
        let token = WebWorkspaceState.approvalToken(model)
        let now = Date(timeIntervalSince1970: 100)
        var state = NotchPresentationState()
        state.observe(activityKey: key, notify: true, now: now)
        state.advance(to: now.addingTimeInterval(5))
        XCTAssertFalse(state.showsNotification)
        XCTAssertEqual(WebWorkspaceState.approvalToken(model), token)
        XCTAssertFalse(model.calendarActions.proposals[0].isFinished)
        model.calendarActions.edit(model.calendarActions.proposals[0].id) { $0.title = "Corrected exam" }
        XCTAssertEqual(NotchActivity.resolve(model, completion: nil).notificationKey(model), key)
        model.currentCaptureSessionID = UUID()
        XCTAssertNotEqual(NotchActivity.resolve(model, completion: nil).notificationKey(model), key)
    }

    func testNotchWebContentAcceptsTheFirstInactiveClick() {
        let web = WorkspaceWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.acceptsInactiveClicks = true
        XCTAssertTrue(web.acceptsFirstMouse(for: nil))
    }

    func testNotchLayoutActionsStayScopedToNotchAndValidateArguments() async throws {
        let model = fixture()
        let workspace = WebWorkspaceController(model: model, loadsResources: false)
        let notch = WebWorkspaceController(model: model, loadsResources: false, isNotch: true)
        var expanded: Bool?
        notch.onNotchLayout = { value, _ in expanded = value }
        try await notch.handle("notchLayout", ["detail": true])
        XCTAssertEqual(expanded, true)
        try await notch.handle("notchLayout", ["detail": false])
        XCTAssertEqual(expanded, false)
        do { try await workspace.handle("notchLayout", ["detail": true]); XCTFail("Workspace cannot resize notch") } catch {}
        do { try await notch.handle("notchLayout", ["detail": "true"]); XCTFail("Invalid layout rejected") } catch {}
        do { try await notch.handle("notchLayout", ["detail": true, "height": 2000]); XCTFail("Unbounded height rejected") } catch {}
        XCTAssertNil(model.workspaceWindowController)
    }

    func testNotchApprovalRejectsStaleReviewToken() async throws {
        let model = fixture()
        model.calendarActions.replace(with: [row()])
        let notch = WebWorkspaceController(model: model, loadsResources: false, isNotch: true)
        do { try await notch.handle("approve", ["token": "old-session"]); XCTFail("Stale approval must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("review")) }
        XCTAssertFalse(model.calendarActions.proposals[0].isFinished)
    }

    func testAppearancePreferenceRoundTripsWithoutChangingUserDefaults() throws {
        let name = "CalshotAppearanceTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppAppearance.load(from: defaults), .system)
        for mode in AppAppearance.allCases { mode.save(to: defaults); XCTAssertEqual(AppAppearance.load(from: defaults), mode) }
        defaults.set("invalid", forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.load(from: defaults), .system)
    }
    func testAppearanceBridgeValidatesAndPublishesTheSelectedMode() async throws {
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let model = fixture(); let bridge = WebWorkspaceController(model: model, loadsResources: false)
        for mode in ["dark", "light", "system"] {
            try await bridge.handle("appearance", ["mode": mode])
            XCTAssertEqual(model.appearanceMode.rawValue, mode)
            let state = WebWorkspaceState.make(model, imageURL: nil, notice: nil, accounts: [], googleReady: false)
            XCTAssertEqual(state.objectValue?["settings"]?.objectValue?["appearance"]?.stringValue, mode)
        }
        XCTAssertNil(NSApp.appearance)
        do { try await bridge.handle("appearance", ["mode": "unknown"]); XCTFail("Invalid mode must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Light")) }
        XCTAssertEqual(model.appearanceMode, .system)
    }
    func testNotchReflectsWorkingApprovalFailureAndReceiptCompletion() {
        let model = fixture()
        XCTAssertEqual(NotchActivity.resolve(model, completion: nil).phase, .idle)
        model.isRecognizing = true
        XCTAssertEqual(NotchActivity.resolve(model, completion: nil).label, "Reading screenshot")
        model.isRecognizing = false
        model.agentIsWaitingForApproval = true
        model.calendarActions.replace(with: [row()])
        XCTAssertEqual(NotchActivity.resolve(model, completion: nil).label, "1 event to review")
        model.agentIsWaitingForApproval = false
        var failed = row(); failed.state = .failed
        model.calendarActions.replace(with: [failed])
        XCTAssertEqual(NotchActivity.resolve(model, completion: "1 added").phase, .failed)
        failed.state = .added; model.calendarActions.replace(with: [failed])
        XCTAssertEqual(NotchActivity.resolve(model, completion: "1 added").phase, .completed)
        XCTAssertEqual(NotchActivity.resolve(model, completion: nil).phase, .idle)
    }
    func testReviewTokenChangesWithSessionDestinationAndEdits() {
        let model = fixture(); model.calendarActions.replace(with: [row()])
        let initial = WebWorkspaceState.approvalToken(model)
        model.currentCaptureSessionID = UUID()
        let next = WebWorkspaceState.approvalToken(model)
        XCTAssertNotEqual(initial, next)
        model.selectedCalendarID = "fixture"
        XCTAssertNotEqual(next, WebWorkspaceState.approvalToken(model))
        let beforeEdit = WebWorkspaceState.approvalToken(model)
        model.calendarActions.edit(model.calendarActions.proposals[0].id) { $0.title = "Changed exam" }
        XCTAssertNotEqual(beforeEdit, WebWorkspaceState.approvalToken(model))
    }
    func testBridgeRejectsStaleApprovalAndSelection() async throws {
        let model = fixture(); let item = row(); model.calendarActions.replace(with: [item])
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        for action in ["approve", "selectProposal", "skipApproval", "editProposal"] {
            do { try await bridge.handle(action, ["token": "stale", "proposalID": item.id.uuidString, "selected": false]); XCTFail("Expected stale action rejection") }
            catch { XCTAssertTrue(error.localizedDescription.contains("review changed")) }
        }
        XCTAssertTrue(model.calendarActions.proposals[0].isSelected)
        XCTAssertNil(model.calendarActions.proposals[0].receipt)
    }
    func testBridgeRejectsOldQuestionAndUnknownAction() async {
        let model = fixture(); let bridge = WebWorkspaceController(model: model, loadsResources: false)
        for action in ["answer", "cancelQuestion", "unrestricted_write"] {
            do { try await bridge.handle(action, ["questionID": UUID().uuidString, "answer": "Yes"]); XCTFail("Expected rejection") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
    func testSnapshotContainsHumanConversationWithoutToolPayloads() throws {
        let model = fixture()
        model.agentMessages = [AgentTurn(role: "user", content: "Add my exam"),
            AgentTurn(role: "assistant", toolName: "search_events", arguments: "PRIVATE_TOOL_ARGUMENT"),
            AgentTurn(role: "tool", toolName: "ask_user", result: #"{"answer":"Use all-day"}"#)]
        let state = WebWorkspaceState.make(model, imageURL: nil, notice: nil, accounts: [], googleReady: false)
        let messages = try XCTUnwrap(state.objectValue?["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?.objectValue?["content"]?.stringValue, "Use all-day")
        XCTAssertFalse(state.jsonString().contains("PRIVATE_TOOL_ARGUMENT"))
        XCTAssertNil(state.objectValue?["googleClientSecret"])
        XCTAssertNil(state.objectValue?["accessToken"])
    }
    func testEditingRejectsInvalidLinkBeforeChangingDraft() async {
        let model = fixture(); let item = row(); model.calendarActions.replace(with: [item])
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        let fields: [String: Any] = ["title": "Changed", "start": "2026-10-20T09:00", "end": "2026-10-20T10:00", "timeZone": "America/Toronto", "url": "javascript:alert(1)"]
        do { try await bridge.handle("editProposal", ["token": WebWorkspaceState.approvalToken(model), "proposalID": item.id.uuidString, "fields": fields]); XCTFail("Expected invalid URL rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("valid")) }
        XCTAssertEqual(model.calendarActions.proposals[0].draft.title, item.draft.title)
    }
    func testNewTaskDoesNotReplayOrRemoveCalendarWrites() async throws {
        let model = fixture(); var item = row(); item.state = .added
        model.calendarActions.replace(with: [item]); model.agentMessages = [AgentTurn(role: "user", content: "Previous task")]
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        try await bridge.handle("newTask", [:])
        XCTAssertTrue(model.agentMessages.isEmpty)
        XCTAssertTrue(model.calendarActions.proposals.isEmpty)
        XCTAssertNotNil(model.currentCaptureSessionID)
    }
    func testCalendarQuestionStartsFreshHistoryWithoutOldScreenshotOrTranscript() async throws {
        let model = fixture()
        let previous = try model.memoryStore.recordCommand("Previous fictional task", transcript: [AgentTurn(role: "user", content: "Previous fictional task")])
        model.currentMemoryRecordID = previous.id
        model.currentCaptureSessionID = UUID()
        let previousSession = model.currentCaptureSessionID
        var completed = row(); completed.state = .added
        _ = try model.memoryStore.updateProposals(for: previous.id, proposals: [completed])
        model.calendarActions.replace(with: [completed])
        model.agentMessages = [AgentTurn(role: "user", content: "Previous fictional task")]
        model.agentTranscriptPrefix = model.agentMessages
        model.agentSummary = "Previous result"
        model.image = NSImage(size: NSSize(width: 16, height: 16)); model.recognizedText = "Previous screenshot"
        model.currentAgentSourceID = UUID()
        model.workspaceSelection = .calendars
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        try await bridge.handle("startCalendarTask", ["text": "Find my events tomorrow"])
        for _ in 0..<100 {
            if model.currentMemoryRecordID != nil && model.currentMemoryRecordID != previous.id { break }
            await Task.yield()
        }
        XCTAssertNotEqual(model.currentCaptureSessionID, previousSession)
        XCTAssertNotNil(model.currentMemoryRecordID)
        XCTAssertNotEqual(model.currentMemoryRecordID, previous.id)
        XCTAssertNil(model.image); XCTAssertNil(model.currentAgentSourceID); XCTAssertNil(model.ocrTask)
        XCTAssertTrue(model.recognizedText.isEmpty); XCTAssertTrue(model.agentTranscriptPrefix.isEmpty)
        XCTAssertTrue(model.calendarActions.proposals.isEmpty)
        XCTAssertNil(model.agentSummary)
        XCTAssertFalse(model.agentMessages.contains { $0.content == "Previous fictional task" })
        XCTAssertEqual(model.workspaceSelection, .chat)
        let preserved = try XCTUnwrap(model.memoryStore.listRecords().first { $0.id == previous.id })
        XCTAssertEqual(preserved.agentTranscript?.first?.content, "Previous fictional task")
        XCTAssertEqual(preserved.calendarProposals.first?.state, .added)
    }
    func testCalendarQuestionRejectsInvalidOrStaleActionsBeforeClearingHistory() async throws {
        let model = fixture()
        model.workspaceSelection = .calendars
        model.agentMessages = [AgentTurn(role: "user", content: "Keep this task")]
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        for text in [" ", String(repeating: "x", count: 8001)] {
            do { try await bridge.handle("startCalendarTask", ["text": text]); XCTFail("Invalid text rejected") } catch {}
        }
        model.agentQuestion = AgentQuestion(question: "Which event?", choices: [])
        do { try await bridge.handle("startCalendarTask", ["text": "Find my events"]); XCTFail("Pending question preserved") } catch {}
        model.agentQuestion = nil; model.agentIsWaitingForApproval = true
        do { try await bridge.handle("startCalendarTask", ["text": "Find my events"]); XCTFail("Pending approval preserved") } catch {}
        model.agentIsWaitingForApproval = false; model.agentIsRunning = true
        do { try await bridge.handle("startCalendarTask", ["text": "Find my events"]); XCTFail("Running task preserved") } catch {}
        model.agentIsRunning = false; model.workspaceSelection = .chat
        do { try await bridge.handle("startCalendarTask", ["text": "Find my events"]); XCTFail("Stale calendar action rejected") } catch {}
        model.workspaceSelection = .calendars
        let notch = WebWorkspaceController(model: model, loadsResources: false, isNotch: true)
        do { try await notch.handle("startCalendarTask", ["text": "Find my events"]); XCTFail("Workspace-only action rejected from notch") } catch {}
        XCTAssertEqual(model.agentMessages.first?.content, "Keep this task")
    }
    func testQueuedCalendarQuestionCannotReplaceANewerCapture() async {
        let model = fixture()
        let stale = UUID(), current = UUID()
        model.currentCaptureSessionID = current; model.agentIsRunning = true
        model.agentCommand = "Find my events tomorrow"
        await model.startAgentCommand(expectedSessionID: stale)
        XCTAssertEqual(model.currentCaptureSessionID, current)
        XCTAssertTrue(model.agentIsRunning)
        XCTAssertNil(model.currentMemoryRecordID)
    }
}

private actor CalendarBrowserTestService: CalendarDestinationService {
    let events: [CalendarEventSnapshot]
    var suspendFirst: Bool
    var continuation: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { continuation != nil }
    init(events: [CalendarEventSnapshot], suspendFirst: Bool = false) { self.events = events; self.suspendFirst = suspendFirst }
    func resume() { continuation?.resume(); continuation = nil }
    func availableDestinations() async throws -> [CalendarDestinationInfo] {
        [.init(id: "browse", title: "Read-only", provider: .apple, isReadOnly: true), .init(id: "broken", title: "Unavailable source", provider: .google, isReadOnly: true)]
    }
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] {
        guard destination == .eventKit(calendarIdentifier: "browse") else { throw CalendarDestinationError.calendarUnavailable }
        if suspendFirst { suspendFirst = false; await withCheckedContinuation { continuation = $0 } }
        return Array(events.filter { $0.start < end && $0.end > start }.prefix(40))
    }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] { [] }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String { throw CalendarDestinationError.calendarReadOnly }
}

@MainActor
final class AccountWebAuthenticationTests: XCTestCase {
    func testWorkerQueueCallbackReturnsToMainActorAndCompletesOnce() async throws {
        let started = expectation(description: "Browser started on main thread")
        var callback: AccountWebAuthentication.Completion?
        var returned = 0
        let browser = AccountWebAuthentication(factory: { _, scheme, _, complete in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(scheme, "calshot")
            callback = complete
            return .init(start: { started.fulfill(); return true }, cancel: {})
        })
        browser.onReturn = { XCTAssertTrue(Thread.isMainThread); returned += 1 }
        let flow = Task { try await browser.authenticate(URL(string: "https://example.invalid/authorize")!) }
        await fulfillment(of: [started], timeout: 2)
        let deliver = try XCTUnwrap(callback)
        let expected = URL(string: "calshot://auth/callback?code=fictional-code")!
        await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            deliver(expected, nil)
            deliver(expected, nil)
        }.value
        let actual = try await flow.value
        await Task.yield()
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(returned, 1)
        XCTAssertFalse(browser.isRunning)
    }
    func testExternalCallbackAndBrowserCompletionUseOneCodeExchange() async throws {
        let started = expectation(description: "Browser ready")
        var callback: AccountWebAuthentication.Completion?
        let browser = AccountWebAuthentication(factory: { _, _, _, complete in
            callback = complete
            return .init(start: { started.fulfill(); return true }, cancel: {})
        })
        let flow = Task { try await browser.authenticate(URL(string: "https://example.invalid/authorize")!) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(browser.receive(URL(string: "calshot://other/callback?code=untrusted")!))
        let expected = URL(string: "calshot://auth/callback?code=fictional-code")!
        XCTAssertTrue(browser.receive(expected))
        callback?(expected, nil)
        let actual = try await flow.value
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(browser.lastCallback, expected)
        XCTAssertFalse(browser.receive(expected))
    }
    func testCancellationDropsLateCallbackAndAllowsAnotherAttempt() async throws {
        let firstStarted = expectation(description: "First browser ready")
        let secondStarted = expectation(description: "Second browser ready")
        var callbacks: [AccountWebAuthentication.Completion] = []
        var cancelled = 0
        let browser = AccountWebAuthentication(factory: { _, _, _, complete in
            callbacks.append(complete)
            let first = callbacks.count == 1
            return .init(start: { (first ? firstStarted : secondStarted).fulfill(); return true }, cancel: { cancelled += 1 })
        })
        let url = URL(string: "https://example.invalid/authorize")!
        let first = Task { try await browser.authenticate(url) }
        await fulfillment(of: [firstStarted], timeout: 2)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancellation must finish the waiting operation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let second = Task { try await browser.authenticate(url) }
        await fulfillment(of: [secondStarted], timeout: 2)
        let expected = URL(string: "calshot://auth/callback?code=new-fictional-code")!
        callbacks[0](URL(string: "calshot://auth/callback?code=old-fictional-code")!, nil)
        callbacks[1](expected, nil)
        let actual = try await second.value
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(cancelled, 1)
    }
    func testBrowserStartFailureAndInvalidCallbackAreRecoverable() async throws {
        let browser = AccountWebAuthentication(factory: { _, _, _, _ in .init(start: { false }, cancel: {}) })
        do { _ = try await browser.authenticate(URL(string: "https://example.invalid/authorize")!); XCTFail("Failed browser must not hang") }
        catch { XCTAssertTrue(error.localizedDescription.contains("open Google sign-in")) }
        XCTAssertFalse(browser.isRunning)
        for raw in ["https://auth/callback", "calshot://wrong/callback", "calshot://auth/other", "calshot://user@auth/callback", "calshot://auth:123/callback"] {
            XCTAssertFalse(AccountWebAuthentication.isCallback(URL(string: raw)!))
        }
    }
}
