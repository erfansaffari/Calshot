import XCTest
import Auth
@testable import Calshot

@MainActor
final class CalendarAgentTests: XCTestCase {
    func testPlanToolsAreNamespacedAndAPIKeyToolsKeepTheirSchema() throws {
        let tool = JSONValue.object(["type": .string("function"), "name": .string("search_events"), "parameters": .object([:])])
        let plan = ResponsesCalendarAgentClient.requestTools([tool], usesChatGPTPlan: true)
        XCTAssertEqual(plan.first?.objectValue?["type"], .string("namespace"))
        XCTAssertEqual(plan.first?.objectValue?["name"], .string("calendar"))
        XCTAssertEqual(plan.first?.objectValue?["tools"], .array([tool]))
        XCTAssertEqual(ResponsesCalendarAgentClient.requestTools([tool], usesChatGPTPlan: false), [tool])
        XCTAssertEqual(ResponsesCalendarAgentClient.requestTools([], usesChatGPTPlan: true), [])
        let output = JSONValue.object(["output": .array([.object(["type": .string("function_call"), "namespace": .string("calendar"), "name": .string("search_events"), "call_id": .string("call_fixture"), "arguments": .string("{}")])])])
        XCTAssertEqual(try ResponsesCalendarAgentClient.decodeResponse(output).calls.first?.name, "search_events")
    }
    func testTerminalRefreshRecoveryClearsOnlyTokensAndKeepsRegistration() {
        let account = ChatGPTConnection.Account(clientID: "oaiapp_fixture", subject: "fixture-subject", email: "alex@example.invalid", idToken: "fictional-id", accessToken: "fictional-access", refreshToken: "fictional-refresh", scopes: "chatgpt.tokens.use.direct", expiresAt: .distantFuture, model: "fixture-model")
        let recovered = ChatGPTConnection.withoutTokens(account)
        XCTAssertEqual(recovered.clientID, account.clientID)
        XCTAssertEqual(recovered.subject, account.subject)
        XCTAssertEqual(recovered.email, account.email)
        XCTAssertTrue(recovered.accessToken.isEmpty)
        XCTAssertTrue(recovered.refreshToken.isEmpty)
        XCTAssertTrue(recovered.idToken.isEmpty)
        XCTAssertFalse(recovered.canUsePlan)
        XCTAssertTrue(ChatGPTConnection.isTerminalRefreshError("invalid_grant"))
        XCTAssertTrue(ChatGPTConnection.isTerminalRefreshError("refresh_token_reused"))
        XCTAssertFalse(ChatGPTConnection.isTerminalRefreshError("temporarily_unavailable"))
        XCTAssertFalse(ChatGPTConnection.isTerminalRefreshError("invalid_client"))
    }
    func testOAuthErrorShapePreservesReasonCodeAndRequestID() {
        let http = HTTPURLResponse(url: URL(string: "https://example.invalid/token")!, statusCode: 400, httpVersion: nil, headerFields: ["x-request-id": "fixture-request"])!
        let message = ResponsesCalendarAgentClient.failureMessage(http: http, data: Data(#"{"error":"invalid_grant","error_description":"Session expired"}"#.utf8))
        XCTAssertTrue(message.contains("invalid_grant"))
        XCTAssertTrue(message.contains("Session expired"))
        XCTAssertTrue(message.contains("fixture-request"))
    }
    func testScreenshotTurnReceivesBroadCalendarScopeAndClarificationPolicy() async throws {
        let client = ScriptedAgentClient([.init(text: "Ready for review")])
        let agent = CalendarAgent(client: client, executor: ScriptedAgentExecutor(results: []))
        try await agent.start(userMessage: CalendarAgent.screenshotPrompt, imageDataURL: "data:image/png;base64,fixture")
        let instructions = try XCTUnwrap(client.instructions.first)
        XCTAssertTrue(instructions.contains("not just due dates"))
        XCTAssertTrue(instructions.contains("appointments, meetings, classes, shifts"))
        XCTAssertTrue(instructions.contains("Never ask for a title, date, time, year, calendar or choice already unambiguously provided"))
        XCTAssertTrue(instructions.contains("prepare the useful batch with unresolved rows clearly marked"))
        XCTAssertTrue(instructions.contains("Never invent times, durations or years"))
        XCTAssertTrue(instructions.contains("Never claim success absent from a tool receipt"))
    }

    func testClarificationContinuationKeepsPolicyRequestAndAnswerTogether() async throws {
        let client = ScriptedAgentClient([
            .init(calls: [.init(name: "ask_user", callID: "question", arguments: #"{"question":"Which Work calendar?","choices":["Work · Personal account","Work · School account"]}"#)]),
            .init(calls: [.init(name: "create_events", callID: "review", arguments: #"{"calendarIdentifier":"fixture-school","events":[{"title":"Workshop","date":"2026-11-10","startTime":null,"endTime":null,"allDay":null,"timeZone":"America/Toronto","location":null,"url":null,"notes":null,"evidence":"Workshop on November 10, 2026; time TBD.","yearInferred":false,"dateAmbiguous":false}]}"#)]),
            .init(text: "No changes were saved.")
        ])
        let executor = ScriptedAgentExecutor(results: [#"{"answer":"Work · School account"}"#, #"{"added":[],"failed":[],"skipped":[{"title":"Workshop"}]}"#])
        let agent = CalendarAgent(client: client, executor: executor)
        try await agent.start(userMessage: "Add the workshop on November 10, 2026 to Work; the time is TBD.", imageDataURL: nil)
        XCTAssertEqual(executor.names, ["ask_user", "create_events"])
        XCTAssertEqual(client.instructions.count, 3)
        XCTAssertTrue(client.instructions.allSatisfy { $0.hasPrefix(CalendarAgent.instructions) })
        XCTAssertEqual(Set(client.instructions).count, 1, "Continuation must keep the same policy and clock context.")
        let reviewInput = try XCTUnwrap(client.conversations.last)
        XCTAssertEqual(reviewInput.first?.value.objectValue?["content"]?.stringValue, "Add the workshop on November 10, 2026 to Work; the time is TBD.")
        let answers = reviewInput.compactMap { $0.value.objectValue }.filter { $0["type"]?.stringValue == "function_call_output" }
        XCTAssertTrue(answers.contains { $0["call_id"]?.stringValue == "question" && $0["output"]?.stringValue?.contains("School account") == true })
        XCTAssertEqual(executor.arguments.last?.objectValue?["events"]?.arrayValue?.first?.objectValue?["startTime"], .null)
    }

    func testSignInPersistsCredentialsBeforeUnavailableModelCatalog() async throws {
        let account = ChatGPTConnection.Account(clientID: "oaiapp_fixture", subject: "test", email: "test@example.com",
            idToken: "fixture", accessToken: "fixture", refreshToken: "fixture", scopes: "chatgpt.tokens.use.direct",
            expiresAt: .distantFuture, model: "")
        var saved: [ChatGPTConnection.Account] = []
        let result = try await ChatGPTConnection.finishSignIn(account, persist: { saved.append($0) }, loadModel: {
            XCTAssertEqual(saved.count, 1)
            throw ResponsesCalendarAgentClient.ClientError.http(520, "catalog unavailable", nil)
        })
        XCTAssertEqual(result.account.email, account.email)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(result.error?.contains("catalog unavailable") == true)
        let ready = try await ChatGPTConnection.finishSignIn(account, persist: { saved.append($0) }, loadModel: { "available-model" })
        XCTAssertEqual(ready.account.model, "available-model")
        XCTAssertEqual(saved.last?.model, "available-model")
        XCTAssertNil(ready.error)
    }
    func testIncompleteAndFailedStreamsPreserveReasonWithoutExecutingPartialTools() throws {
        for terminal in [
            #"{"type":"response.incomplete","response":{"id":"resp-limit","incomplete_details":{"reason":"max_output_tokens"}}}"#,
            #"{"type":"response.failed","response":{"id":"resp-failed","error":{"code":"subscription_sharing_usage_unavailable","message":"Usage unavailable","param":"model"}}}"#
        ] {
            var parser = CalendarAgentStreamParser()
            _ = try parser.consume(line: #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","name":"delete_event","call_id":"partial","arguments":"{}"}}"#)
            XCTAssertThrowsError(try parser.consume(line: "data: " + terminal)) { error in
                XCTAssertTrue(error.localizedDescription.contains(terminal.contains("max_output_tokens") ? "max_output_tokens" : "subscription_sharing_usage_unavailable"))
                XCTAssertTrue(error.localizedDescription.contains("Response ID:"))
            }
            XCTAssertNil(parser.completed)
        }
    }
    func testPlanAdmissionErrorPreservesDetailAndRequestIdentifier() {
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!, statusCode: 503,
                                       httpVersion: nil, headerFields: ["x-request-id": "req-test"])!
        let message = ResponsesCalendarAgentClient.failureMessage(http: response, data: Data(#"{"detail":"Direct route unavailable"}"#.utf8))
        XCTAssertTrue(message.contains("503"))
        XCTAssertTrue(message.contains("Direct route unavailable"))
        XCTAssertTrue(message.contains("req-test"))
        let structured = ResponsesCalendarAgentClient.failureMessage(http: response,
            data: Data(#"{"error":{"message":"Unsupported","code":"subscription_sharing_unsupported_capability","param":"tools"}}"#.utf8))
        XCTAssertTrue(structured.contains("subscription_sharing_unsupported_capability"))
        XCTAssertTrue(structured.contains("Parameter: tools"))
    }

    func testServer520RetriesBeforeReturningSuccess() async throws {
        var attempts = 0
        var delays: [Double] = []
        var statuses: [String] = []
        let value = try await ResponsesCalendarAgentClient.withRetry(operation: {
            attempts += 1
            if attempts < 3 { throw ResponsesCalendarAgentClient.ClientError.http(520, "upstream", nil) }
            return "completed"
        }, onRetry: { statuses.append($0) }, sleep: { delays.append($0) })
        XCTAssertEqual(value, "completed")
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(delays, [1, 2])
        XCTAssertEqual(statuses.count, 2)
    }
    func testPersistentServerFailureIsBoundedAndAuthIsNotRetried() async {
        for status in [520, 401, 429] {
            var attempts = 0
            do {
                _ = try await ResponsesCalendarAgentClient.withRetry(operation: { () async throws -> String in
                    attempts += 1
                    throw ResponsesCalendarAgentClient.ClientError.http(status, "failed", nil)
                }, sleep: { _ in })
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(attempts, status == 520 ? 3 : 1) }
        }
    }
    func testRetryDelayHonorsHeaderAndCancellation() async {
        var attempts = 0
        var delay: Double?
        do {
            _ = try await ResponsesCalendarAgentClient.withRetry(operation: { () async throws -> String in
                attempts += 1
                throw ResponsesCalendarAgentClient.ClientError.http(503, "overloaded", 7)
            }, sleep: { delay = $0; throw CancellationError() })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(delay, 7)
    }
    func testModelPublishesChatRepliesAndRestoresConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryStore(directoryURL: directory)
        let model = CalshotModel(calendarService: CalendarDemoService(), memoryStore: store, loadsAIConnection: false,
            agentClient: ScriptedAgentClient([.init(text: "Here is your calendar response.")]))
        model.agentCommand = "Hello"
        await model.startAgentCommand()
        XCTAssertEqual(model.workspaceSelection, .chat)
        XCTAssertEqual(model.agentMessages.filter { $0.role == "assistant" }.last?.content, "Here is your calendar response.")
        XCTAssertEqual(model.agentStreamingText, "")
        let record = try XCTUnwrap(store.listRecords().first)
        model.agentMessages = []
        model.restoreCalendarReview(record)
        XCTAssertEqual(model.workspaceSelection, .chat)
        XCTAssertEqual(model.agentMessages.last?.content, "Here is your calendar response.")
    }

    func testFailedCommandIsVisibleAndCanBeRetried() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryStore(directoryURL: directory)
        let client = ScriptedAgentClient([.init(text: "No events found.")])
        client.failNextTurn = true
        let model = CalshotModel(calendarService: CalendarDemoService(), memoryStore: store,
                                 loadsAIConnection: false, agentClient: client)
        model.agentCommand = "Find today's events"
        await model.startAgentCommand()
        XCTAssertEqual(model.workspaceSelection, .chat)
        XCTAssertTrue(model.agentError?.contains("520") == true)
        XCTAssertEqual(model.agentRetryPrompt, "Find today's events")
        XCTAssertTrue(model.agentMessages.contains { $0.role == "error" })
        XCTAssertTrue(store.listRecords().first?.agentTranscript?.contains { $0.role == "error" } == true)
        await model.retryAgentCommand()
        XCTAssertNil(model.agentError)
        XCTAssertNil(model.agentRetryPrompt)
        XCTAssertEqual(model.agentMessages.last?.content, "No events found.")
    }

    func testRetryPreservesTypedVersusScreenshotRequestOrigin() async throws {
        for typed in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = ScriptedAgentClient([.init(text: "Offline result.")]); client.failNextTurn = true
            let model = CalshotModel(calendarService: CalendarDemoService(), memoryStore: MemoryStore(directoryURL: directory),
                                     loadsAIConnection: false, agentClient: client)
            model.agentCommand = "Import the captured dates"
            await model.startAgentCommand(isTypedRequest: typed)
            XCTAssertNotNil(model.agentRetryPrompt)
            XCTAssertEqual(model.agentRetryWasTypedRequest, typed)
            XCTAssertEqual(model.agentTypedRunID != nil, typed)
            await model.retryAgentCommand()
            XCTAssertNil(model.agentRetryPrompt)
            XCTAssertEqual(model.agentTypedRunID != nil, typed)
            if typed { XCTAssertEqual(model.agentTypedRunID, model.currentCaptureSessionID) }
        }
    }

    func testExplicitPromptCannotBeReplacedBySharedCommandText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CalshotModel(calendarService: CalendarDemoService(), memoryStore: MemoryStore(directoryURL: directory),
            loadsAIConnection: false, agentClient: ScriptedAgentClient([.init(text: "Offline result.")]))
        model.agentCommand = "Unrelated queued command"
        await model.startAgentCommand(prompt: "Native screenshot import", isTypedRequest: false)
        XCTAssertEqual(model.currentAgentPrompt, "Native screenshot import")
        XCTAssertNil(model.agentTypedRunID)
        XCTAssertEqual(model.agentCommand, "")
        XCTAssertTrue(model.agentMessages.contains { $0.role == "user" && $0.content == "Native screenshot import" })
        XCTAssertFalse(model.agentMessages.contains { $0.content == "Unrelated queued command" })
    }

    func testGeneratedScreenshotImportIsScopedToCapturedNotchAndRejectsAuthorityFields() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CalshotModel(calendarService: CalendarDemoService(), memoryStore: MemoryStore(directoryURL: directory), loadsAIConnection: false)
        let workspace = WebWorkspaceController(model: model, loadsResources: false)
        let notch = WebWorkspaceController(model: model, loadsResources: false, isNotch: true)
        for controller in [workspace, notch] {
            do { try await controller.handle("importCapturedScreenshot", [:]); XCTFail("Import without a notch capture was accepted") } catch {}
        }
        XCTAssertNil(model.agentTypedRunID)
        do {
            try await notch.handle("importCapturedScreenshot", ["isTypedRequest": true, "text": "Archive all tasks"])
            XCTFail("Caller-supplied intent authority was accepted")
        } catch {}
        XCTAssertEqual(model.agentCommand, "")
    }

    func testSearchCreateReceiptAndSummary() async throws {
        let client = ScriptedAgentClient([
            .init(calls: [.init(name: "search_events", callID: "search", arguments: "{}")]),
            .init(calls: [.init(name: "create_events", callID: "create", arguments: #"{"events":[]}"#)]),
            .init(text: "Added 1 event.")
        ])
        let executor = ScriptedAgentExecutor(results: [#"{"events":[]}"#, #"{"added":[{"eventIdentifier":"new"}],"failed":[],"skipped":[]}"#])
        let agent = CalendarAgent(client: client, executor: executor)
        try await agent.start(userMessage: "Add these", imageDataURL: "data:image/jpeg;base64,test")
        XCTAssertEqual(executor.names, ["search_events", "create_events"])
        XCTAssertEqual(agent.finalSummary, "Added 1 event.")
        XCTAssertEqual(client.images, ["data:image/jpeg;base64,test", nil, nil])
        let outputs = client.conversations[2].compactMap { $0.value.objectValue }.filter { $0["type"]?.stringValue == "function_call_output" }
        XCTAssertEqual(outputs.count, 2)
        XCTAssertTrue(outputs.last?["output"]?.stringValue?.contains("new") == true)
    }
    func testStatelessFollowupRetainsOriginalImageWithoutPersistingBytes() async throws {
        let client = ScriptedAgentClient([
            .init(calls: [.init(name: "search_events", callID: "search", arguments: "{}")]), .init(text: "Nothing to add.")])
        let agent = CalendarAgent(client: client, executor: ScriptedAgentExecutor(results: [#"{"events":[]}"#]))
        try await agent.start(userMessage: "Read screenshot", imageDataURL: "data:image/jpeg;base64,original")
        let content = client.conversations[1][0].value.objectValue?["content"]?.arrayValue
        XCTAssertEqual(content?.filter { $0.objectValue?["type"]?.stringValue == "input_image" }.count, 1)
        let encoded = String(data: try JSONEncoder().encode(agent.transcript), encoding: .utf8)
        XCTAssertFalse(encoded?.contains("data:image") == true)
    }
    func testTypedFollowupIncludesReceiptsWithoutReexecutingOldActions() async throws {
        let client = ScriptedAgentClient([
            .init(calls: [.init(name: "create_events", callID: "create", arguments: #"{"events":[{"title":"Math"}]}"#)]),
            .init(text: "Added Math."), .init(text: "Math was already added; no further changes.")])
        let executor = ScriptedAgentExecutor(results: [#"{"added":[{"eventIdentifier":"math"}],"failed":[],"skipped":[]}"#])
        let agent = CalendarAgent(client: client, executor: executor)
        try await agent.start(userMessage: "Add Math", imageDataURL: nil)
        let prior = agent.transcript
        try await agent.start(userMessage: "What did you add?", imageDataURL: nil, memory: prior)
        XCTAssertEqual(executor.names, ["create_events"])
        XCTAssertEqual(client.conversations[2].count, 1)
        XCTAssertTrue(client.instructions[2].contains("math"))
        XCTAssertEqual(agent.transcript.first?.content, "What did you add?")
    }
    func testStopPreservesActualPartialWriteReceipt() async throws {
        let client = ScriptedAgentClient([
            .init(calls: [.init(name: "create_events", callID: "pending", arguments: #"{"events":[]}"#)])])
        let executor = SuspendedAgentExecutor()
        let agent = CalendarAgent(client: client, executor: executor)
        var persisted: [AgentTurn] = []
        agent.onTranscriptChanged = { persisted = $0 }
        let running = Task { try await agent.start(userMessage: "Add", imageDataURL: nil) }
        while executor.continuation == nil { await Task.yield() }
        agent.cancel()
        executor.continuation?.resume(returning: #"{"added":[{"eventIdentifier":"written"}],"failed":[],"skipped":[{"title":"Pending"}]}"#)
        executor.continuation = nil
        try await running.value
        XCTAssertFalse(agent.isRunning)
        XCTAssertEqual(client.conversations.count, 1)
        XCTAssertTrue(persisted.last?.result?.contains("written") == true)
        XCTAssertTrue(persisted.last?.result?.contains("skipped") == true)
        XCTAssertEqual(agent.status, "Stopped")
    }
    func testSkippedDeleteIsReturnedToModel() async throws {
        let client = ScriptedAgentClient([
            .init(calls: [.init(name: "delete_event", callID: "delete", arguments: #"{"eventIdentifier":"old","reason":"old"}"#)]),
            .init(text: "Skipped the removal.")])
        let executor = ScriptedAgentExecutor(results: [#"{"skipped":true}"#])
        let agent = CalendarAgent(client: client, executor: executor)
        try await agent.start(userMessage: "Remove it", imageDataURL: nil)
        XCTAssertEqual(executor.names, ["delete_event"])
        XCTAssertTrue(client.conversations[1].last?.value.objectValue?["output"]?.stringValue?.contains("skipped") == true)
    }
    func testTwoMatchesAskBeforeUpdate() async throws {
        let client = ScriptedAgentClient([
            .init(calls: [.init(name: "search_events", callID: "search", arguments: "{}")]),
            .init(calls: [.init(name: "ask_user", callID: "ask", arguments: #"{"question":"Which midterm?","choices":["Math","Physics"]}"#)]),
            .init(calls: [.init(name: "update_event", callID: "update", arguments: #"{"eventIdentifier":"math","title":"Math midterm"}"#)]),
            .init(text: "Updated Math midterm.")])
        let executor = ScriptedAgentExecutor(results: [#"{"events":[{"eventIdentifier":"math"},{"eventIdentifier":"physics"}]}"#, #"{"answer":"Math"}"#, #"{"updated":true,"eventIdentifier":"math"}"#])
        let agent = CalendarAgent(client: client, executor: executor)
        try await agent.start(userMessage: "Move my midterm", imageDataURL: nil)
        XCTAssertEqual(executor.names, ["search_events", "ask_user", "update_event"])
    }
    func testSyllabusBatchAndOnlyFailedRowsRetry() async throws {
        let rows = (1...12).map { JSONValue.object(["title": .string("Assignment \($0)")]) }
        let first = JSONValue.object(["events": .array(rows)]).jsonString()
        let retry = JSONValue.object(["events": .array(Array(rows.suffix(3)))]).jsonString()
        let client = ScriptedAgentClient([
            .init(calls: [.init(name: "create_events", callID: "batch", arguments: first)]),
            .init(calls: [.init(name: "create_events", callID: "retry", arguments: retry)]),
            .init(text: "Added 12 assignments.")])
        let failures = JSONValue.object(["failed": .array(Array(rows.suffix(3))), "added": .array(Array(rows.prefix(9))), "skipped": .array([])]).jsonString()
        let executor = ScriptedAgentExecutor(results: [failures, #"{"added":[1,2,3],"failed":[],"skipped":[]}"#])
        let agent = CalendarAgent(client: client, executor: executor)
        try await agent.start(userMessage: "Add the syllabus", imageDataURL: "image")
        XCTAssertEqual(executor.arguments.map { $0.objectValue?["events"]?.arrayValue?.count }, [12, 3])
        XCTAssertEqual(executor.arguments.last?.objectValue?["events"]?.arrayValue, Array(rows.suffix(3)))
        XCTAssertTrue(client.conversations[1].last?.value.objectValue?["output"]?.stringValue?.contains("failed") == true)
    }
    func testEightTurnLimitPreservesReceipts() async throws {
        let responses = (0..<9).map { AgentModelResponse(calls: [.init(name: "create_events", callID: "call\($0)", arguments: #"{"events":[]}"#)]) }
        let client = ScriptedAgentClient(responses)
        let executor = ScriptedAgentExecutor(results: Array(repeating: #"{"added":[{"eventIdentifier":"saved"}],"failed":[],"skipped":[]}"#, count: 9))
        let agent = CalendarAgent(client: client, executor: executor)
        try await agent.start(userMessage: "Add", imageDataURL: nil)
        XCTAssertEqual(client.conversations.count, 8)
        XCTAssertEqual(executor.names.count, 8)
        XCTAssertEqual(agent.transcript.filter { $0.role == "tool" }.count, 8)
        XCTAssertEqual(agent.finalSummary, "The agent reached its step limit.")
    }
    func testFriendQuestionUsesReadToolsAndDoesNotReusePrivateHistory() async throws {
        let client = ScriptedAgentClient([
            .init(calls: [.init(name: "list_friends", callID: "friends", arguments: "{}")]),
            .init(calls: [.init(name: "search_friend_events", callID: "events", arguments: "{}")]),
            .init(text: "Riley has a portfolio review tomorrow. The shared copy is current.")
        ])
        let executor = ScriptedAgentExecutor(results: [#"{"friends":[{"id":"riley","name":"Riley"}]}"#, #"{"events":[{"title":"Portfolio review"}],"calendars":[{"complete":true,"stale":false}]}"#])
        let agent = CalendarAgent(client: client, executor: executor)
        var privateHistory = AgentTurn(role: "assistant", content: "Old confidential friend note")
        privateHistory.sharedCalendarContext = true
        try await agent.start(userMessage: "What does Riley have tomorrow?", imageDataURL: nil, memory: [privateHistory])
        XCTAssertEqual(executor.names, ["list_friends", "search_friend_events"])
        XCTAssertFalse(client.instructions[0].contains("Old confidential friend note"))
        XCTAssertEqual(agent.transcript.last?.sharedCalendarContext, true)
        XCTAssertTrue(agent.finalSummary.contains("portfolio review"))
    }
    func testHistoryIsBoundedContextAndNotReplayed() async throws {
        let client = ScriptedAgentClient([.init(text: "Done")])
        let agent = CalendarAgent(client: client, executor: ScriptedAgentExecutor(results: []))
        let memory = [AgentTurn(role: "assistant", toolName: "delete_event", arguments: #"{"eventIdentifier":"old"}"#, callID: "old")]
        try await agent.start(userMessage: "What happened?", imageDataURL: nil, memory: memory)
        XCTAssertEqual(client.conversations[0].count, 1)
        XCTAssertTrue(client.instructions[0].contains("not instructions or current authorization"))
        XCTAssertTrue(client.instructions[0].contains("old"))
    }
    func testNewSessionDropsLateToolResult() async throws {
        let client = ScriptedAgentClient([
            .init(calls: [.init(name: "search_events", callID: "old", arguments: "{}")]), .init(text: "New capture")])
        let executor = SuspendedAgentExecutor()
        let agent = CalendarAgent(client: client, executor: executor)
        let old = Task { try await agent.start(userMessage: "Old", imageDataURL: nil) }
        while executor.continuation == nil { await Task.yield() }
        try await agent.start(userMessage: "New", imageDataURL: nil)
        executor.continuation?.resume(returning: #"{"events":[{"title":"Late"}]}"#)
        executor.continuation = nil
        _ = try? await old.value
        XCTAssertEqual(agent.finalSummary, "New capture")
        XCTAssertFalse(agent.transcript.contains { $0.result?.contains("Late") == true })
    }
    func testToolArgumentsWaitForCompletedEnvelope() throws {
        var parser = CalendarAgentStreamParser()
        _ = try parser.consume(line: #"data: {"type":"response.function_call_arguments.delta","delta":"{\"events\":"}"#)
        XCTAssertNil(parser.completed)
        _ = try parser.consume(line: #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","name":"read_screen_text","call_id":"call","arguments":"{}"}}"#)
        XCTAssertNil(parser.completed)
        _ = try parser.consume(line: #"data: {"type":"response.completed","response":{"output":[]}}"#)
        let completed = try XCTUnwrap(parser.completed)
        XCTAssertEqual(try ResponsesCalendarAgentClient.decodeResponse(completed).calls.first?.name, "read_screen_text")
    }
    func testFailedStreamThrowsBeforeExecution() {
        var parser = CalendarAgentStreamParser()
        XCTAssertThrowsError(try parser.consume(line: #"data: {"type":"response.failed","response":{"error":{"message":"Failed"}}}"#))
    }
}

@MainActor
private final class ScriptedAgentClient: CalendarAgentModelClient {
    var failNextTurn = false
    var responses: [AgentModelResponse]
    var conversations: [[AgentMessage]] = []
    var images: [String?] = []
    var instructions: [String] = []
    init(_ responses: [AgentModelResponse]) { self.responses = responses }
    func turn(conversation: [AgentMessage], imageDataURL: String?, instructions: String, tools: [JSONValue],
              onText: @escaping @MainActor (String) -> Void) async throws -> AgentModelResponse {
        if failNextTurn { failNextTurn = false; throw ResponsesCalendarAgentClient.ClientError.http(520, "HTTP 520", nil) }
        conversations.append(conversation); images.append(imageDataURL); self.instructions.append(instructions)
        let result = responses.removeFirst()
        if !result.text.isEmpty { onText(result.text) }
        return result
    }
}
@MainActor
private final class ScriptedAgentExecutor: CalendarAgentToolExecuting {
    var results: [String]
    var names: [String] = []
    var arguments: [JSONValue] = []
    init(results: [String]) { self.results = results }
    func execute(name: String, arguments: JSONValue, sessionID: UUID) async -> String {
        names.append(name); self.arguments.append(arguments); return results.removeFirst()
    }
    func cancelPending(sessionID: UUID) {}
}
@MainActor
private final class SuspendedAgentExecutor: CalendarAgentToolExecuting {
    var continuation: CheckedContinuation<String, Never>?
    func execute(name: String, arguments: JSONValue, sessionID: UUID) async -> String {
        await withCheckedContinuation { continuation = $0 }
    }
    func cancelPending(sessionID: UUID) {}
}

@MainActor
final class TaskDomainPhaseOneTests: XCTestCase {
    private func model(_ service: any CalendarDestinationService = CalendarDemoService()) -> CalshotModel {
        CalshotModel(calendarService: service, memoryStore: MemoryStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("task-domain-fixture-" + UUID().uuidString)), loadsAIConnection: false)
    }
    func testLegacyIntentResolutionAndExplicitTaskOnlyLaterDate() throws {
        let old = CalshotTask(title: "Fictional report", dueDate: "2026-11-10")
        let encoded = try CalshotTaskStore.encoder.encode(old)
        let decoded = try CalshotTaskStore.decoder.decode(CalshotTask.self, from: encoded)
        XCTAssertNil(decoded.calendarIntent); XCTAssertEqual(decoded.resolvedCalendarIntent, .new)
        XCTAssertTrue(decoded.needsPublication)
        var undated = CalshotTask(title: "Read fictional chapter")
        undated.resolveCalendarIntent(); XCTAssertEqual(undated.resolvedCalendarIntent, .none)
        undated.dueDate = "2026-11-10"; undated.applyDefaultCalendarIntent()
        XCTAssertEqual(undated.resolvedCalendarIntent, .new)
        undated.calendarIntent = CalshotTaskCalendarIntent.none; undated.intentProvenance = .explicit
        undated.dueDate = "2026-11-11"; undated.applyDefaultCalendarIntent()
        XCTAssertEqual(undated.resolvedCalendarIntent, .none); XCTAssertFalse(undated.needsPublication)
        XCTAssertThrowsError(try undated.deadline(owner: nil))
        var owned = CalshotTask(title: "Owned undated deadline")
        owned.receipt = .init(destinationID: "fixture", calendarName: "Fictional", eventIdentifier: "owned", savedAt: .now)
        owned.resolveCalendarIntent(); XCTAssertEqual(owned.resolvedCalendarIntent, .new)
    }
    func testConflictCopiesStaySuppressedWhenDatedLater() throws {
        for day in [nil, "2026-11-10"] as [String?] {
            var copy = CalshotTask(title: "Fictional conflict", dueDate: day).conflictCopy()
            copy.dueDate = "2026-11-11"; copy.applyDefaultCalendarIntent()
            try copy.validate()
            XCTAssertEqual(copy.intentProvenance, .suppressed); XCTAssertFalse(copy.needsPublication)
            XCTAssertNil(copy.receipt); XCTAssertNil(copy.sourceLink)
            XCTAssertThrowsError(try copy.deadline(owner: nil))
        }
    }
    func testSharedMutationVersionIdempotencyNullAndAgentOrigin() async throws {
        let m = model(); let context = try m.taskContext(origin: .workspace), op = UUID()
        let patch: [String: JSONValue] = ["title": .string("Fictional task"), "calendarIntent": .string("none"), "dueDate": .string("2026-11-10")]
        let saved = try m.mutateTask(taskID: nil, expectedVersion: nil, patch: patch, context: context, operationID: op)
        XCTAssertEqual(try m.mutateTask(taskID: nil, expectedVersion: nil, patch: patch, context: context, operationID: op), saved)
        XCTAssertEqual(m.taskDocument.items.count, 1); XCTAssertFalse(m.taskDocument.items[0].needsPublication)
        XCTAssertThrowsError(try m.mutateTask(taskID: saved.taskID, expectedVersion: UUID(), patch: ["completed": .bool(true)], context: context, operationID: UUID()))
        XCTAssertThrowsError(try m.mutateTask(taskID: nil, expectedVersion: nil, patch: ["title": .string("different")], context: context, operationID: op))
        let run = UUID(); m.activeAgentRunID = run; m.agentIsRunning = true
        let agent = try m.taskContext(origin: .agent(runID: run))
        let edited = try m.mutateTask(taskID: saved.taskID, expectedVersion: saved.taskVersion, patch: ["notes": .string("Task only"), "dueDate": .null], context: agent, operationID: UUID())
        XCTAssertNil(m.taskDocument.items[0].dueDate); XCTAssertEqual(m.taskDocument.items[0].title, "Fictional task")
        m.activeAgentRunID = nil
        XCTAssertThrowsError(try m.mutateTask(taskID: edited.taskID, expectedVersion: edited.taskVersion, patch: ["completed": .bool(true)], context: agent, operationID: UUID()))
        let reloaded = try m.taskStore.load(); XCTAssertEqual(reloaded.operations?.count, 2)
    }
    func testLinkReadableSourceIsAtomicIdempotentAndNeverPublishes() async throws {
        let service = TaskLinkFixtureService(), m = model(service); await m.loadCalendars()
        let context = try m.taskContext(origin: .workspace)
        let fingerprint = try CalshotModel.taskSourceFingerprint(service.snapshot)
        async let first = m.linkExistingEvent(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: fingerprint, context: context, operationID: UUID())
        async let second = m.linkExistingEvent(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: fingerprint, context: context, operationID: UUID())
        let (a,b) = try await (first,second)
        XCTAssertEqual(a.taskID, b.taskID); XCTAssertEqual(m.taskDocument.items.count, 1)
        let linked = m.taskDocument.items[0]
        XCTAssertEqual(linked.resolvedCalendarIntent, .existing); XCTAssertNil(linked.receipt)
        XCTAssertNil(linked.dueTime); XCTAssertFalse(linked.needsPublication)
        let updated = try m.mutateTask(taskID: linked.id, expectedVersion: linked.version, patch: ["title": .string("Task-only rename"), "completed": .bool(true), "archived": .bool(true)], context: context, operationID: UUID())
        try await m.reviewTaskDeadline(updated.taskID)
        XCTAssertTrue(m.calendarActions.proposals.isEmpty)
        let repeated = try await m.linkExistingEvent(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: fingerprint, context: context, operationID: UUID())
        XCTAssertEqual(repeated.outcome, "alreadyLinkedArchived"); XCTAssertEqual(repeated.taskID, linked.id)
        XCTAssertEqual(service.writes, 0)
        var duplicate = linked; duplicate.id = UUID()
        XCTAssertThrowsError(try m.taskStore.save(.init(items: [linked,duplicate])))
        var conflict = linked.conflictCopy(); conflict.dueDate = "2026-11-12"; conflict.applyDefaultCalendarIntent()
        XCTAssertNil(conflict.sourceLink); XCTAssertFalse(conflict.needsPublication)
    }
    func testInvalidSourceAndStaleContextCannotCreateTask() async throws {
        let service = TaskLinkFixtureService(), m = model(service); await m.loadCalendars()
        let context = try m.taskContext(origin: .workspace)
        m.taskSessionID = UUID()
        do { _ = try await m.linkExistingEvent(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: CalshotModel.taskSourceFingerprint(service.snapshot), context: context, operationID: UUID()); XCTFail("Stale context accepted") } catch {}
        XCTAssertTrue(m.taskDocument.items.isEmpty); XCTAssertEqual(service.writes, 0)
        var invalid = CalshotTaskSourceLink(deviceID: "device", calendarID: "calendar", eventID: "event", occurrenceKey: "single", observedStart: .now, observedEnd: .distantPast, observedAt: .now, sourceName: "Fictional", calendarName: "Fictional")
        XCTAssertThrowsError(try invalid.validate()); invalid.observedEnd = .distantFuture; invalid.deviceID = ""
        XCTAssertThrowsError(try invalid.validate())
    }
    func testTasksOnlyDatedImportUsesNoCalendarProposal() async throws {
        let m = model(); m.currentMemoryRecordID = try m.memoryStore.recordCommand("Fictional tasks only").id
        let result = try m.createAgentTasks(["tasks": .array([.object(["title": .string("Fictional report"), "dueDate": .string("2026-11-10"), "yearResolved": .bool(true), "sourceText": .string("Fictional task"), "calendarIntent": .string("none")])])])
        XCTAssertTrue(result.proposals.isEmpty); XCTAssertEqual(m.taskImport?.selectedInboxIDs.count, 1)
        m.agentIsWaitingForApproval = true; try m.commitTaskImport()
        XCTAssertEqual(m.taskDocument.items.count, 1); XCTAssertFalse(m.taskDocument.items[0].needsPublication)
    }
}

private final class TaskLinkFixtureService: CalendarDestinationService, @unchecked Sendable {
    // The domain calls no mutation method; the counter makes that property observable.
    private(set) var writes = 0
    var snapshot = CalendarEventSnapshot(eventIdentifier: "fictional-event", title: "Fictional reading day", start: Date(timeIntervalSince1970: 1_800_057_600), end: Date(timeIntervalSince1970: 1_800_144_000), isAllDay: true, timeZone: "UTC", location: nil, calendarName: "Fictional read-only calendar", url: nil, notes: nil, isRecurring: false)
    func availableDestinations() async throws -> [CalendarDestinationInfo] { [.init(id: "fictional-readonly", title: "Fictional read-only calendar", provider: .other, isReadOnly: true, sourceName: nil, timeZone: "UTC")] }
    func event(identifier: String, in destination: CalendarDestination) async throws -> CalendarEventSnapshot? { await Task.yield(); return identifier == snapshot.eventIdentifier ? snapshot : nil }
    func matchingEvents(_ draft: EventDraft, in destination: CalendarDestination) async throws -> [String] { [] }
    func save(_ draft: EventDraft, to destination: CalendarDestination) async throws -> String { writes += 1; throw CalendarDestinationError.calendarReadOnly }
    func update(_ draft: EventDraft, identifier: String, in destination: CalendarDestination) async throws -> String { writes += 1; throw CalendarDestinationError.calendarReadOnly }
    func delete(identifier: String, in destination: CalendarDestination) async throws { writes += 1; throw CalendarDestinationError.calendarReadOnly }
}

extension TaskDomainPhaseOneTests {
    func testMalformedIntentPairsAndSourcePublicationOwnershipAreRejected() throws {
        var task = CalshotTask(title: "Fictional malformed task")
        task.calendarIntent = CalshotTaskCalendarIntent.none
        XCTAssertThrowsError(try task.validate())
        task.intentProvenance = .explicit; XCTAssertNoThrow(try task.validate())
        task.calendarIntent = .existing; XCTAssertThrowsError(try task.validate())
        task.sourceLink = .init(deviceID: "fictional-device", calendarID: "fixture-calendar", eventID: "fixture-event", occurrenceKey: "single", observedStart: Date(timeIntervalSince1970: 1_800_000_000), observedEnd: Date(timeIntervalSince1970: 1_800_003_600), observedAt: .now, sourceName: "Fictional", calendarName: "Fictional")
        XCTAssertNoThrow(try task.validate())
        task.receipt = .init(destinationID: "fixture-calendar", calendarName: "Fictional", eventIdentifier: "fixture-event", savedAt: .now)
        XCTAssertThrowsError(try task.validate())
    }
}


extension TaskDomainPhaseOneTests {
    func testAllDayCoveredDatesAcceptBothEndConventionsAcrossDST() async throws {
        for day in ["2026-03-08", "2026-11-01"] {
            let start = try CalshotTask.date(day, zone: "America/Toronto")
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Toronto")!
            let midnight = calendar.date(byAdding: .day, value: 1, to: start)!
            for end in [midnight, midnight.addingTimeInterval(-1)] {
                let service = TaskLinkFixtureService(); service.snapshot.start = start; service.snapshot.end = end; service.snapshot.timeZone = "America/Toronto"
                let m = model(service); await m.loadCalendars()
                _ = try await m.linkExistingEvent(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: CalshotModel.taskSourceFingerprint(service.snapshot), context: m.taskContext(origin: .workspace), operationID: UUID())
                XCTAssertEqual(m.taskDocument.items.first?.dueDate, day); XCTAssertNil(m.taskDocument.items.first?.dueTime)
                XCTAssertEqual(m.taskDocument.items.first?.sourceLink?.sourceName, "other")
                XCTAssertEqual(service.writes, 0)
            }
        }
    }
    func testTaskSyncV2MissingMigrationRetainsPersistedLocalEdits() async throws {
        let m = model(); m.account.onAuthenticated = nil
        let user = UUID()
        m.account.accept(User(id: user, appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "fictional@example.invalid", createdAt: .now, updatedAt: .now), provider: "email")
        m.activeLocalAccountID = user
        var task = CalshotTask(title: "Fictional local task", dueDate: "2026-11-10")
        task.calendarIntent = CalshotTaskCalendarIntent.none; task.intentProvenance = .explicit
        try m.persistTasks(.init(items: [task]))
        m.taskRPC = { name, _, _ in
            XCTAssertEqual(name, "read_task_state_v2")
            throw CalendarToolArgumentError("Update required: fixture endpoint unavailable")
        }
        await m.syncTasks()
        XCTAssertTrue(m.taskError?.contains("Local changes are kept") == true)
        XCTAssertEqual(try m.taskStore.load().items.first?.calendarIntent, CalshotTaskCalendarIntent.none)
        var calls: [String] = []
        m.taskRPC = { name, body, _ in
            calls.append(name)
            if name == "read_task_state_v2" { return .object(["protocol_version": .number(2), "revision": .number(0), "items": .array([])]) }
            XCTAssertEqual(name, "write_task_state_v2"); XCTAssertEqual(body.objectValue?["protocol_version"], .number(2))
            XCTAssertEqual(body.objectValue?["items"]?.arrayValue?.first?.objectValue?["calendarIntent"], .string("none"))
            throw CalendarToolArgumentError("Fixture write failed")
        }
        await m.syncTasks()
        XCTAssertEqual(calls, ["read_task_state_v2", "write_task_state_v2"])
        XCTAssertEqual(try m.taskStore.load().items.first?.version, task.version)
        m.taskRPC = { _, _, _ in .object(["protocol_version": .number(1), "revision": .number(0), "items": .array([])]) }
        await m.syncTasks(); XCTAssertNotNil(m.taskError); XCTAssertEqual(m.taskDocument.items.count, 1)
    }
}

extension TaskDomainPhaseOneTests {
    func testSaveTaskWrapperIntentChoiceAndOmissionPreserveProvenance() async throws {
        let m = model(); await m.loadCalendars()
        try await m.saveTask(["token": m.tasksToken, "title": "Fictional tasks-only report", "dueDate": "2026-11-10", "calendarIntent": "none"])
        var task = m.taskDocument.items[0]
        XCTAssertEqual(task.calendarIntent, CalshotTaskCalendarIntent.none); XCTAssertEqual(task.intentProvenance, .explicit)
        XCTAssertTrue(m.calendarActions.proposals.isEmpty)
        try await m.saveTask(["token": m.tasksToken, "taskID": task.id.uuidString, "title": task.title, "dueDate": "2026-11-11"])
        task = m.taskDocument.items[0]
        XCTAssertEqual(task.calendarIntent, CalshotTaskCalendarIntent.none); XCTAssertEqual(task.intentProvenance, .explicit)
        XCTAssertTrue(m.calendarActions.proposals.isEmpty)
        var doc = m.taskDocument; var copy = task.conflictCopy(); copy.dueDate = nil; doc.items.append(copy); try m.persistTasks(doc)
        try await m.saveTask(["token": m.tasksToken, "taskID": copy.id.uuidString, "title": copy.title, "dueDate": "2026-11-12"])
        XCTAssertEqual(m.taskDocument.items[1].intentProvenance, .suppressed); XCTAssertFalse(m.taskDocument.items[1].needsPublication)
        try await m.saveTask(["token": m.tasksToken, "title": "Fictional default inbox"])
        let inbox = m.taskDocument.items[2]
        XCTAssertEqual(inbox.calendarIntent, CalshotTaskCalendarIntent.none); XCTAssertEqual(inbox.intentProvenance, .defaulted)
        try await m.saveTask(["token": m.tasksToken, "taskID": inbox.id.uuidString, "title": inbox.title, "dueDate": "2026-11-13", "calendarID": "demo"])
        XCTAssertEqual(m.taskDocument.items[2].calendarIntent, .new); XCTAssertEqual(m.taskDocument.items[2].intentProvenance, .defaulted)
        XCTAssertEqual(m.calendarActions.proposals.count, 1)
        let events = try await m.calendarService.searchEvents(query: nil, start: .distantPast, end: .distantFuture, in: .resolve(identifier: "demo"))
        XCTAssertTrue(events.isEmpty)
    }
    func testSaveTaskWrapperRejectsInvalidIntentAndOwnedTransitions() async throws {
        let m = model()
        for value: Any in ["existing", "invalid", NSNull(), NSNumber(value: true)] {
            do { try await m.saveTask(["token": m.tasksToken, "title": "Fictional invalid", "calendarIntent": value]); XCTFail("Invalid intent accepted") } catch {}
        }
        XCTAssertTrue(m.taskDocument.items.isEmpty)
        var task = CalshotTask(title: "Fictional owned", dueDate: "2026-11-10")
        task.receipt = .init(destinationID: "demo", calendarName: "Fictional", eventIdentifier: "fixture-owned", savedAt: .now)
        task.receiptDeviceID = CalshotModel.syncDeviceID
        try m.persistTasks(.init(items: [task]))
        do { try await m.saveTask(["token": m.tasksToken, "taskID": task.id.uuidString, "title": task.title, "calendarIntent": "none"]); XCTFail("Owned publication detached") } catch {}
        XCTAssertNotNil(m.taskDocument.items[0].receipt)
        let service = TaskLinkFixtureService(), linkedModel = model(service); await linkedModel.loadCalendars()
        _ = try await linkedModel.linkExistingEvent(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: CalshotModel.taskSourceFingerprint(service.snapshot), context: linkedModel.taskContext(origin: .workspace), operationID: UUID())
        let linked = linkedModel.taskDocument.items[0]
        do { try await linkedModel.saveTask(["token": linkedModel.tasksToken, "taskID": linked.id.uuidString, "title": linked.title, "calendarIntent": "none"]); XCTFail("Source detached by intent selector") } catch {}
        XCTAssertNotNil(linkedModel.taskDocument.items[0].sourceLink); XCTAssertEqual(service.writes, 0)
    }
}

extension TaskDomainPhaseOneTests {
    func testRecurringLinkUsesOriginalAnchorAndFingerprintDetectsMetadataChanges() async throws {
        let service = TaskLinkFixtureService(); service.snapshot.isRecurring = true
        service.snapshot.recurrenceDate = "2026-11-01"
        let m = model(service); await m.loadCalendars()
        let context = try m.taskContext(origin: .workspace)
        let fingerprint = try CalshotModel.taskSourceFingerprint(service.snapshot)
        let first = try await m.linkExistingEvent(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: fingerprint, context: context, operationID: UUID())
        service.snapshot.start = service.snapshot.start.addingTimeInterval(86400)
        service.snapshot.end = service.snapshot.end.addingTimeInterval(86400)
        service.snapshot.modifiedAt = Date(timeIntervalSince1970: 1_800_000_000.123)
        XCTAssertNotEqual(try CalshotModel.taskSourceFingerprint(service.snapshot), fingerprint)
        let moved = try await m.linkExistingEvent(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: CalshotModel.taskSourceFingerprint(service.snapshot), context: context, operationID: UUID())
        XCTAssertEqual(moved.taskID, first.taskID)
        service.snapshot.recurrenceDate = "2026-11-08"
        let next = try await m.linkExistingEvent(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: CalshotModel.taskSourceFingerprint(service.snapshot), context: context, operationID: UUID())
        XCTAssertNotEqual(next.taskID, first.taskID); XCTAssertEqual(m.taskDocument.items.count, 2)
        service.snapshot.recurrenceDate = nil
        do { _ = try await m.linkExistingEvent(snapshot: service.snapshot, destinationID: "fictional-readonly", expectedFingerprint: CalshotModel.taskSourceFingerprint(service.snapshot), context: context, operationID: UUID()); XCTFail("Unknown recurrence identity accepted") } catch {}
        XCTAssertEqual(m.taskDocument.items.count, 2); XCTAssertEqual(service.writes, 0)
    }
}


extension TaskDomainPhaseOneTests {
    func testAgentTaskImportNullCalendarIntentUsesNativeDefault() async throws {
        let m = model(); await m.loadCalendars()
        m.currentMemoryRecordID = try m.memoryStore.recordCommand("Fictional default intent").id
        let result = try m.createAgentTasks(["calendarIdentifier": .string("demo"), "tasks": .array([.object([
            "title": .string("Fictional dated report"), "dueDate": .string("2026-11-10"),
            "yearResolved": .bool(true), "sourceText": .string("Fictional report"), "calendarIntent": .null
        ])])])
        XCTAssertEqual(result.proposals.count, 1)
        XCTAssertEqual(m.taskImport?.items.first?.calendarIntent, .new)
        XCTAssertEqual(m.taskImport?.items.first?.intentProvenance, .defaulted)
        XCTAssertTrue(m.taskDocument.items.isEmpty)
    }
}

extension TaskDomainPhaseOneTests {
    private func ownedReceipt(destination: String = "demo") -> CalendarActionReceipt {
        .init(destinationID: destination, calendarName: "Fictional", eventIdentifier: "fixture-owned", savedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
    private func writeStoreFile(_ m: CalshotModel, _ doc: CalshotTaskDocument) throws {
        try FileManager.default.createDirectory(at: m.taskStore.directory, withIntermediateDirectories: true)
        try CalshotTaskStore.encoder.encode(doc).write(to: m.taskStore.url, options: .atomic)
    }

    func testSettledDeadlineDeletionClearsPublicationMetadataAndTaskStaysEditable() throws {
        let m = model(), receipt = ownedReceipt()
        var task = CalshotTask(title: "Fictional published report")
        task.receipt = receipt; task.receiptDeviceID = CalshotModel.syncDeviceID; task.publishedFingerprint = "previous"
        task.resolveCalendarIntent()
        XCTAssertEqual(task.resolvedCalendarIntent, .new)
        try m.persistTasks(.init(items: [task]))
        var proposal = try task.deadline(owner: nil, deviceID: CalshotModel.syncDeviceID)
        XCTAssertEqual(proposal.operation, .delete)
        proposal.state = .deleted; proposal.receipt = receipt
        try m.reconcileTaskReceipts([proposal])
        let settled = m.taskDocument.items[0]
        XCTAssertNil(settled.receipt); XCTAssertNil(settled.receiptDeviceID); XCTAssertNil(settled.publishedFingerprint)
        XCTAssertFalse(settled.needsPublication)
        // The next edit resolves the defaulted undated task to none and must still validate and persist.
        let saved = try m.mutateTask(taskID: settled.id, expectedVersion: settled.version, patch: ["notes": .string("Task only")], context: m.taskContext(origin: .workspace), operationID: UUID())
        XCTAssertEqual(m.taskDocument.items[0].calendarIntent, CalshotTaskCalendarIntent.none)
        let reloaded = try m.taskStore.load().items[0]
        XCTAssertEqual(reloaded.version, saved.taskVersion)
        XCTAssertNil(reloaded.receiptDeviceID); XCTAssertNil(reloaded.publishedFingerprint); XCTAssertNil(reloaded.receipt)
        // A dated deadline that is published and updated keeps its metadata.
        var active = CalshotTask(title: "Fictional active report", dueDate: "2026-11-10"); active.calendarID = "demo"
        active.receipt = receipt; active.receiptDeviceID = CalshotModel.syncDeviceID
        var update = try active.deadline(owner: nil, deviceID: CalshotModel.syncDeviceID)
        XCTAssertEqual(update.operation, .update)
        update.state = .updated; update.receipt = receipt
        try m.persistTasks(.init(items: [active]))
        try m.reconcileTaskReceipts([update])
        XCTAssertNotNil(m.taskDocument.items[0].receiptDeviceID); XCTAssertNotNil(m.taskDocument.items[0].publishedFingerprint)
    }

    func testLegacyStalePublicationMetadataIsNormalizedBeforeValidationWithoutLosingEvidence() throws {
        // Undated defaulted task left with metadata after a settled deletion: normalized, not wedged.
        var stale = CalshotTask(title: "Fictional stale metadata")
        stale.receiptDeviceID = "other-device"; stale.publishedFingerprint = "previous"
        XCTAssertThrowsError(try model().taskStore.save(.init(items: [stale])), "Non-new intent must not persist publication metadata")
        let m = model(); try writeStoreFile(m, .init(items: [stale]))
        let before = stale.version
        var loaded = try m.taskStore.load().items[0]
        XCTAssertEqual(loaded.calendarIntent, CalshotTaskCalendarIntent.none); XCTAssertEqual(loaded.intentProvenance, .defaulted)
        XCTAssertNil(loaded.receiptDeviceID); XCTAssertNil(loaded.publishedFingerprint); XCTAssertEqual(loaded.version, before)
        try m.persistTasks(.init(items: [loaded])); loaded = try m.taskStore.load().items[0]
        XCTAssertNil(loaded.publishedFingerprint)
        // Explicit task-only intent and suppressed copies are normalized the same way.
        var explicit = stale; explicit.id = UUID(); explicit.dueDate = "2026-11-10"
        explicit.calendarIntent = CalshotTaskCalendarIntent.none; explicit.intentProvenance = .explicit
        var legacyCopy = stale; legacyCopy.id = UUID(); legacyCopy.calendarError = "Local copy kept after a sync conflict. Choose Publish explicitly to add a deadline."
        let m2 = model(); try writeStoreFile(m2, .init(items: [explicit, legacyCopy]))
        for task in try m2.taskStore.load().items { XCTAssertNil(task.publishedFingerprint); XCTAssertNil(task.receiptDeviceID) }
        // Pending dated publication keeps its fingerprint; a legacy receipt stays recovery evidence.
        var pending = CalshotTask(title: "Fictional pending report", dueDate: "2026-11-10"); pending.publishedFingerprint = "older"
        var owned = CalshotTask(title: "Fictional owned report"); owned.receipt = ownedReceipt(); owned.receiptDeviceID = "source-mac"; owned.publishedFingerprint = "published"
        let m3 = model(); try writeStoreFile(m3, .init(items: [pending, owned]))
        let kept = try m3.taskStore.load().items
        XCTAssertEqual(kept[0].publishedFingerprint, "older"); XCTAssertTrue(kept[0].needsPublication)
        XCTAssertNotNil(kept[1].receipt); XCTAssertEqual(kept[1].receiptDeviceID, "source-mac"); XCTAssertEqual(kept[1].publishedFingerprint, "published")
        // A receipt contradicting a non-new intent is never erased: the file is rejected and left untouched.
        var contradiction = owned; contradiction.id = UUID()
        contradiction.calendarIntent = CalshotTaskCalendarIntent.none; contradiction.intentProvenance = .explicit
        let m4 = model(); try writeStoreFile(m4, .init(items: [contradiction]))
        let bytes = try Data(contentsOf: m4.taskStore.url)
        XCTAssertThrowsError(try m4.taskStore.load()); XCTAssertEqual(try Data(contentsOf: m4.taskStore.url), bytes)
        // Sync-validated cloud copies get the same treatment.
        var viaIntent = CalshotTask(title: "Fictional detached"); viaIntent.calendarIntent = CalshotTaskCalendarIntent.none; viaIntent.intentProvenance = .explicit
        viaIntent.publishedFingerprint = "previous"; XCTAssertThrowsError(try viaIntent.validate())
        viaIntent.normalizeUnownedPublicationMetadata(); XCTAssertNoThrow(try viaIntent.validate())
    }

    func testTaskOnlyCompleteAndArchiveNeedNoWritableCalendarAndPreserveDestination() throws {
        let service = TaskLinkFixtureService(), m = model(service)   // no calendars loaded: every destination is unavailable here
        let context = try m.taskContext(origin: .workspace)
        var foreign = CalshotTask(title: "Fictional foreign deadline", dueDate: "2026-11-10"); foreign.calendarID = "elsewhere"; foreign.calendarName = "Fictional elsewhere"
        foreign.receipt = ownedReceipt(destination: "elsewhere"); foreign.receiptDeviceID = "source-mac"; foreign.publishedFingerprint = foreign.fingerprint
        var unpublished = CalshotTask(title: "Fictional unpublished deadline", dueDate: "2026-11-11", rank: 1); unpublished.calendarID = "gone"; unpublished.calendarName = "Fictional gone"
        try m.persistTasks(.init(items: [foreign, unpublished]))
        for original in [foreign, unpublished] {
            var version = original.version
            for patch: [String: JSONValue] in [["completed": .bool(true)], ["archived": .bool(true)], ["completed": .bool(false), "archived": .bool(false)]] {
                version = try m.mutateTask(taskID: original.id, expectedVersion: version, patch: patch, context: context, operationID: UUID()).taskVersion
            }
            let now = m.taskDocument.items.first { $0.id == original.id }!
            XCTAssertEqual(now.calendarID, original.calendarID); XCTAssertEqual(now.calendarName, original.calendarName)
            XCTAssertEqual(now.receipt?.eventIdentifier, original.receipt?.eventIdentifier); XCTAssertEqual(now.receiptDeviceID, original.receiptDeviceID)
            XCTAssertEqual(now.publishedFingerprint, original.publishedFingerprint)
            XCTAssertEqual(now.version, version)
        }
        // Publication-relevant edits still refuse: foreign receipts belong to their source Mac, and an
        // unpublished deadline still needs a writable destination.
        for task in m.taskDocument.items {
            XCTAssertThrowsError(try m.mutateTask(taskID: task.id, expectedVersion: task.version, patch: ["notes": .string("Changed")], context: context, operationID: UUID()))
        }
        XCTAssertEqual(m.taskDocument.items.map(\.notes), ["", ""])
        // A new dated task has no destination yet, so it cannot be created unpublishable.
        XCTAssertThrowsError(try m.mutateTask(taskID: nil, expectedVersion: nil, patch: ["title": .string("Fictional new"), "dueDate": .string("2026-11-12")], context: context, operationID: UUID()))
        XCTAssertEqual(m.taskDocument.items.count, 2); XCTAssertTrue(m.calendarActions.proposals.isEmpty); XCTAssertEqual(service.writes, 0)
    }

    func testOperationLedgerHasNoCountCapAndOldOperationsStayIdempotent() throws {
        let m = model(); var context = try m.taskContext(origin: .workspace)
        let firstOp = UUID(), firstPatch: [String: JSONValue] = ["title": .string("Fictional first task")]
        let first = try m.mutateTask(taskID: nil, expectedVersion: nil, patch: firstPatch, context: context, operationID: firstOp)
        var doc = m.taskDocument
        doc.operations = (doc.operations ?? []) + (1..<10_000).map { _ in CalshotTaskOperationReceipt(operationID: UUID(), requestDigest: String(repeating: "a", count: 64), taskID: first.taskID, taskVersion: first.taskVersion, outcome: "saved", savedAt: .now) }
        XCTAssertEqual(doc.operations?.count, 10_000)
        try m.persistTasks(doc)
        let second = try m.mutateTask(taskID: nil, expectedVersion: nil, patch: ["title": .string("Fictional second task")], context: context, operationID: UUID())
        XCTAssertEqual(m.taskDocument.operations?.count, 10_001); XCTAssertEqual(try m.taskStore.load().operations?.count, 10_001)
        m.loadTasks(); context = try m.taskContext(origin: .workspace)
        XCTAssertEqual(m.taskDocument.operations?.count, 10_001); XCTAssertEqual(m.taskDocument.items.count, 2)
        // The oldest operation still returns its original receipt and creates nothing.
        let replay = try m.mutateTask(taskID: nil, expectedVersion: nil, patch: firstPatch, context: context, operationID: firstOp)
        // savedAt is compared separately: the persisted ISO-8601 form drops sub-second precision.
        XCTAssertEqual([replay.operationID, replay.taskID, replay.taskVersion], [first.operationID, first.taskID, first.taskVersion])
        XCTAssertEqual(replay.requestDigest, first.requestDigest); XCTAssertEqual(replay.outcome, first.outcome)
        XCTAssertEqual(replay.savedAt.timeIntervalSince(first.savedAt), 0, accuracy: 1)
        XCTAssertEqual(m.taskDocument.items.count, 2); XCTAssertEqual(m.taskDocument.operations?.count, 10_001)
        XCTAssertThrowsError(try m.mutateTask(taskID: nil, expectedVersion: nil, patch: ["title": .string("Different")], context: context, operationID: firstOp))
        XCTAssertEqual(second.taskID, m.taskDocument.items[1].id)
        // Corruption is still rejected: duplicate IDs on save and on load, and malformed receipts.
        var duplicate = m.taskDocument; duplicate.operations = (duplicate.operations ?? []) + [duplicate.operations![0]]
        XCTAssertThrowsError(try m.taskStore.save(duplicate))
        let m2 = model(); try writeStoreFile(m2, duplicate); XCTAssertThrowsError(try m2.taskStore.load())
        var malformed = m.taskDocument; malformed.operations![0] = CalshotTaskOperationReceipt(operationID: UUID(), requestDigest: "short", taskID: first.taskID, taskVersion: first.taskVersion, outcome: "saved", savedAt: .now)
        XCTAssertThrowsError(try m.taskStore.save(malformed))
    }
}
