import XCTest
import AppKit
import WebKit
import Auth
@testable import Calshot

@MainActor
final class WebWorkspaceTests: XCTestCase {
    func testTaskDateOnlyAndTimedDeadlinesStayAllDayAcrossDST() throws {
        let task = CalshotTask(title: "Field report", dueDate: "2026-11-01", dueTime: "17:00", timeZone: "America/Toronto")
        try task.validate(); let p = try task.deadline(owner: UUID())
        XCTAssertTrue(p.draft.isAllDay); XCTAssertEqual(p.draft.title, "Field report · due 17:00")
        XCTAssertEqual(p.draft.endDate!.timeIntervalSince(p.draft.startDate!), 25 * 3600)
        XCTAssertTrue(p.draft.isTaskDeadline == true); XCTAssertTrue(p.draft.notes!.contains("does not reserve work time"))
        XCTAssertThrowsError(try CalshotTask.date("2026-02-30", zone: "America/Toronto"))
        XCTAssertThrowsError(try CalshotTask.date("2026-03-08", time: "02:30", zone: "America/Toronto"))
        XCTAssertNoThrow(try CalshotTask(title: "Read chapter").validate())
        XCTAssertThrowsError(try CalshotTask(title: "No date", dueTime: "17:00").validate())
        XCTAssertThrowsError(try CalshotTask(title: "Alarm", dueDate: "2026-11-01", reminderMinutes: 60).validate())
    }
    func testTaskStoreDoesNotOverwriteCorruptFilesAndIsAccountScoped() throws {
        let root = MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a = CalshotTaskStore(directory: try root.accountStore(for: UUID()).locationURL)
        let b = CalshotTaskStore(directory: try root.accountStore(for: UUID()).locationURL)
        try a.save(.init(items: [CalshotTask(title: "Private fixture")]))
        XCTAssertEqual(try a.load().items.count, 1); XCTAssertTrue(try b.load().items.isEmpty)
        let corrupt = Data("broken fixture".utf8); try corrupt.write(to: a.url)
        XCTAssertThrowsError(try a.load()); XCTAssertEqual(try Data(contentsOf: a.url), corrupt)
        let duplicate = CalshotTask(title: "Duplicate")
        XCTAssertThrowsError(try b.save(.init(items: [duplicate, duplicate])))
    }
    func testTaskLoadFailureNeverExposesThePreviousAccountList() throws {
        let model = fixture(); try model.persistTasks(.init(items:[CalshotTask(title:"Previous account fixture")]))
        let next = MemoryStore(directoryURL:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        model.memoryStore = next; try model.taskStore.save(.init())
        let corrupt = Data("corrupt new-account fixture".utf8); try corrupt.write(to:model.taskStore.url)
        model.loadTasks()
        XCTAssertFalse(model.taskDataReady); XCTAssertTrue(model.taskDocument.items.isEmpty); XCTAssertNotNil(model.taskError)
        XCTAssertEqual(try Data(contentsOf:model.taskStore.url),corrupt)
    }
    func testSavingADatedTaskAddsItsDeadlineFromTheReceiptWithoutAReview() async throws {
        let model = fixture(service: CalendarDemoService())
        await model.loadCalendars()
        try await model.saveTask(["token":model.tasksToken,"title":"Field report","dueDate":"2026-11-10","dueTime":"17:00","timeZone":"America/Toronto","calendarID":"demo"])
        var task = try XCTUnwrap(model.taskDocument.items.first)
        XCTAssertNotNil(task.receipt); XCTAssertFalse(task.needsPublication); XCTAssertNil(task.calendarError)
        XCTAssertTrue(model.calendarActions.proposals.isEmpty, "Your own Save is the confirmation; no second review")
        XCTAssertTrue(model.memoryStore.listRecords().isEmpty)
        var events = try await model.calendarService.searchEvents(query:nil,start:.distantPast,end:.distantFuture,in:.resolve(identifier:"demo"))
        XCTAssertEqual(events.map(\.title), ["Field report · due 17:00"])
        // Editing the task updates the same entry.
        try await model.saveTask(["token":model.tasksToken,"taskID":task.id.uuidString,"title":"Field report draft","dueDate":"2026-11-11","dueTime":"17:00","timeZone":"America/Toronto"])
        task = model.taskDocument.items[0]
        events = try await model.calendarService.searchEvents(query:nil,start:.distantPast,end:.distantFuture,in:.resolve(identifier:"demo"))
        XCTAssertEqual(events.map(\.title), ["Field report draft · due 17:00"]); XCTAssertFalse(task.needsPublication)
        // Tasks only removes the published entry.
        try await model.saveTask(["token":model.tasksToken,"taskID":task.id.uuidString,"title":task.title,"dueDate":"2026-11-11","dueTime":"17:00","timeZone":"America/Toronto","calendarIntent":"none"])
        task = model.taskDocument.items[0]
        XCTAssertNil(task.receipt); XCTAssertEqual(task.calendarIntent, CalshotTaskCalendarIntent.none)
        events = try await model.calendarService.searchEvents(query:nil,start:.distantPast,end:.distantFuture,in:.resolve(identifier:"demo"))
        XCTAssertTrue(events.isEmpty)
    }
    func testDeletingATaskRemovesItsDeadlineOnlyWhenAsked() async throws {
        let model = fixture(service: CalendarDemoService()); await model.loadCalendars()
        try await model.saveTask(["token":model.tasksToken,"title":"Fictional essay","dueDate":"2026-11-10","calendarID":"demo"])
        try await model.saveTask(["token":model.tasksToken,"title":"Fictional quiz","dueDate":"2026-11-12","calendarID":"demo"])
        let essay = model.taskDocument.items[0], quiz = model.taskDocument.items[1]
        do { try await model.deleteTask(["token":model.tasksToken,"taskID":essay.id.uuidString,"removeDeadline":NSNumber(value:1)]); XCTFail("Accepted a number for removeDeadline") } catch {}
        do { try await model.deleteTask(["token":"stale","taskID":essay.id.uuidString,"removeDeadline":false]); XCTFail("Accepted a stale token") } catch {}
        try await model.deleteTask(["token":model.tasksToken,"taskID":essay.id.uuidString,"removeDeadline":false])
        try await model.deleteTask(["token":model.tasksToken,"taskID":quiz.id.uuidString,"removeDeadline":true])
        XCTAssertTrue(model.taskDocument.items.isEmpty); XCTAssertTrue(try model.taskStore.load().items.isEmpty)
        let events = try await model.calendarService.searchEvents(query:nil,start:.distantPast,end:.distantFuture,in:.resolve(identifier:"demo"))
        XCTAssertEqual(events.map(\.title), ["Fictional essay"], "Kept deadlines stay as ordinary calendar entries")
    }
    func testTaskReceiptRecoveryUsesLocalHistoryWithoutReplayingWrites() async throws {
        for device in [CalshotModel.syncDeviceID,UUID().uuidString] {
            let model=fixture(); let task=CalshotTask(title:"Report",dueDate:"2026-11-10",calendarID:"demo",calendarName:"Fixture")
            try model.persistTasks(.init(items:[task]))
            var proposal=try task.deadline(owner:nil,deviceID:device); proposal.state = .added
            proposal.receipt=CalendarActionReceipt(destinationID:"demo",calendarName:"Fixture",eventIdentifier:"historical-receipt",savedAt:.now)
            let record=try model.memoryStore.recordCommand("Fixture receipt")
            _ = try model.memoryStore.updateProposals(for:record.id,proposals:[proposal])
            model.loadTasks()
            XCTAssertEqual(model.taskDocument.items[0].receipt != nil,device==CalshotModel.syncDeviceID)
            let events=try await model.calendarService.searchEvents(query:nil,start:.distantPast,end:.distantFuture,in:.resolve(identifier:"demo"))
            XCTAssertTrue(events.isEmpty,"Receipt recovery must never replay a calendar write")
        }
    }
    func testTaskReorderCompletionAndArchivePreserveDeadlineAndReceipt() throws {
        let model = fixture()
        let first = CalshotTask(title:"First",dueDate:"2026-11-10",dueTime:"17:00",rank:0), second = CalshotTask(title:"Second",rank:1), third = CalshotTask(title:"Third",rank:2)
        try model.persistTasks(.init(items:[first,second,third]))
        let old = model.tasksToken
        try model.changeTask(["action":"reorderTask","token":old,"taskID":first.id.uuidString,"targetTaskID":third.id.uuidString])
        XCTAssertEqual(model.taskDocument.items.sorted{$0.rank < $1.rank}.map(\.title),["Second","Third","First"])
        XCTAssertEqual(model.taskDocument.items[0].dueDate,first.dueDate); XCTAssertEqual(model.taskDocument.items[0].dueTime,first.dueTime)
        XCTAssertThrowsError(try model.changeTask(["action":"completeTask","token":old,"taskID":first.id.uuidString,"completed":true]))
        try model.changeTask(["action":"completeTask","token":model.tasksToken,"taskID":first.id.uuidString,"completed":true])
        XCTAssertTrue(model.taskDocument.items[0].completed)
        try model.changeTask(["action":"archiveTask","token":model.tasksToken,"taskID":first.id.uuidString,"archived":true])
        try model.changeTask(["action":"archiveTask","token":model.tasksToken,"taskID":first.id.uuidString,"archived":false])
        XCTAssertFalse(model.taskDocument.items[0].deleted); XCTAssertEqual(model.taskDocument.items[0].dueDate,first.dueDate)
    }
    func testTaskApprovalRejectsWrongOwnerChangedTaskAndTimedDeadline() throws {
        let model = fixture(); let task = CalshotTask(title:"Essay",dueDate:"2026-11-10")
        try model.persistTasks(.init(items:[task])); var p = try task.deadline(owner:nil)
        model.calendarActions.replace(with:[p]); XCTAssertNoThrow(try model.validateTaskApproval())
        p.draft.taskOwnerID = UUID(); model.calendarActions.replace(with:[p]); XCTAssertThrowsError(try model.validateTaskApproval())
        p.draft.taskOwnerID = nil; p.draft.taskVersion = UUID(); model.calendarActions.replace(with:[p]); XCTAssertThrowsError(try model.validateTaskApproval())
        p.draft.taskVersion = task.version; p.draft.isAllDay = false; model.calendarActions.replace(with:[p]); XCTAssertThrowsError(try model.validateTaskApproval())
    }
    func testTaskWebKitNumbersAndBooleansHaveDistinctValidation() async throws {
        let model = fixture(); await model.loadCalendars()
        try await model.saveTask(["token":model.tasksToken,"taskID":NSNull(),"title":"Due task","dueDate":"2026-11-10","dueTime":"17:00","reminderMinutes":NSNumber(value:0),"calendarID":"demo"])
        XCTAssertEqual(model.taskDocument.items[0].reminderMinutes,0)
        model.calendarActions.replace(with:[])
        let second = CalshotTask(title:"Second",rank:1); var doc=model.taskDocument; doc.items.append(second); try model.persistTasks(doc)
        let first = model.taskDocument.items[0]
        try model.changeTask(["action":"reorderTask","token":model.tasksToken,"taskID":first.id.uuidString,"offset":NSNumber(value:1)])
        XCTAssertEqual(model.taskDocument.items[0].rank,1)
        XCTAssertThrowsError(try model.changeTask(["action":"completeTask","token":model.tasksToken,"taskID":first.id.uuidString,"completed":NSNumber(value:1)]))
        XCTAssertThrowsError(try model.changeTask(["action":"reorderTask","token":model.tasksToken,"taskID":first.id.uuidString,"offset":NSNumber(value:true)]))
    }
    func testTaskActionsRejectNotchAndOtherPages() async throws {
        let model = fixture(), body:[String:Any] = ["title":"Read","token":"stale"]
        for controller in [WebWorkspaceController(model:model,loadsResources:false,isNotch:true), WebWorkspaceController(model:model,loadsResources:false)] {
            do { try await controller.handle("saveTask",body); XCTFail("Task action escaped its page") } catch {}
        }
        XCTAssertTrue(model.taskDocument.items.isEmpty)
    }
    func testAgentTasksPreserveUnresolvedYearsAndNeverDuplicateImports() async throws {
        let model = fixture(); await model.loadCalendars()
        model.currentMemoryRecordID = try model.memoryStore.recordCommand("Add assignments").id
        let fields:[String:JSONValue] = ["calendarIdentifier":.null,"tasks":.array([.object(["title":.string("Essay"),"dueDate":.string("2026-11-10"),"dueTime":.string("17:00"),"yearResolved":.bool(false),"sourceText":.string("Essay due Nov 10 at 5pm; year unknown")])])]
        let result = try model.createAgentTasks(fields)
        XCTAssertTrue(result.proposals.isEmpty); XCTAssertTrue(model.taskDocument.items.isEmpty)
        XCTAssertNil(model.taskImport?.items.first?.dueDate)
        XCTAssertTrue(try XCTUnwrap(model.taskImport?.items.first?.calendarError).contains("year"))
        model.agentIsWaitingForApproval=true
        try model.commitTaskImport(); model.taskImport=nil
        _ = try model.createAgentTasks(fields); XCTAssertEqual(model.taskDocument.items.count,1)
    }
    func testAgentTaskImportRequiresCurrentApprovalAndSkipPersistsNothing() async throws {
        let model = fixture(); model.currentMemoryRecordID = try model.memoryStore.recordCommand("Add a task").id
        model.configureCalendarAgent(); let executor = try XCTUnwrap(model.agentToolExecutor); let session = UUID(); executor.activate(sessionID:session)
        let fields:JSONValue = .object(["calendarIdentifier":.null,"tasks":.array([.object(["title":.string("Read chapter"),"sourceText":.string("Read chapter; no deadline"),"yearResolved":.bool(false)])])])
        let skipped = Task { await executor.execute(name:"create_tasks",arguments:fields,sessionID:session) }
        while !model.agentIsWaitingForApproval { await Task.yield() }
        XCTAssertTrue(model.taskDocument.items.isEmpty)
        executor.skipApproval(); let skippedResult=try JSONDecoder().decode(JSONValue.self,from:Data((await skipped.value).utf8))
        XCTAssertEqual(skippedResult.objectValue?["tasksSaved"]?.arrayValue?.count,0); XCTAssertNil(model.taskImport)
        let accepted = Task { await executor.execute(name:"create_tasks",arguments:fields,sessionID:session) }
        while !model.agentIsWaitingForApproval { await Task.yield() }
        let workspace=WebWorkspaceController(model:model,loadsResources:false)
        let id=try XCTUnwrap(model.taskImport?.items.first?.id); let old=WebWorkspaceState.approvalToken(model)
        try await workspace.handle("selectInboxTaskImport",["token":old,"taskID":id.uuidString,"selected":false])
        do { try await workspace.handle("approve",["token":old]); XCTFail("Stale task approval accepted") } catch {}
        XCTAssertTrue(model.taskDocument.items.isEmpty)
        try await workspace.handle("selectInboxTaskImport",["token":WebWorkspaceState.approvalToken(model),"taskID":id.uuidString,"selected":true])
        try await workspace.handle("approve",["token":WebWorkspaceState.approvalToken(model)])
        let acceptedResult=try JSONDecoder().decode(JSONValue.self,from:Data((await accepted.value).utf8))
        XCTAssertEqual(acceptedResult.objectValue?["tasksSaved"]?.arrayValue?.count,1); XCTAssertEqual(model.taskDocument.items.count,1); XCTAssertNil(model.taskImport)
    }
    func testTaskSyncConflictKeepsLocalChangesAndExplicitlyRetainsBoth() async throws {
        let model = fixture(); let user = mirrorUser(model); model.activeLocalAccountID = user
        var local = CalshotTask(title:"Local edit"); let base = UUID(); local.version = UUID()
        var remote = local; remote.title = "Remote edit"; remote.version = UUID()
        try model.persistTasks(.init(items:[local],baseline:[local.id.uuidString:base]))
        var writes = 0
        model.taskRPC = { name, _, _ in
            if name == "read_task_state_v2" { return .object(["protocol_version":.number(2),"revision":.number(1),"items":WebWorkspaceState.encoded([remote])]) }
            writes += 1; return .number(2)
        }
        await model.syncTasks(); XCTAssertTrue(model.taskConflict); XCTAssertEqual(writes,0); XCTAssertEqual(model.taskDocument.items[0].title,"Local edit")
        await model.syncTasks(keepBoth:true); XCTAssertEqual(writes,1); XCTAssertEqual(model.taskDocument.items.count,2); XCTAssertFalse(model.taskConflict)
        XCTAssertTrue(model.taskDocument.items.contains{$0.title=="Local edit (local copy)" && $0.receipt==nil})
    }
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
    func testSelectedEventTaskLinkUsesNativeReadOnlySnapshotAndDurableReceipt() async throws {
        let service = SelectedTaskLinkFixture()
        let model = fixture(service: service); await model.loadCalendars(); model.workspaceSelection = .calendars
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        let range: [String: Any] = ["start": "2026-11-10T00:00:00Z", "end": "2026-11-11T00:00:00Z", "calendarIDs": ["selected-source"]]
        try await bridge.loadCalendarView(range)
        let event = try XCTUnwrap(bridge.calendarView.objectValue?["events"]?.arrayValue?.first?.objectValue)
        let handle = try XCTUnwrap(event["selectionHandle"]?.stringValue)
        let generation = try XCTUnwrap(event["selectionGeneration"]?.stringValue)
        let body: [String: Any] = ["selectionHandle": handle, "selectionGeneration": generation]
        try await bridge.handle("linkCalendarEventTask", body)
        try await bridge.handle("linkCalendarEventTask", body)
        XCTAssertEqual(model.taskDocument.items.count, 1)
        XCTAssertEqual(model.taskDocument.items.first?.sourceLink?.eventID, "native-source")
        XCTAssertEqual(model.taskDocument.items.first?.resolvedCalendarIntent, .existing)
        XCTAssertNil(model.taskDocument.items.first?.receipt)
        XCTAssertTrue(model.calendarActions.proposals.isEmpty)
        XCTAssertEqual(bridge.calendarTaskNotices[handle]?.objectValue?["receipt"]?.objectValue?["outcome"]?.stringValue, "alreadyLinked")
        let writes = await service.writes; XCTAssertEqual(writes, 0)
        try await bridge.loadCalendarView(range)
        do { try await bridge.handle("linkCalendarEventTask", body); XCTFail("Old view must not authorize a task link") } catch {}
    }
    func testSelectedEventTaskLinkRejectsForgedFieldsWrongPageStaleSessionAndRevokedAccess() async throws {
        let service = SelectedTaskLinkFixture()
        let model = fixture(service: service); await model.loadCalendars(); model.workspaceSelection = .calendars
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        let range: [String: Any] = ["start": "2026-11-10T00:00:00Z", "end": "2026-11-11T00:00:00Z", "calendarIDs": ["selected-source"]]
        try await bridge.loadCalendarView(range)
        let event = try XCTUnwrap(bridge.calendarView.objectValue?["events"]?.arrayValue?.first?.objectValue)
        let body: [String: Any] = ["selectionHandle": try XCTUnwrap(event["selectionHandle"]?.stringValue), "selectionGeneration": try XCTUnwrap(event["selectionGeneration"]?.stringValue)]
        var forged = body; forged["snapshot"] = ["title": "Forged title"]
        do { try await bridge.handle("linkCalendarEventTask", forged); XCTFail("Snapshot fields cannot confer authority") } catch {}
        model.workspaceSelection = .tasks
        do { try await bridge.handle("linkCalendarEventTask", body); XCTFail("Calendar origin required") } catch {}
        model.workspaceSelection = .calendars; model.agentIsRunning = true
        do { try await bridge.handle("linkCalendarEventTask", body); XCTFail("Idle session required") } catch {}
        model.agentIsRunning = false; let calendars = model.readableCalendars; model.readableCalendars = []
        do { try await bridge.handle("linkCalendarEventTask", body); XCTFail("Readable membership required") } catch {}
        model.readableCalendars = calendars; model.currentCaptureSessionID = UUID()
        do { try await bridge.handle("linkCalendarEventTask", body); XCTFail("Current session required") } catch {}
        XCTAssertTrue(model.taskDocument.items.isEmpty)
        let writes = await service.writes; XCTAssertEqual(writes, 0)
    }
    func testSelectedEventTaskLinkPublishesPersistentSourceChangeError() async throws {
        let service = SelectedTaskLinkFixture()
        let model = fixture(service: service); await model.loadCalendars(); model.workspaceSelection = .calendars
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        try await bridge.loadCalendarView(["start": "2026-11-10T00:00:00Z", "end": "2026-11-11T00:00:00Z", "calendarIDs": ["selected-source"]])
        let event = try XCTUnwrap(bridge.calendarView.objectValue?["events"]?.arrayValue?.first?.objectValue)
        let handle = try XCTUnwrap(event["selectionHandle"]?.stringValue)
        await service.changeSource()
        do { try await bridge.handle("linkCalendarEventTask", ["selectionHandle": handle, "selectionGeneration": try XCTUnwrap(event["selectionGeneration"]?.stringValue)]); XCTFail("Changed source must not link") } catch {}
        XCTAssertEqual(bridge.calendarTaskNotices[handle]?.objectValue?["status"]?.stringValue, "error")
        XCTAssertTrue(model.taskDocument.items.isEmpty)
        let writes = await service.writes; XCTAssertEqual(writes, 0)
    }
    func testDirectCalendarCreateSavesOnConfirmWithReceiptAndNoConversation() async throws {
        let service = DirectCalendarFixture()
        let model = fixture(service: service); await model.loadCalendars(); model.workspaceSelection = .calendars
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        try await bridge.handle("changeCalendarEvent", ["operation": "create", "fields": [
            "title": "Fictional office hours", "date": "2026-11-10", "allDay": false,
            "startTime": "09:00", "endTime": "10:00", "timeZone": "UTC", "calendarID": "direct-source"
        ]])
        let writes = await service.writeCount()
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(model.workspaceSelection, .calendars, "A direct change stays on Calendar")
        XCTAssertTrue(model.calendarActions.proposals.isEmpty, "A direct change never opens the Assistant review")
        XCTAssertTrue(model.memoryStore.listRecords().isEmpty, "A direct change adds no History record")
        XCTAssertEqual(bridge.calendarChange.objectValue?["operation"], .string("create"))
        XCTAssertEqual(bridge.calendarChange.objectValue?["title"], .string("Fictional office hours"))
        XCTAssertEqual(bridge.calendarChange.objectValue?["calendarName"], .string("Personal writable fixture"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.memoryStore.locationURL.appendingPathComponent("calendar-direct-journal.json").path))
    }
    func testDirectCalendarCreateStopsAtADuplicateUntilAddAnyway() async throws {
        let model = fixture(); await model.loadCalendars(); model.workspaceSelection = .calendars
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        let body: [String: Any] = ["operation": "create", "fields": [
            "title": "Fictional seminar", "date": "2026-11-10", "allDay": false,
            "startTime": "09:00", "endTime": "10:00", "timeZone": "UTC", "calendarID": "demo"
        ]]
        try await bridge.handle("changeCalendarEvent", body)
        do { try await bridge.handle("changeCalendarEvent", body); XCTFail("Added a duplicate without asking") }
        catch { XCTAssertTrue(error.localizedDescription.hasPrefix(DirectCalendarWriter.duplicatePrefix)) }
        var events = try await model.calendarService.searchEvents(query: nil, start: .distantPast, end: .distantFuture, in: .resolve(identifier: "demo"))
        XCTAssertEqual(events.count, 1)
        do { try await bridge.handle("changeCalendarEvent", body.merging(["allowDuplicate": NSNumber(value: 1)]) { $1 }); XCTFail("Accepted a number for allowDuplicate") } catch {}
        try await bridge.handle("changeCalendarEvent", body.merging(["allowDuplicate": true]) { $1 })
        events = try await model.calendarService.searchEvents(query: nil, start: .distantPast, end: .distantFuture, in: .resolve(identifier: "demo"))
        XCTAssertEqual(events.count, 2)
    }
    func testDirectCalendarUpdateAndDeleteApplyToTheFreshSelectedEvent() async throws {
        let service = DirectCalendarFixture()
        let model = fixture(service: service); await model.loadCalendars(); model.workspaceSelection = .calendars
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        try await bridge.loadCalendarView(["start": "2026-11-10T00:00:00Z", "end": "2026-11-11T00:00:00Z", "calendarIDs": ["direct-source"]])
        let event = try XCTUnwrap(bridge.calendarView.objectValue?["events"]?.arrayValue?.first?.objectValue)
        do {
            try await bridge.handle("changeCalendarEvent", ["operation": "update", "selectionHandle": try XCTUnwrap(event["selectionHandle"]?.stringValue), "selectionGeneration": try XCTUnwrap(event["selectionGeneration"]?.stringValue), "fields": [
                "title": "Fictional workshop", "date": "2026-11-10", "allDay": false,
                "startTime": "08:00", "endTime": "09:00", "timeZone": "UTC", "location": "", "url": "", "notes": ""
            ]])
            XCTFail("Saved an edit with no changes")
        } catch {}
        try await bridge.handle("changeCalendarEvent", ["operation": "update", "selectionHandle": try XCTUnwrap(event["selectionHandle"]?.stringValue), "selectionGeneration": try XCTUnwrap(event["selectionGeneration"]?.stringValue), "fields": [
            "title": "Fictional workshop moved", "date": "2026-11-10", "allDay": false,
            "startTime": "11:00", "endTime": "12:00", "timeZone": "UTC", "location": "", "url": "", "notes": ""
        ]])
        let writesAfterUpdate = await service.writeCount()
        XCTAssertEqual(writesAfterUpdate, 1)
        XCTAssertEqual(bridge.calendarChange.objectValue?["operation"], .string("update"))
        XCTAssertTrue(model.calendarActions.proposals.isEmpty)
        try await bridge.loadCalendarView(["start": "2026-11-10T00:00:00Z", "end": "2026-11-11T00:00:00Z", "calendarIDs": ["direct-source"]])
        let changed = try XCTUnwrap(bridge.calendarView.objectValue?["events"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(changed["title"], .string("Fictional workshop moved"))
        try await bridge.handle("changeCalendarEvent", ["operation": "delete", "selectionHandle": try XCTUnwrap(changed["selectionHandle"]?.stringValue), "selectionGeneration": try XCTUnwrap(changed["selectionGeneration"]?.stringValue)])
        let writesAfterDelete = await service.writeCount()
        XCTAssertEqual(writesAfterDelete, 2)
        XCTAssertEqual(bridge.calendarChange.objectValue?["operation"], .string("delete"))
        XCTAssertEqual(bridge.calendarChange.objectValue?["title"], .string("Fictional workshop moved"))
        XCTAssertTrue(model.memoryStore.listRecords().isEmpty)
    }
    func testDirectCalendarRecurringOccurrenceChangesThisDateOnly() async throws {
        let service = DirectCalendarFixture()
        await service.markRecurring()
        let model = fixture(service: service); await model.loadCalendars(); model.workspaceSelection = .calendars
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        try await bridge.loadCalendarView(["start": "2026-11-10T00:00:00Z", "end": "2026-11-11T00:00:00Z", "calendarIDs": ["direct-source"]])
        let event = try XCTUnwrap(bridge.calendarView.objectValue?["events"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(event["isRecurring"], .bool(true))
        try await bridge.handle("changeCalendarEvent", ["operation": "update", "selectionHandle": try XCTUnwrap(event["selectionHandle"]?.stringValue), "selectionGeneration": try XCTUnwrap(event["selectionGeneration"]?.stringValue), "fields": [
            "title": "This date only", "date": "2026-11-10", "allDay": false,
            "startTime": "11:00", "endTime": "12:00", "timeZone": "UTC"
        ]])
        let writes = await service.writeCount()
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(bridge.calendarChange.objectValue?["thisDateOnly"], .bool(true))
    }
    func testDirectCalendarChangeRejectsStaleReadOnlyAndNotchWithoutWriting() async throws {
        let writable = DirectCalendarFixture()
        let model = fixture(service: writable); await model.loadCalendars(); model.workspaceSelection = .calendars
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        try await bridge.loadCalendarView(["start": "2026-11-10T00:00:00Z", "end": "2026-11-11T00:00:00Z", "calendarIDs": ["direct-source"]])
        let event = try XCTUnwrap(bridge.calendarView.objectValue?["events"]?.arrayValue?.first?.objectValue)
        let notch = WebWorkspaceController(model: model, loadsResources: false, isNotch: true)
        do { try await notch.handle("changeCalendarEvent", ["operation": "delete", "selectionHandle": try XCTUnwrap(event["selectionHandle"]?.stringValue), "selectionGeneration": try XCTUnwrap(event["selectionGeneration"]?.stringValue)]); XCTFail("The notch changed a calendar event") } catch {}
        await writable.changeSourceTitle()
        do {
            try await bridge.handle("changeCalendarEvent", ["operation": "update", "selectionHandle": try XCTUnwrap(event["selectionHandle"]?.stringValue), "selectionGeneration": try XCTUnwrap(event["selectionGeneration"]?.stringValue), "fields": [
                "title": "Forged change", "date": "2026-11-10", "allDay": false,
                "startTime": "11:00", "endTime": "12:00", "timeZone": "UTC"
            ]])
            XCTFail("Stale selected event was changed")
        } catch {}
        let staleWrites = await writable.writeCount()
        XCTAssertEqual(staleWrites, 0)
        XCTAssertEqual(bridge.calendarChange, .null)

        let readOnly = SelectedTaskLinkFixture()
        let readOnlyModel = fixture(service: readOnly); await readOnlyModel.loadCalendars(); readOnlyModel.workspaceSelection = .calendars
        let readOnlyBridge = WebWorkspaceController(model: readOnlyModel, loadsResources: false)
        try await readOnlyBridge.loadCalendarView(["start": "2026-11-10T00:00:00Z", "end": "2026-11-11T00:00:00Z", "calendarIDs": ["selected-source"]])
        let readOnlyEvent = try XCTUnwrap(readOnlyBridge.calendarView.objectValue?["events"]?.arrayValue?.first?.objectValue)
        do {
            try await readOnlyBridge.handle("changeCalendarEvent", ["operation": "delete", "selectionHandle": try XCTUnwrap(readOnlyEvent["selectionHandle"]?.stringValue), "selectionGeneration": try XCTUnwrap(readOnlyEvent["selectionGeneration"]?.stringValue)])
            XCTFail("Read-only selected event was deleted")
        } catch {}
        let readOnlyWrites = await readOnly.writes
        XCTAssertEqual(readOnlyWrites, 0)
    }
    func testDirectCalendarChangeIsNotBlockedByAPendingAssistantReview() async throws {
        let model = fixture(); await model.loadCalendars(); model.workspaceSelection = .calendars
        model.calendarActions.replace(with: [row()]); model.agentIsWaitingForApproval = true
        let bridge = WebWorkspaceController(model: model, loadsResources: false)
        try await bridge.handle("changeCalendarEvent", ["operation": "create", "fields": [
            "title": "Fictional study block", "date": "2026-11-12", "allDay": true, "timeZone": "UTC", "calendarID": "demo"
        ]])
        XCTAssertEqual(model.calendarActions.proposals.count, 1, "The pending review is left as it was")
        XCTAssertFalse(model.calendarActions.proposals[0].isFinished)
    }
    func testInterruptedDirectWriteIsConfirmedWithoutRetrying() async throws {
        let model = fixture(); await model.loadCalendars()
        let saved = EventDraft(title: "Fictional interrupted lab", startDate: Date(timeIntervalSince1970: 1_800_000_000), endDate: Date(timeIntervalSince1970: 1_800_003_600), isAllDay: false, timeZoneIdentifier: "UTC", location: nil, url: nil, notes: nil, sourceText: "Direct user entry", confidence: 1, ambiguities: [])
        _ = try await model.calendarService.save(saved, to: .resolve(identifier: "demo"))
        var landed = CalendarActionProposal(draft: saved); landed.state = .saving; landed.attemptedDestinationID = "demo"; landed.attemptedCalendarName = "Demo"
        var lost = CalendarActionProposal(draft: EventDraft(title: "Fictional lost entry", startDate: Date(timeIntervalSince1970: 1_800_100_000), endDate: Date(timeIntervalSince1970: 1_800_103_600), isAllDay: false, timeZoneIdentifier: "UTC", location: nil, url: nil, notes: nil, sourceText: "Direct user entry", confidence: 1, ambiguities: []))
        lost.state = .saving; lost.attemptedDestinationID = "demo"; lost.attemptedCalendarName = "Demo"
        let journal = model.memoryStore.locationURL.appendingPathComponent("calendar-direct-journal.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([landed, lost]).write(to: journal)
        await model.recoverDirectCalendarWrites()
        let notice = try XCTUnwrap(model.directWriteNotice)
        XCTAssertTrue(notice.contains("Fictional lost entry") && notice.contains("couldn’t be confirmed"))
        let events = try await model.calendarService.searchEvents(query: nil, start: .distantPast, end: .distantFuture, in: .resolve(identifier: "demo"))
        XCTAssertEqual(events.count, 1, "Recovery never replays a write")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testNativeSelectedContextBindsOnlyToItsConversationAndCapture() throws {
        let model = fixture(); let record = try model.memoryStore.recordCommand("Fictional selected source")
        let capture = UUID(); model.currentMemoryRecordID = record.id; model.currentCaptureSessionID = capture
        let snapshot = CalendarEventSnapshot(eventIdentifier: "fixture", title: "Fictional source", start: .now, end: .now.addingTimeInterval(3600), isAllDay: false, calendarName: "Fixture", isRecurring: false)
        model.selectedEventContext = CalshotSelectedEventContext(ownerID: model.account.userID, storeURL: model.taskStore.url, snapshot: snapshot, destinationID: "source", fingerprint: try CalshotModel.taskSourceFingerprint(snapshot), recordID: record.id, captureID: capture)
        let runID = UUID(); model.bindSelectedEventContext(runID: runID); model.currentCaptureSessionID = runID
        XCTAssertEqual(model.selectedEventContext?.runID, runID)
        model.currentCaptureSessionID = UUID(); XCTAssertNil(model.selectedEventContext)
    }
    func testVoiceBridgeRejectsStaleControlsAndNotchPreferences() async throws {
        let model = fixture(); model.workspaceSelection = .settings
        let bridge = WebWorkspaceController(model: model)
        do { try await bridge.handle("stopVoice", ["token": "stale"]); XCTFail("Stale voice control accepted") } catch {}
        let notch = WebWorkspaceController(model: model, isNotch: true)
        do { try await notch.handle("voiceSettings", ["token": model.voiceSession.token, "model": "fictional", "voice": "marin", "cap": 10.0]); XCTFail("Notch settings accepted") } catch {}
        let snapshot = WebWorkspaceState.make(model, imageURL: nil, notice: nil, accounts: [], googleReady: false)
        XCTAssertEqual(snapshot.objectValue?["voice"]?.objectValue?["state"]?.stringValue, "idle")
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
    func testNotchGeometryMatchesCameraHousingOnEachMacBookSize() {
        // (display, safe-area top, left and right areas beside the housing)
        let models: [(NSRect, CGFloat, CGFloat, CGFloat)] = [
            (NSRect(x: 0, y: 0, width: 1470, height: 956), 32, 640, 640),   // 13" / 15" Air
            (NSRect(x: 0, y: 0, width: 1512, height: 982), 32, 662, 662),   // 14" Pro
            (NSRect(x: 0, y: 0, width: 1728, height: 1117), 38, 764, 764),  // 16" Pro
            (NSRect(x: 0, y: 0, width: 1800, height: 1169), 32, 810, 810),  // 14" Pro, More Space
        ]
        for (frame, top, left, right) in models {
            let visible = NSRect(x: 0, y: 70, width: frame.width, height: frame.height - 70 - top)
            let g = NotchGeometry(frame: frame, visibleFrame: visible, safeAreaTop: top, leftAuxiliaryWidth: left, rightAuxiliaryWidth: right, statusBarThickness: 24)
            XCTAssertTrue(g.hasCameraHousing)
            XCTAssertEqual(g.barHeight, top)
            XCTAssertEqual(g.closedSize, NSSize(width: frame.width - left - right, height: top))
            let closed = g.frame(for: g.closedSize)
            XCTAssertEqual(closed.minX, left)
            XCTAssertEqual(closed.maxY, frame.maxY)
            XCTAssertGreaterThan(g.expandedWidth(detail: false), g.closedWidth)
        }
    }
    func testNotchGeometryDrawsMenuBarNotchWithoutCameraHousing() {
        // External 1080p display: 30pt menu bar and a 53pt Dock.
        let external = NotchGeometry(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: NSRect(x: 0, y: 53, width: 1920, height: 997), safeAreaTop: 0, leftAuxiliaryWidth: nil, rightAuxiliaryWidth: nil, statusBarThickness: 22)
        XCTAssertFalse(external.hasCameraHousing)
        XCTAssertEqual(external.barHeight, 30)
        XCTAssertEqual(external.frame(for: external.closedSize), NSRect(x: 868, y: 1050, width: 184, height: 30))
        XCTAssertEqual(external.expandedHeight(detail: true, detailHeight: 490), 520)
        // MacBook without a notch, with the menu bar hidden automatically.
        let hidden = NotchGeometry(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900), safeAreaTop: 0, leftAuxiliaryWidth: nil, rightAuxiliaryWidth: nil, statusBarThickness: 22)
        XCTAssertEqual(hidden.barHeight, 24)
        // A secondary display keeps the panel on its own frame.
        let secondary = NotchGeometry(frame: NSRect(x: 1920, y: 200, width: 1280, height: 800), visibleFrame: NSRect(x: 1920, y: 200, width: 1280, height: 775), safeAreaTop: 0, leftAuxiliaryWidth: nil, rightAuxiliaryWidth: nil, statusBarThickness: 22)
        XCTAssertEqual(secondary.frame(for: secondary.closedSize), NSRect(x: 2468, y: 975, width: 184, height: 25))
    }
    func testNotchGeometryFitsSmallAndShortDisplays() {
        let g = NotchGeometry(frame: NSRect(x: 0, y: 0, width: 360, height: 600), visibleFrame: NSRect(x: 0, y: 300, width: 360, height: 276), safeAreaTop: 0, leftAuxiliaryWidth: nil, rightAuxiliaryWidth: nil, statusBarThickness: 22)
        XCTAssertEqual(g.closedWidth, 108)
        XCTAssertEqual(g.notificationSize.width, 328)
        XCTAssertEqual(g.expandedWidth(detail: true), 328)
        // Detail stops above the Dock instead of running off the display.
        XCTAssertEqual(g.expandedHeight(detail: true, detailHeight: 490), 24 + 264)
        let open = g.frame(for: NSSize(width: g.expandedWidth(detail: true), height: 288))
        XCTAssertGreaterThanOrEqual(open.minX, 0)
        XCTAssertLessThanOrEqual(open.maxX, 360)
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
    func testNotchSettingIsSettingsOnlyAndRoutesTasksToTheWorkspaceWhenOff() async throws {
        let model = fixture(); let bridge = WebWorkspaceController(model: model, loadsResources: false)
        model.notchEnabled = true
        let notch = WebWorkspaceController(model: model, loadsResources: false, isNotch: true)
        do { try await notch.handle("notchEnabled", ["enabled": false]); XCTFail("The notch turned itself off") } catch {}
        do { try await bridge.handle("notchEnabled", ["enabled": "no"]); XCTFail("Accepted a non-Boolean value") } catch {}
        XCTAssertTrue(model.notchEnabled)
        model.taskUsesNotch = true
        try await bridge.handle("notchEnabled", ["enabled": false])
        XCTAssertFalse(model.notchEnabled)
        XCTAssertFalse(model.taskUsesNotch)
        // Shortcut and capture paths ask for the notch; while it is off they cannot get it.
        model.taskUsesNotch = true
        model.showNotchLauncher()
        XCTAssertFalse(model.taskUsesNotch)
        XCTAssertNil(model.notchLauncherController)
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

private actor SelectedTaskLinkFixture: CalendarDestinationService {
    var writes = 0
    var source = CalendarEventSnapshot(eventIdentifier: "native-source", title: "Fictional workshop", start: Date(timeIntervalSince1970: 1794297600), end: Date(timeIntervalSince1970: 1794301200), isAllDay: false, timeZone: "UTC", calendarName: "Personal read-only fixture", isRecurring: false)
    func availableDestinations() async throws -> [CalendarDestinationInfo] { [.init(id: "selected-source", title: "Personal read-only fixture", provider: .apple, isReadOnly: true)] }
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] { [source] }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? { identifier == source.eventIdentifier && destination == .resolve(identifier: "selected-source") ? source : nil }
    func changeSource() { source.title = "Changed fictional workshop" }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] { [] }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String { writes += 1; throw CalendarDestinationError.calendarReadOnly }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String { writes += 1; throw CalendarDestinationError.calendarReadOnly }
    func delete(identifier: String, in destination: CalendarDestination) async throws { writes += 1; throw CalendarDestinationError.calendarReadOnly }
}

private actor DirectCalendarFixture: CalendarDestinationService {
    private var writes = 0
    private var source = CalendarEventSnapshot(eventIdentifier: "native-source", title: "Fictional workshop", start: Date(timeIntervalSince1970: 1794297600), end: Date(timeIntervalSince1970: 1794301200), isAllDay: false, timeZone: "UTC", calendarName: "Personal writable fixture", isRecurring: false)
    func availableDestinations() async throws -> [CalendarDestinationInfo] {
        [.init(id: "direct-source", title: "Personal writable fixture", provider: .apple, isReadOnly: false, sourceName: "Fixture", timeZone: "UTC")]
    }
    func searchEvents(query: String?, start: Date, end: Date, in destination: CalendarDestination) async throws -> [CalendarEventSnapshot] {
        guard destination == .resolve(identifier: "direct-source"), source.start < end, source.end > start else { return [] }
        return [source]
    }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? {
        destination == .resolve(identifier: "direct-source") && identifier == source.eventIdentifier ? source : nil
    }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] { [] }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String {
        writes += 1
        source = CalendarEventSnapshot(eventIdentifier: draft.id.uuidString, title: draft.title, start: draft.startDate!, end: draft.endDate!, isAllDay: draft.isAllDay, timeZone: draft.timeZoneIdentifier, location: draft.location, calendarName: "Personal writable fixture", url: draft.url, notes: draft.notes, isRecurring: false)
        return source.eventIdentifier
    }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String {
        guard identifier == source.eventIdentifier else { throw CalendarDestinationError.calendarUnavailable }
        writes += 1
        source = CalendarEventSnapshot(eventIdentifier: identifier, title: draft.title, start: draft.startDate!, end: draft.endDate!, isAllDay: draft.isAllDay, timeZone: draft.timeZoneIdentifier, location: draft.location, calendarName: "Personal writable fixture", url: draft.url, notes: draft.notes, isRecurring: false)
        return identifier
    }
    func delete(identifier: String, in destination: CalendarDestination) async throws {
        guard identifier == source.eventIdentifier else { throw CalendarDestinationError.calendarUnavailable }
        writes += 1
        source.end = source.start
    }
    func changeSourceTitle() { source.title = "Changed fictional workshop" }
    func markRecurring() {
        source.isRecurring = true
        source.originalOccurrenceStart = source.start
    }
    func writeCount() -> Int { writes }
}

// MARK: - Task-only review and saved task permissions (isolated, fictional fixtures, no provider writes)

private final class ReadOnlySourceFixture: CalendarDestinationService, @unchecked Sendable {
    private(set) var writes = 0
    var snapshot = CalendarEventSnapshot(eventIdentifier: "fictional-event", title: "Fictional reading day", start: Date(timeIntervalSince1970: 1_800_057_600), end: Date(timeIntervalSince1970: 1_800_144_000), isAllDay: true, timeZone: "UTC", location: nil, calendarName: "Fictional read-only calendar", url: nil, notes: nil, isRecurring: false)
    func availableDestinations() async throws -> [CalendarDestinationInfo] { [.init(id: "fictional-readonly", title: "Fictional read-only calendar", provider: .other, isReadOnly: true, sourceName: nil, timeZone: "UTC")] }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? { await Task.yield(); return identifier == snapshot.eventIdentifier ? snapshot : nil }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] { [] }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String { writes += 1; throw CalendarDestinationError.calendarReadOnly }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String { writes += 1; throw CalendarDestinationError.calendarReadOnly }
    func delete(identifier: String, in destination: CalendarDestination) async throws { writes += 1; throw CalendarDestinationError.calendarReadOnly }
}

@MainActor
final class AgentTaskReviewIntegrationTests: XCTestCase {
    private func fixture(_ service: any CalendarDestinationService = CalendarDemoService()) -> CalshotModel {
        CalshotModel(calendarService: service, memoryStore: MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("task-review-fixture-" + UUID().uuidString)), loadsAIConnection: false)
    }
    /// A running agent run, as the native executor would see it while a tool is awaited.
    private func startRun(_ model: CalshotModel) -> UUID {
        let run = UUID(); model.activeAgentRunID = run; model.agentIsRunning = true; model.agentTypedRunID = run; return run
    }
    private func addTasks(_ model: CalshotModel, _ count: Int) throws -> [CalshotTask] {
        let tasks = (0..<count).map { CalshotTask(title: "Fictional task \($0)", rank: $0) }
        try model.persistTasks(.init(items: tasks)); return tasks
    }
    private func patch(_ task: CalshotTask, _ fields: [String: JSONValue]) -> AgentPreparedTaskMutation.Patch {
        .init(operationID: UUID(), taskID: task.id, expectedVersion: task.version, fields: fields)
    }
    private func request(_ patches: [AgentPreparedTaskMutation.Patch]) -> AgentPreparedTaskMutation {
        AgentPreparedTaskMutation(id: UUID(), change: .patches(patches))
    }
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "Timed out waiting for the native state")
    }
    private func grant(_ model: CalshotModel, _ families: [String: Bool], revision: UInt64 = 0) async throws {
        try await model.saveAgentTaskPermissions(revision: revision, families: families, days: 30)
    }
    private func status(_ value: JSONValue) -> String? { value.objectValue?["status"]?.stringValue }

    func testDefaultReviewIsOneTaskOnlyApprovalAndSavesOnceWithoutCalendarState() async throws {
        let model = fixture(), task = try addTasks(model, 1)[0], run = startRun(model)
        let call = Task { try await model.authorizeAgentTaskChange(request([patch(task, ["title": .string("Renamed after review")])]), runID: run) }
        try await waitFor { model.agentTaskReview != nil }
        let review = try XCTUnwrap(model.agentTaskReview)
        XCTAssertEqual(review.phase, .waiting); XCTAssertEqual(review.rows.count, 1)
        XCTAssertEqual(review.rows[0].changes.first?.before, "Fictional task 0"); XCTAssertEqual(review.rows[0].changes.first?.after, "Renamed after review")
        XCTAssertFalse(model.agentIsWaitingForApproval, "A task review must not borrow calendar approval state")
        XCTAssertEqual(model.taskDocument.items[0].title, "Fictional task 0", "Nothing may save before approval")
        XCTAssertThrowsError(try model.approveAgentTaskReview(id: review.id, token: "wrong-token", digest: review.digest))
        XCTAssertThrowsError(try model.approveAgentTaskReview(id: review.id, token: review.token, digest: "wrong-digest"))
        XCTAssertNotNil(model.agentTaskReview, "A rejected click leaves the pending review usable")
        try model.approveAgentTaskReview(id: review.id, token: review.token, digest: review.digest)
        XCTAssertThrowsError(try model.approveAgentTaskReview(id: review.id, token: review.token, digest: review.digest), "Double click")
        let result = try await call.value
        XCTAssertEqual(status(result), "saved"); XCTAssertEqual(result.objectValue?["calendarWrites"], .number(0))
        XCTAssertEqual(result.objectValue?["authorization"]?.stringValue, "taskReview")
        XCTAssertEqual(model.taskDocument.items[0].title, "Renamed after review"); XCTAssertNil(model.agentTaskReview)
        XCTAssertEqual(model.agentTaskOutcome?.status, "saved")
        XCTAssertEqual(try model.taskStore.load().operations?.count, 1)
    }

    func testSavedExplicitGrantExecutesImmediatelyAndRevocationRestoresReview() async throws {
        let model = fixture(), task = try addTasks(model, 1)[0], run = startRun(model)
        try await grant(model, ["edit": true])
        let immediate = try await model.authorizeAgentTaskChange(request([patch(task, ["notes": .string("Saved under a grant")])]), runID: run)
        XCTAssertEqual(status(immediate), "saved"); XCTAssertEqual(immediate.objectValue?["authorization"]?.stringValue, "savedPermission")
        XCTAssertNil(model.agentTaskReview); XCTAssertEqual(model.taskDocument.items[0].notes, "Saved under a grant")
        // A grant for one family does not cover another.
        let current = model.taskDocument.items[0]
        let call = Task { try await model.authorizeAgentTaskChange(request([patch(current, ["completed": .bool(true)])]), runID: run) }
        try await waitFor { model.agentTaskReview != nil }
        let review = try XCTUnwrap(model.agentTaskReview)
        try model.declineAgentTaskReview(id: review.id, token: review.token)
        let declined = try await call.value
        XCTAssertEqual(status(declined), "declined"); XCTAssertFalse(model.taskDocument.items[0].completed)
        // Revocation: the next matching request must ask again.
        try await grant(model, [:], revision: try XCTUnwrap(model.agentPermissionPolicy).revision)
        let latest = model.taskDocument.items[0]
        let asked = Task { try await model.authorizeAgentTaskChange(request([patch(latest, ["notes": .string("After revocation")])]), runID: run) }
        try await waitFor { model.agentTaskReview != nil }
        XCTAssertEqual(model.taskDocument.items[0].notes, "Saved under a grant")
        model.cancelAgentTaskReview()
        let cancelledAsk = try await asked.value
        XCTAssertEqual(status(cancelledAsk), "cancelled")
    }

    func testStopResumesTheAwaitedHookOnceAndInvalidatesTheOldButtons() async throws {
        let model = fixture(), task = try addTasks(model, 1)[0], run = startRun(model)
        let call = Task { try await model.authorizeAgentTaskChange(request([patch(task, ["archived": .bool(true)])]), runID: run) }
        try await waitFor { model.agentTaskReview != nil }
        let review = try XCTUnwrap(model.agentTaskReview)
        model.stopAgent()
        XCTAssertNil(model.agentTaskReview); XCTAssertNil(model.agentTaskReviewContinuation)
        let stopped = try await call.value
        XCTAssertEqual(status(stopped), "cancelled")
        XCTAssertThrowsError(try model.approveAgentTaskReview(id: review.id, token: review.token, digest: review.digest))
        XCTAssertFalse(model.taskDocument.items[0].deleted)
    }

    func testSignOutAndAccountChangeCancelThePendingReviewAndCloseTheStore() async throws {
        let model = fixture(), task = try addTasks(model, 1)[0], run = startRun(model)
        try await grant(model, ["complete": true])
        XCTAssertNotNil(model.agentPermissionStore)
        let call = Task { try await model.authorizeAgentTaskChange(request([patch(task, ["title": .string("Needs review")])]), runID: run) }
        try await waitFor { model.agentTaskReview != nil }
        model.teardownAgentPermissions(reason: "The account changed.")
        let torn = try await call.value
        XCTAssertEqual(status(torn), "cancelled")
        XCTAssertNil(model.agentPermissionStore); XCTAssertNil(model.agentPermissionPolicy); XCTAssertNil(model.agentTaskReview)
        XCTAssertEqual(model.taskDocument.items[0].title, "Fictional task 0")
        // A fresh store for the same canonical account reads the saved device-local grants after the old one closed.
        let reopened = try await model.openAgentPermissionStore()
        let policy = try await reopened.snapshot()
        XCTAssertEqual(policy.grants.map(\.action), [.taskComplete]); XCTAssertEqual(policy.revision, 1)
    }

    func testStaleRunAtApprovalIsRejectedAndNothingSaves() async throws {
        let model = fixture(), task = try addTasks(model, 1)[0], run = startRun(model)
        let call = Task { try await model.authorizeAgentTaskChange(request([patch(task, ["title": .string("Stale")])]), runID: run) }
        try await waitFor { model.agentTaskReview != nil }
        let review = try XCTUnwrap(model.agentTaskReview)
        model.activeAgentRunID = UUID() // another conversation took over
        XCTAssertThrowsError(try model.approveAgentTaskReview(id: review.id, token: review.token, digest: review.digest))
        let stale = try await call.value
        XCTAssertEqual(status(stale), "cancelled")
        XCTAssertEqual(model.taskDocument.items[0].title, "Fictional task 0")
    }

    func testQuotaOverflowReviewIsApprovableAndRowsReportPartialFailure() async throws {
        let model = fixture(), tasks = try addTasks(model, 21), firstRun = startRun(model)
        try await grant(model, ["complete": true])
        let run = firstRun
        let tooMany = Task { try await model.authorizeAgentTaskChange(request(tasks.map { patch($0, ["completed": .bool(true)]) }), runID: run) }
        try await waitFor { model.agentTaskReview != nil }
        XCTAssertEqual(model.agentTaskReview?.rows.count, 21)
        // The saved quota bounds unattended execution only; the explicit review can approve the exact larger effect.
        let large = try XCTUnwrap(model.agentTaskReview)
        XCTAssertTrue(large.reason.lowercased().contains("limit"))
        XCTAssertTrue(model.taskDocument.items.allSatisfy { !$0.completed }, "Nothing may save before approval")
        try model.approveAgentTaskReview(id: large.id, token: large.token, digest: large.digest)
        let largeResult = try await tooMany.value
        XCTAssertEqual(status(largeResult), "saved"); XCTAssertEqual(largeResult.objectValue?["rows"]?.arrayValue?.count, 21)
        XCTAssertTrue(model.taskDocument.items.allSatisfy { $0.completed })
        for index in model.taskDocument.items.indices { model.taskDocument.items[index].completed = false } // reset the fixture only
        try model.persistTasks(model.taskDocument)
        // A row-level failure is reported without claiming all-or-none behaviour.
        let run2 = startRun(model) // a new run: the earlier run's reviewed effect already used its per-run quota
        var dated = CalshotTask(title: "Dated fictional deadline", dueDate: "2026-11-10", rank: 30, calendarID: "demo", calendarName: "Demo")
        dated.resolveCalendarIntent()
        var doc = model.taskDocument; doc.items.append(dated); try model.persistTasks(doc)
        model.calendarActions.replace(with: [try dated.deadline(owner: nil)]) // unfinished deadline review blocks edits to that task
        let current = model.taskDocument.items
        let rows = [patch(current[0], ["completed": .bool(true)]), patch(current.first { $0.id == dated.id }!, ["completed": .bool(true)])]
        let result = try await model.authorizeAgentTaskChange(request(rows), runID: run2)
        XCTAssertEqual(status(result), "partial")
        let outcomes = try XCTUnwrap(result.objectValue?["rows"]?.arrayValue).compactMap { $0.objectValue?["outcome"]?.stringValue }
        XCTAssertEqual(outcomes, ["saved", "failed"]); XCTAssertNotNil(result.objectValue?["note"])
        XCTAssertTrue(model.taskDocument.items.first { $0.id == current[0].id }!.completed)
        XCTAssertFalse(model.taskDocument.items.first { $0.id == dated.id }!.completed)
    }

    func testLinkingTheSelectedEventUsesTheKernelWithZeroProviderWritesAndIsIdempotent() async throws {
        let service = ReadOnlySourceFixture(), model = fixture(service); await model.loadCalendars()
        let record = try model.memoryStore.recordCommand("Add this event to Tasks"); model.currentMemoryRecordID = record.id
        let capture = UUID(); model.currentCaptureSessionID = capture
        model.selectedEventContext = CalshotSelectedEventContext(ownerID: model.account.userID, storeURL: model.taskStore.url, snapshot: service.snapshot, destinationID: "fictional-readonly", fingerprint: try CalshotModel.taskSourceFingerprint(service.snapshot), recordID: record.id, captureID: capture)
        let run = UUID(); model.bindSelectedEventContext(runID: run); model.currentCaptureSessionID = run
        model.activeAgentRunID = run; model.agentIsRunning = true; model.agentTypedRunID = run
        let reference = try XCTUnwrap(model.selectedEventContext?.token)
        try await grant(model, ["link": true])
        let first = try await model.authorizeAgentTaskChange(AgentPreparedTaskMutation(id: UUID(), change: .linkSelectedEvent(contextReference: reference)), runID: run)
        XCTAssertEqual(status(first), "saved"); XCTAssertEqual(model.taskDocument.items.count, 1)
        XCTAssertEqual(model.taskDocument.items[0].resolvedCalendarIntent, .existing); XCTAssertNil(model.taskDocument.items[0].receipt)
        let again = try await model.authorizeAgentTaskChange(AgentPreparedTaskMutation(id: UUID(), change: .linkSelectedEvent(contextReference: reference)), runID: run)
        XCTAssertEqual(status(again), "saved")
        XCTAssertEqual(again.objectValue?["rows"]?.arrayValue?.first?.objectValue?["outcome"]?.stringValue, "alreadyLinked")
        XCTAssertEqual(model.taskDocument.items.count, 1); XCTAssertEqual(service.writes, 0)
        XCTAssertTrue(model.calendarActions.proposals.isEmpty)
        // A changed source cannot be linked through a stale selection.
        service.snapshot.title = "Moved fictional day"
        let stale = try await model.authorizeAgentTaskChange(AgentPreparedTaskMutation(id: UUID(), change: .linkSelectedEvent(contextReference: reference)), runID: run)
        XCTAssertEqual(status(stale), "failed"); XCTAssertEqual(model.taskDocument.items.count, 1)
    }

    func testTaskGrantsNeverAuthorizeCalendarWritesOrDeadlines() async throws {
        let model = fixture(); try await grant(model, ["create": true, "link": true, "edit": true, "complete": true, "archive": true])
        let store = try await model.openAgentPermissionStore(), policy = try await store.snapshot()
        XCTAssertTrue(policy.grants.allSatisfy { $0.action.isTask && $0.calendarIDs.isEmpty && !$0.backgroundEnabled })
        let operation = AgentPermissionOperation(operationID: UUID(), runID: UUID(), ownerID: model.agentPermissionOwnerID, deviceID: CalshotModel.syncDeviceID, action: .calendarCreate, resourceIDs: ["new-event"], expectedVersions: [:], calendarIDs: ["demo"], fields: ["title"], effectDigest: String(repeating: "a", count: 64), hasGuestEffects: false, affectsSeries: false, hasSharingEffects: false)
        let resources = AgentPermissionResources(ownerID: model.agentPermissionOwnerID, deviceID: CalshotModel.syncDeviceID, versions: [:], writableCalendarIDs: ["demo"], supportedActions: [.calendarCreate], cancelled: false)
        let decision = try await store.reserve(operation, context: .userRequested(), resources: resources)
        guard case .requireReview = decision else { return XCTFail("A task grant authorized a calendar write: \(decision)") }
        // A task-only import under a grant still sends a dated new deadline to the existing calendar review.
        await model.loadCalendars()
        let record = try model.memoryStore.recordCommand("Add my deadline"); model.currentMemoryRecordID = record.id
        let run = startRun(model)
        _ = try model.createAgentTasks(["tasks": .array([.object(["title": .string("Fictional dated deadline"), "dueDate": .string("2026-11-10"), "yearResolved": .bool(true), "sourceText": .string("Fictional deadline")])]), "calendarIdentifier": .string("demo")])
        let committed = try await model.commitAgentTaskOnlyImport(runID: run)
        XCTAssertNil(committed, "A new calendar deadline always keeps its own review"); XCTAssertTrue(model.taskDocument.items.isEmpty)
    }

    func testTaskOnlyCreateUsesTheGrantElseKeepsTheExistingImportReview() async throws {
        let model = fixture(); let record = try model.memoryStore.recordCommand("Add tasks"); model.currentMemoryRecordID = record.id
        let run = startRun(model)
        let rows: JSONValue = .array([.object(["title": .string("Fictional task-only item"), "sourceText": .string("Fictional line"), "calendarIntent": .string("none")])])
        _ = try model.createAgentTasks(["tasks": rows])
        let withoutGrant = try await model.commitAgentTaskOnlyImport(runID: run)
        XCTAssertNil(withoutGrant, "No grant: the existing in-conversation import review remains")
        XCTAssertTrue(model.taskDocument.items.isEmpty); XCTAssertNotNil(model.taskImport)
        try await grant(model, ["create": true])
        let saved = try await model.commitAgentTaskOnlyImport(runID: run)
        XCTAssertEqual(saved?.arrayValue?.count, 1); XCTAssertEqual(model.taskDocument.items.map(\.title), ["Fictional task-only item"])
        XCTAssertNil(model.taskImport); XCTAssertEqual(model.agentTaskOutcome?.status, "saved")
        XCTAssertEqual(try model.taskStore.load().items.count, 1)
    }

    func testScreenshotImportCannotUseTheCreateGrantWithoutATypedRequest() async throws {
        let model = fixture(); model.currentMemoryRecordID = try model.memoryStore.recordCommand("Import fictional screenshot").id
        let run = startRun(model); model.agentTypedRunID = nil
        try await grant(model, ["create": true])
        let rows: JSONValue = .array([.object(["title": .string("Fictional screenshot item"), "sourceText": .string("Fictional capture"), "calendarIntent": .string("none")])])
        _ = try model.createAgentTasks(["tasks": rows])
        let blocked = try await model.commitAgentTaskOnlyImport(runID: run)
        XCTAssertNil(blocked); XCTAssertNotNil(model.taskImport); XCTAssertTrue(model.taskDocument.items.isEmpty)
        let store = try await model.openAgentPermissionStore()
        let records = try await store.operationRecords()
        XCTAssertTrue(records.isEmpty)
        model.agentTypedRunID = run
        let saved = try await model.commitAgentTaskOnlyImport(runID: run)
        XCTAssertEqual(saved?.arrayValue?.count, 1)
    }

    func testPermissionStoreFailureBlocksMutationAndNeverOverwritesTheSavedFile() async throws {
        let model = fixture(), task = try addTasks(model, 1)[0], run = startRun(model)
        let directory = model.memoryStore.locationURL.appendingPathComponent("AgentPermissions", isDirectory: true)
            .appendingPathComponent(model.agentPermissionOwnerID, isDirectory: true).appendingPathComponent(CalshotModel.syncDeviceID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("fictional corrupt permissions".utf8); let file = directory.appendingPathComponent("agent-permissions.json")
        try corrupt.write(to: file)
        let result = try await model.authorizeAgentTaskChange(request([patch(task, ["title": .string("Must not save")])]), runID: run)
        XCTAssertEqual(status(result), "unavailable"); XCTAssertNil(model.agentTaskReview)
        XCTAssertEqual(model.taskDocument.items[0].title, "Fictional task 0")
        XCTAssertNotNil(model.agentPermissionError); XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertEqual(model.agentPermissionSnapshot().objectValue?["loaded"], .bool(false))
    }

    func testSettingsRevisionIsCompareAndSwapAndTheSnapshotOffersNoBackgroundControl() async throws {
        let model = fixture()
        try await grant(model, ["edit": true, "link": true])
        do { try await grant(model, [:], revision: 0); XCTFail("A stale Settings snapshot restored old permissions") } catch {}
        let snapshot = try XCTUnwrap(model.agentPermissionSnapshot().objectValue)
        let ids = snapshot["families"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue }
        XCTAssertEqual(ids, ["create", "link", "edit", "complete", "archive"])
        XCTAssertFalse(JSONValue.object(snapshot).jsonString().lowercased().contains("background"))
        XCTAssertEqual(snapshot["revision"], .number(1))
    }

    func testWorkspaceStateCarriesTheReviewWithoutCalendarWaitingAndHidesItSignedOut() async throws {
        let model = fixture(), tasks = try addTasks(model, 12), run = startRun(model)
        let call = Task { try await model.authorizeAgentTaskChange(request(tasks.map { patch($0, ["completed": .bool(true)]) }), runID: run) }
        try await waitFor { model.agentTaskReview != nil }
        let state = try XCTUnwrap(WebWorkspaceState.make(model, imageURL: nil, notice: nil, accounts: [], googleReady: false).objectValue)
        XCTAssertEqual(state["waitingApproval"], .bool(false))
        let review = try XCTUnwrap(state["taskReview"]?.objectValue)
        XCTAssertEqual(review["rows"]?.arrayValue?.count, 12); XCTAssertEqual(review["calendarWrites"], .number(0))
        XCTAssertNil(state["taskOutcome"])
        model.cancelAgentTaskReview(); _ = try await call.value
        let after = WebWorkspaceState.make(model, imageURL: nil, notice: nil, accounts: [], googleReady: false).objectValue
        XCTAssertEqual(after?["taskOutcome"]?.objectValue?["status"], .string("cancelled"))
    }

    func testReviewedRequestBeyondTheHourlyWindowSavesWithReceiptsThenSavedGrantsStayBlocked() async throws {
        let model = fixture(), tasks = try addTasks(model, 100), run = startRun(model)
        try await grant(model, ["complete": true])
        let call = Task { try await model.authorizeAgentTaskChange(request(tasks.map { patch($0, ["completed": .bool(true)]) }), runID: run) }
        try await waitFor { model.agentTaskReview != nil }
        let review = try XCTUnwrap(model.agentTaskReview)
        XCTAssertEqual(review.rows.count, 100); XCTAssertTrue(review.reason.lowercased().contains("limit"))
        try model.approveAgentTaskReview(id: review.id, token: review.token, digest: review.digest)
        let result = try await call.value
        XCTAssertEqual(status(result), "saved"); XCTAssertEqual(result.objectValue?["rows"]?.arrayValue?.count, 100)
        XCTAssertTrue(model.taskDocument.items.allSatisfy(\.completed)); XCTAssertEqual(try model.taskStore.load().operations?.count, 100)
        // The reviewed effect still counts: all 100 of the hourly window are used, so a saved grant must ask again.
        var doc = model.taskDocument; doc.items.append(CalshotTask(title: "One more fictional task", rank: 200)); try model.persistTasks(doc)
        let fresh = try XCTUnwrap(model.taskDocument.items.last), nextRun = startRun(model)
        let next = Task { try await model.authorizeAgentTaskChange(request([patch(fresh, ["completed": .bool(true)])]), runID: nextRun) }
        try await waitFor { model.agentTaskReview != nil }
        XCTAssertTrue(try XCTUnwrap(model.agentTaskReview).reason.lowercased().contains("limit"))
        model.cancelAgentTaskReview(); _ = try await next.value
        XCTAssertFalse(model.taskDocument.items.last!.completed)
    }

    func testScreenshotStartedRunsAlwaysReviewTaskChangesButTypedRunsUseSavedGrants() async throws {
        let model = fixture(), task = try addTasks(model, 1)[0]
        let run = UUID(); model.activeAgentRunID = run; model.agentIsRunning = true // never marked as typed: screenshot-started
        try await grant(model, ["edit": true, "complete": true, "archive": true])
        let call = Task { try await model.authorizeAgentTaskChange(request([patch(task, ["title": .string("From a screenshot")])]), runID: run) }
        try await waitFor { model.agentTaskReview != nil }
        XCTAssertTrue(try XCTUnwrap(model.agentTaskReview).reason.contains("screenshot"))
        XCTAssertEqual(model.taskDocument.items[0].title, "Fictional task 0")
        model.cancelAgentTaskReview(); let cancelled = try await call.value
        XCTAssertEqual(status(cancelled), "cancelled")
        // The user typing the request is what lets a saved grant apply.
        model.agentTypedRunID = run
        let typed = try await model.authorizeAgentTaskChange(request([patch(task, ["title": .string("Typed request")])]), runID: run)
        XCTAssertEqual(typed.objectValue?["authorization"]?.stringValue, "savedPermission")
        XCTAssertEqual(model.taskDocument.items[0].title, "Typed request")
    }

    func testVoiceRunAlwaysReviewsEvenWithSavedTaskGrant() async throws {
        let model = fixture(), task = try addTasks(model, 1)[0], run = UUID()
        model.activeAgentRunID = run; model.voiceRunID = run; model.agentIsRunning = false; model.agentTypedRunID = nil
        try await grant(model, ["edit": true])
        let call = Task { try await model.authorizeAgentTaskChange(request([patch(task, ["title": .string("Voice request")])]), runID: run) }
        try await waitFor { model.agentTaskReview != nil }
        XCTAssertTrue(try XCTUnwrap(model.agentTaskReview).reason.contains("Voice"))
        XCTAssertEqual(model.taskDocument.items[0].title, "Fictional task 0")
        model.cancelAgentTaskReview(); let result = try await call.value
        XCTAssertEqual(status(result), "cancelled")
    }

    func testLedgerReconciliationWaitsForTasksThenSettlesFromTheMatchingReceipt() async throws {
        let model = fixture(), task = try addTasks(model, 1)[0], run = startRun(model)
        let plan = try model.agentTaskPlan(request([patch(task, ["title": .string("Recovered title")])]), runID: run)
        let operation = plan.operations[0], store = try await model.openAgentPermissionStore()
        let resources = await model.agentTaskResources(plan, runID: run)
        guard case .allow(let envelope) = try await store.reserve(operation, context: .directTaskSubmission(operation), resources: resources) else { return XCTFail("Not reserved") }
        try await store.beginDispatch(envelope, resources: resources)
        _ = try model.mutateTask(taskID: task.id, expectedVersion: task.version, patch: ["title": .string("Recovered title")], context: try model.taskContext(origin: .agent(runID: run)), operationID: operation.operationID)
        // Simulated restart: the dispatched row survives, and tasks are not loaded yet when the store reopens.
        model.teardownAgentPermissions(reason: "Simulated restart.")
        model.taskDataReady = false
        let reopened = try await model.openAgentPermissionStore()
        XCTAssertTrue(model.agentPermissionNeedsReconcile)
        var record = try await reopened.operationRecord(operation.operationID)
        XCTAssertEqual(record?.status, "dispatched")
        model.loadTasks()
        for _ in 0..<200 where record?.status != "succeeded" { try await Task.sleep(nanoseconds: 5_000_000); record = try await reopened.operationRecord(operation.operationID) }
        XCTAssertEqual(record?.status, "succeeded"); XCTAssertFalse(model.agentPermissionNeedsReconcile)
    }

    func testSavedPeriodIsKeptUnlessTheUserExplicitlyRenews() async throws {
        let model = fixture()
        func expiry(_ action: AgentPermissionAction) -> Date? { model.agentPermissionPolicy?.grants.first { $0.action == action }?.expiresAt }
        try await model.saveAgentTaskPermissions(revision: 0, families: ["edit": true], days: 7)
        let sevenDays = try XCTUnwrap(expiry(.taskEdit))
        try await model.saveAgentTaskPermissions(revision: 1, families: ["edit": true, "complete": true], days: 30)
        XCTAssertEqual(expiry(.taskEdit), sevenDays, "Turning on another family must not extend an existing grant")
        XCTAssertGreaterThan(try XCTUnwrap(expiry(.taskComplete)).timeIntervalSinceNow, 29 * 86_400)
        try await model.saveAgentTaskPermissions(revision: 2, families: ["edit": true, "complete": true], days: 90, renew: true)
        XCTAssertGreaterThan(try XCTUnwrap(expiry(.taskEdit)).timeIntervalSinceNow, 89 * 86_400)
        XCTAssertGreaterThan(try XCTUnwrap(expiry(.taskComplete)).timeIntervalSinceNow, 89 * 86_400)
        try await model.saveAgentTaskPermissions(revision: 3, families: ["complete": true], days: 7)
        XCTAssertNil(expiry(.taskEdit)); XCTAssertNotNil(expiry(.taskComplete))
    }

    func testAnAwaitedSaveCannotPublishIntoTheNextStoreAfterTeardown() async throws {
        let model = fixture()
        let save = Task { try await model.saveAgentTaskPermissions(revision: 0, families: ["edit": true], days: 30) }
        for _ in 0..<50 where !model.agentPermissionBusy { await Task.yield() } // the save is now awaiting the store
        XCTAssertTrue(model.agentPermissionBusy)
        model.teardownAgentPermissions(reason: "The account changed.")
        do { try await save.value; XCTFail("A torn-down save completed") } catch {}
        XCTAssertNil(model.agentPermissionPolicy); XCTAssertNil(model.agentPermissionNotice); XCTAssertFalse(model.agentPermissionBusy)
        let reopened = try await model.openAgentPermissionStore()
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.revision, 0); XCTAssertTrue(snapshot.grants.isEmpty)
    }

    func testAnUnreadableTaskFileAfterADispatchedWritePausesAllMutationUntilCleanReload() async throws {
        let model = fixture(); _ = try addTasks(model, 2); let run = startRun(model)
        try await grant(model, ["edit": true])
        // The second task has an unfinished deadline review, so its domain write fails; then the task file becomes unreadable.
        var dated = model.taskDocument.items[1]; dated.dueDate = "2026-11-10"; dated.calendarID = "demo"; dated.calendarName = "Demo"; dated.applyDefaultCalendarIntent()
        var doc = model.taskDocument; doc.items[1] = dated; try model.persistTasks(doc)
        model.calendarActions.replace(with: [try dated.deadline(owner: nil)])
        let corrupt = Data("fictional unreadable task file".utf8); try corrupt.write(to: model.taskStore.url)
        let current = model.taskDocument.items
        let result = try await model.authorizeAgentTaskChange(request([patch(current[1], ["title": .string("Cannot save")])]), runID: run)
        XCTAssertEqual(status(result), "failed")
        XCTAssertFalse(model.taskDataReady); XCTAssertNotNil(model.taskError); XCTAssertTrue(model.agentPermissionNeedsReconcile)
        XCTAssertEqual(try Data(contentsOf: model.taskStore.url), corrupt, "The unreadable file must never be overwritten")
        let store = try await model.openAgentPermissionStore()
        let unresolved = try await store.operationRecords().filter { $0.status == "unknown" }
        XCTAssertEqual(unresolved.count, 1)
        // Nothing may mutate or retry with new identifiers while the outcome is uncertain.
        let blocked = try await model.authorizeAgentTaskChange(request([patch(current[0], ["title": .string("Also blocked")])]), runID: run)
        XCTAssertNotEqual(status(blocked), "saved"); XCTAssertEqual(try Data(contentsOf: model.taskStore.url), corrupt)
    }

    func testDirectAddToTasksUsesTheLedgerAndDomainReceiptWithOneOperationID() async throws {
        let service = ReadOnlySourceFixture(), model = fixture(service); await model.loadCalendars()
        let fingerprint = try CalshotModel.taskSourceFingerprint(service.snapshot)
        let receipt = try await model.linkSelectedEventDirectly(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: fingerprint)
        XCTAssertEqual(receipt.outcome, "saved"); XCTAssertEqual(model.taskDocument.items.count, 1)
        let store = try await model.openAgentPermissionStore()
        let stored = try await store.operationRecord(receipt.operationID)
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.status, "succeeded"); XCTAssertEqual(record.envelope.operation.action, .taskLink); XCTAssertTrue(record.envelope.operation.calendarIDs.isEmpty)
        XCTAssertEqual(try model.taskStore.load().operations?.first?.operationID, receipt.operationID)
        let again = try await model.linkSelectedEventDirectly(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: fingerprint)
        XCTAssertEqual(again.outcome, "alreadyLinked"); XCTAssertEqual(model.taskDocument.items.count, 1); XCTAssertEqual(service.writes, 0)
        // A changed source cannot be added from an old selection.
        service.snapshot.title = "Moved fictional day"
        do { _ = try await model.linkSelectedEventDirectly(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: "stale"); XCTFail("Stale selection linked") } catch {}
        XCTAssertEqual(model.taskDocument.items.count, 1)
    }

    func testExactDirectLinkWorksAfterAutomationQuotaIsExhausted() async throws {
        let service = ReadOnlySourceFixture(), model = fixture(service); await model.loadCalendars()
        try await grant(model, ["create": true])
        let store = try await model.openAgentPermissionStore(), policy = try await store.snapshot()
        try await store.replaceGrants(policy.grants, expectedRevision: policy.revision,
            control: .init(nativeOwnerID: model.agentPermissionOwnerID, nativeDeviceID: CalshotModel.syncDeviceID), maxPerRun: 1, maxPerWindow: 1)
        let pending = AgentPermissionOperation(operationID: UUID(), runID: UUID(), ownerID: model.agentPermissionOwnerID, deviceID: CalshotModel.syncDeviceID,
            action: .taskCreate, resourceIDs: ["fictional-pending"], expectedVersions: [:], calendarIDs: [], fields: ["title"],
            effectDigest: String(repeating: "a", count: 64), hasGuestEffects: false, affectsSeries: false, hasSharingEffects: false)
        let resources = AgentPermissionResources(ownerID: model.agentPermissionOwnerID, deviceID: CalshotModel.syncDeviceID, versions: [:],
            writableCalendarIDs: [], supportedActions: [.taskCreate], cancelled: false)
        guard case .allow(let envelope) = try await store.reserve(pending, context: .userRequested(), resources: resources) else { return XCTFail("Fixture reservation failed") }
        try await store.beginDispatch(envelope, resources: resources); try await store.settle(envelope, outcome: .unknown)
        let receipt = try await model.linkSelectedEventDirectly(snapshot: service.snapshot, destinationID: "fictional-readonly",
            expectedFingerprint: CalshotModel.taskSourceFingerprint(service.snapshot))
        XCTAssertEqual(receipt.outcome, "saved"); XCTAssertEqual(model.taskDocument.items.count, 1); XCTAssertEqual(service.writes, 0)
        let record = try await store.operationRecord(receipt.operationID), previous = try await store.operationRecord(pending.operationID)
        XCTAssertEqual(record?.status, "succeeded"); XCTAssertEqual(previous?.status, "unknown")
    }

    func testDirectAddToTasksIsBlockedWhenThePermissionStoreCannotBeOpened() async throws {
        let service = ReadOnlySourceFixture(), model = fixture(service); await model.loadCalendars()
        let directory = model.memoryStore.locationURL.appendingPathComponent("AgentPermissions", isDirectory: true)
            .appendingPathComponent(model.agentPermissionOwnerID, isDirectory: true).appendingPathComponent(CalshotModel.syncDeviceID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("fictional corrupt permissions".utf8); try corrupt.write(to: directory.appendingPathComponent("agent-permissions.json"))
        let fingerprint = try CalshotModel.taskSourceFingerprint(service.snapshot)
        do { _ = try await model.linkSelectedEventDirectly(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: fingerprint); XCTFail("Linked without a readable permission store") } catch {}
        XCTAssertTrue(model.taskDocument.items.isEmpty); XCTAssertNotNil(model.agentPermissionError)
    }
}
