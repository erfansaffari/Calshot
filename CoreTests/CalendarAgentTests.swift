import XCTest
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
