import XCTest
import AppKit
@testable import Calshot

@MainActor
final class WebWorkspaceTests: XCTestCase {
    private func fixture() -> CalshotModel {
        CalshotModel(calendarService: CalendarDemoService(), memoryStore: MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), loadsAIConnection: false)
    }
    private func row() -> CalendarActionProposal {
        CalendarActionProposal(draft: EventDraft(title: "Reviewed exam", startDate: Date(timeIntervalSince1970: 1_800_000_000), endDate: Date(timeIntervalSince1970: 1_800_003_600), isAllDay: false, timeZoneIdentifier: "America/Toronto", location: nil, url: nil, notes: nil, sourceText: "Exam source", confidence: 1, ambiguities: []))
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
}
