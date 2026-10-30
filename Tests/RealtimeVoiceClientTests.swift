import XCTest
@testable import Calshot

@MainActor
private final class FakeRealtimeTransport: RealtimeTransport {
    var sent: [[String: Any]] = []
    var url: URL?
    var authorized = false
    var connectError: Error?
    var continuation: AsyncThrowingStream<String, Error>.Continuation?
    func connect(url: URL, headers: [String: String]) async throws {
        self.url = url; authorized = headers["Authorization"] == "Bearer fictional-test-key"
        if let connectError { throw connectError }
    }
    func send(text: String) async throws { sent.append(try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]) }
    func receive() -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { continuation = $0 } }
    func close() { continuation?.finish(); continuation = nil }
    func emit(_ json: [String: Any]) { continuation?.yield(String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self)) }
}

@MainActor
final class RealtimeVoiceClientTests: XCTestCase {
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        XCTFail("Asynchronous condition did not settle", file: file, line: line)
    }
    private func ready(_ fake: FakeRealtimeTransport) async -> RealtimeVoiceClient {
        let client = RealtimeVoiceClient(apiKey: { "fictional-test-key" }, transportFactory: { fake })
        client.connect(configuration: .init(instructions: "Use fictional data"))
        await settle { fake.continuation != nil }
        fake.emit(["type": RealtimeWire.sessionUpdated.rawValue])
        await settle { client.state == .ready }
        return client
    }
    func testPushToTalkDisablesServerTurnDetectionAndInterruptCancelsAudibleReply() async throws {
        let fake = FakeRealtimeTransport()
        let client = RealtimeVoiceClient(apiKey: { "fictional-test-key" }, transportFactory: { fake })
        client.connect(configuration: .init(instructions: "Fictional", pushToTalk: true))
        await settle { !fake.sent.isEmpty }
        let input = ((fake.sent.first?["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"] as? [String: Any]
        XCTAssertTrue(input?["turn_detection"] is NSNull)
        fake.emit(["type": RealtimeWire.sessionUpdated.rawValue]); await settle { client.state == .ready }
        try await client.interrupt(); XCTAssertFalse(fake.sent.contains { $0["type"] as? String == "response.cancel" }, "Nothing to cancel when idle")
        var flushed = 0; client.flushAudio = { flushed += 1; return 250 }
        try await client.requestResponse(); fake.emit(["type": "response.created"])
        fake.emit(["type": "response.output_audio.delta", "item_id": "fictional-item", "delta": "AAA="])
        await settle { client.state == .responding && client.audioOutputSeconds > 0 }
        try await client.interrupt()
        XCTAssertEqual(flushed, 1)
        XCTAssertTrue(fake.sent.contains { $0["type"] as? String == "response.cancel" })
        XCTAssertEqual(fake.sent.last?["audio_end_ms"] as? Int, 250)
        fake.emit(["type": "error", "error": ["code": "response_cancel_not_active"]])
        fake.emit(["type": "error", "error": ["code": "input_audio_buffer_commit_empty"]])
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNotNil(fake.continuation, "Push-to-talk races never end the session"); client.disconnect()
    }
    func testConcurrentResponsesCoalesceAndActiveResponseErrorIsNonfatal() async throws {
        let fake = FakeRealtimeTransport(), client = await ready(fake)
        try await client.requestResponse(); try await client.requestResponse(); try await client.sendText("Fictional review")
        XCTAssertEqual(fake.sent.filter { $0["type"] as? String == "response.create" }.count, 1)
        fake.emit(["type": "response.created"])
        fake.emit(["type": "error", "error": ["code": "conversation_already_has_active_response"]])
        fake.emit(["type": "response.done", "response": ["id": "one", "status": "completed"]])
        await settle { fake.sent.filter { $0["type"] as? String == "response.create" }.count == 2 }
        XCTAssertNotNil(fake.continuation); XCTAssertNotEqual(client.state, .failed("")); client.disconnect()
    }
    func testSessionConfigurationAndAuthentication() async throws {
        let fake = FakeRealtimeTransport()
        let tool: JSONValue = .object(["type": .string("function"), "name": .string("fictional_lookup"), "strict": .bool(true), "parameters": .object(["type": .string("object")])])
        let client = RealtimeVoiceClient(apiKey: { "fictional-test-key" }, transportFactory: { fake })
        client.connect(configuration: .init(model: "fictional-model", instructions: "Fictional instructions", voice: "cedar", tools: [tool]))
        await settle { !fake.sent.isEmpty }
        XCTAssertTrue(fake.authorized)
        XCTAssertEqual(URLComponents(url: fake.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "fictional-model")
        let s = try XCTUnwrap(fake.sent.first?["session"] as? [String: Any])
        XCTAssertEqual(s["model"] as? String, "fictional-model")
        XCTAssertEqual(s["instructions"] as? String, "Fictional instructions")
        XCTAssertEqual(s["tool_choice"] as? String, "auto")
        XCTAssertEqual((s["tools"] as? [[String: Any]])?.first?["name"] as? String, "fictional_lookup")
        XCTAssertEqual(Set((s["tools"] as? [[String: Any]])?.first?.keys.map { $0 } ?? []), ["type", "name", "parameters"], "Realtime rejects text-agent tool fields such as strict")
        for agentTool in CalendarAgent.tools { XCTAssertNil(RealtimeVoiceClient.realtimeTool(agentTool)?["strict"]) }
        let audio = try XCTUnwrap(s["audio"] as? [String: [String: Any]])
        XCTAssertEqual(audio["output"]?["voice"] as? String, "cedar")
        for side in ["input", "output"] {
            let format = audio[side]?["format"] as? [String: Any]
            XCTAssertEqual(format?["type"] as? String, "audio/pcm"); XCTAssertEqual(format?["rate"] as? Int, 24000)
        }
        XCTAssertNotNil(audio["input"]?["transcription"])
        XCTAssertEqual((audio["input"]?["turn_detection"] as? [String: Any])?["type"] as? String, "server_vad")
        client.disconnect()
    }
    func testAudioAndBufferCommands() async throws {
        let fake = FakeRealtimeTransport(), pcm = Data([1, 2, 3, 4])
        let client = await ready(fake)
        try await client.appendAudio(pcm); try await client.commitInputBuffer(); try await client.clearInputBuffer()
        XCTAssertEqual(fake.sent[1]["audio"] as? String, pcm.base64EncodedString())
        XCTAssertEqual(fake.sent.suffix(3).compactMap { $0["type"] as? String }, [RealtimeWire.append.rawValue, RealtimeWire.commit.rawValue, RealtimeWire.clear.rawValue])
        XCTAssertEqual(client.audioInputSeconds, 4.0 / 48000, accuracy: 0.000001)
        do { try await client.appendAudio(Data([1])); XCTFail() } catch { XCTAssertEqual(error as? RealtimeConnectionError, .invalidFrame) }
        client.disconnect()
    }
    func testImageAndTextShapes() async throws {
        let fake = FakeRealtimeTransport(), client = await ready(fake)
        try await client.sendImage(jpeg: Data([255, 216]), caption: "Fictional screen")
        let item = fake.sent[1]["item"] as! [String: Any], parts = item["content"] as! [[String: String]]
        XCTAssertEqual(item["role"] as? String, "user")
        XCTAssertEqual(parts, [["type": "input_text", "text": "Fictional screen"], ["type": "input_image", "image_url": "data:image/jpeg;base64,/9g="]])
        try await client.sendText("Fictional question")
        XCTAssertEqual(fake.sent.last?["type"] as? String, RealtimeWire.responseCreate.rawValue)
        client.disconnect()
    }
    func testToolCallResultSequence() async throws {
        let fake = FakeRealtimeTransport(), client = await ready(fake)
        var call: RealtimeVoiceEvent?
        client.onEvent = { if case .functionCall = $0 { call = $0 } }
        fake.emit(["type": RealtimeWire.functionDone.rawValue, "call_id": "fictional-call", "name": "fictional_lookup", "arguments": "{}"])
        fake.emit(["type": RealtimeWire.responseDone.rawValue, "response": ["id": "fictional-response", "status": "completed"]])
        await settle { call != nil }
        XCTAssertEqual(call, .functionCall(callID: "fictional-call", name: "fictional_lookup", argumentsJSON: "{}"))
        try await client.sendToolResult(callID: "fictional-call", outputJSON: "{\"found\":true}")
        let item = fake.sent[1]["item"] as! [String: String]
        XCTAssertEqual(item, ["type": "function_call_output", "call_id": "fictional-call", "output": "{\"found\":true}"])
        XCTAssertEqual(fake.sent[2]["type"] as? String, RealtimeWire.responseCreate.rawValue)
        client.disconnect()
    }
    func testBargeInFlushesAndTruncatesRenderedDuration() async throws {
        let fake = FakeRealtimeTransport(), client = await ready(fake)
        var flushed = 0, audioEvents = 0
        client.isAudioPlaying = { true }; client.flushAudio = { flushed += 1; return 347 }
        client.onEvent = { if case .audio = $0 { audioEvents += 1 } }
        fake.emit(["type": RealtimeWire.audioDelta.rawValue, "item_id": "fictional-item", "content_index": 2, "delta": "AAA="])
        await settle { audioEvents == 1 }
        fake.emit(["type": RealtimeWire.speechStarted.rawValue])
        await settle { fake.sent.count == 3 }
        XCTAssertEqual(flushed, 1)
        XCTAssertEqual(fake.sent[1]["type"] as? String, RealtimeWire.cancel.rawValue)
        XCTAssertEqual(fake.sent[2]["type"] as? String, RealtimeWire.truncate.rawValue)
        XCTAssertEqual(fake.sent[2]["audio_end_ms"] as? Int, 347)
        XCTAssertEqual(fake.sent[2]["item_id"] as? String, "fictional-item")
        XCTAssertEqual(fake.sent[2]["content_index"] as? Int, 2)
        fake.emit(["type": RealtimeWire.audioDelta.rawValue, "delta": "AAA="])
        for _ in 0..<30 { await Task.yield() }; XCTAssertEqual(audioEvents, 1)
        client.disconnect()
    }
    func testEveryMappedEventDecodes() throws {
        let fixtures: [(RealtimeWire, RealtimeVoiceEvent)] = [
            (.sessionCreated, .sessionCreated), (.sessionUpdated, .sessionUpdated), (.responseCreated, .responseCreated),
            (.speechStarted, .speechStarted), (.speechStopped, .speechStopped), (.audioDone, .audioDone),
            (.userDelta, .userTranscript(itemID: "i", text: "d", final: false)),
            (.userFinal, .userTranscript(itemID: "i", text: "t", final: true)),
            (.assistantDelta, .assistantTranscript(itemID: "i", text: "d", final: false)),
            (.assistantDone, .assistantTranscript(itemID: "i", text: "t", final: true)),
            (.functionDone, .functionCall(callID: "c", name: "f", argumentsJSON: "{}")),
            (.responseDone, .responseDone(id: "", status: "", usage: .init())),
            (.rateLimits, .rateLimits(.array([]))),
            (.error, .error(code: "service_error", message: "Voice could not complete the request. Try again.")),
            (.transcriptionFailed, .unknown(RealtimeWire.transcriptionFailed.rawValue))]
        for (wire, expected) in fixtures {
            let json: [String: Any] = ["type": wire.rawValue, "item_id": "i", "delta": "d", "transcript": "t", "call_id": "c", "name": "f", "arguments": "{}"]
            XCTAssertEqual(try RealtimeVoiceEvent.decode(String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self)), expected)
        }
        XCTAssertEqual(try RealtimeVoiceEvent.decode("{\"type\":\"response.output_audio.delta\",\"item_id\":\"i\",\"delta\":\"AAA=\"}"), .audio(itemID: "i", contentIndex: 0, data: Data([0, 0])))
        XCTAssertEqual(try RealtimeVoiceEvent.decode("{\"type\":\"future.event\"}"), .unknown("future.event"))
        XCTAssertThrowsError(try RealtimeVoiceEvent.decode("{}"))
        XCTAssertThrowsError(try RealtimeVoiceEvent.decode("{\"type\":\"response.output_audio.delta\",\"delta\":\"!\"}"))
        let serverTypes = Set(fixtures.map(\.0)).union([.audioDelta])
        for wire in RealtimeWire.allCases where !serverTypes.contains(wire) {
            XCTAssertEqual(try RealtimeVoiceEvent.decode("{\"type\":\"\(wire.rawValue)\"}"), .unknown(wire.rawValue))
        }
    }
    func testReconnectBoundedExponentialBackoff() async {
        var attempts = 0, delays: [Double] = []
        let client = RealtimeVoiceClient(apiKey: { "fictional-test-key" }, transportFactory: {
            attempts += 1; let fake = FakeRealtimeTransport(); fake.connectError = RealtimeConnectionError.unavailable; return fake
        }, sleep: { delays.append($0) })
        client.connect(configuration: .init(instructions: ""))
        await settle { if case .failed = client.state { return true }; return false }
        XCTAssertEqual(attempts, 4); XCTAssertEqual(delays, [1, 2, 4]); XCTAssertEqual(client.reconnectAttempt, 3)
        client.disconnect()
    }
    func testAuthenticationAndQuotaNeverRetry() async {
        for failure in [RealtimeConnectionError.authentication, .quota] {
            var attempts = 0
            let client = RealtimeVoiceClient(apiKey: { "fictional-test-key" }, transportFactory: {
                attempts += 1; let f = FakeRealtimeTransport(); f.connectError = failure; return f
            }, sleep: { _ in XCTFail("Terminal failure retried") })
            client.connect(configuration: .init(instructions: ""))
            await settle { client.state == .failed(failure.description) }
            XCTAssertEqual(attempts, 1); client.disconnect()
        }
    }
    func testServerAuthenticationAndQuotaNeverRetry() async {
        for code in ["invalid_api_key", "insufficient_quota"] {
            let fake = FakeRealtimeTransport(), client = await ready(fake)
            fake.emit(["type": RealtimeWire.error.rawValue, "error": ["code": code, "message": "fictional-test-key"]])
            await settle { if case .failed = client.state { return true }; return false }
            XCTAssertEqual(client.reconnectAttempt, 0); client.disconnect()
        }
    }
    func testUnexpectedCloseReconnectAndDisconnectInvalidatesEvents() async {
        var sockets: [FakeRealtimeTransport] = []
        let client = RealtimeVoiceClient(apiKey: { "fictional-test-key" }, transportFactory: {
            let f = FakeRealtimeTransport(); sockets.append(f); return f
        }, sleep: { _ in })
        var resets = 0; client.onReconnect = { resets += 1 }
        client.connect(configuration: .init(instructions: ""))
        await settle { sockets.first?.continuation != nil }
        sockets[0].continuation?.finish()
        await settle { sockets.count == 2 && sockets[1].continuation != nil }
        XCTAssertEqual(resets, 1)
        client.disconnect(); sockets[1].emit(["type": RealtimeWire.sessionUpdated.rawValue])
        for _ in 0..<30 { await Task.yield() }; XCTAssertEqual(client.state, .disconnected)
    }
    func testUsageCostAndDuplicateResponse() async throws {
        let fake = FakeRealtimeTransport(), client = await ready(fake)
        try await client.appendAudio(Data(count: 48000))
        fake.emit(["type": RealtimeWire.audioDelta.rawValue, "delta": Data(count: 24000).base64EncodedString()])
        let done: [String: Any] = ["type": RealtimeWire.responseDone.rawValue, "response": ["id": "fictional-response", "status": "completed", "usage": ["input_tokens": 1000, "output_tokens": 200, "input_token_details": ["audio_tokens": 600, "image_tokens": 100, "cached_tokens_details": ["text_tokens": 100, "audio_tokens": 200, "image_tokens": 50]], "output_token_details": ["audio_tokens": 100]]]]
        fake.emit(done); fake.emit(done)
        await settle { client.tokens.input == 1000 }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(client.audioInputSeconds, 1); XCTAssertEqual(client.audioOutputSeconds, 0.5)
        XCTAssertEqual(client.tokens.output, 200)
        let expected = 0.022795 // $22,795 per million of this mixed token bundle.
        XCTAssertEqual(client.estimatedCost, expected, accuracy: 0.0000001)
        var prices = RealtimePrices(); prices.audioInput = 0
        XCTAssertLessThan(prices.estimate(client.tokens), client.estimatedCost)
        client.disconnect()
    }
    func testCredentialsNeverAppearInDescriptionsOrErrors() async throws {
        let fake = FakeRealtimeTransport(), client = await ready(fake)
        XCTAssertFalse(String(describing: client).contains("fictional-test-key"))
        XCTAssertFalse(String(reflecting: client).contains("fictional-test-key"))
        let event = try RealtimeVoiceEvent.decode("{\"type\":\"error\",\"error\":{\"code\":\"fictional-test-key\",\"message\":\"fictional-test-key\"}}")
        XCTAssertFalse(String(describing: event).contains("fictional-test-key"))
        for error in [RealtimeConnectionError.authentication, .quota, .unavailable, .invalidFrame, .notReady] {
            XCTAssertFalse(error.description.contains("fictional-test-key"))
        }
        client.disconnect()
    }
    func testCancelledResponseNeverDeliversToolCalls() async {
        let fake = FakeRealtimeTransport(), client = await ready(fake)
        var calls = 0, completed = false
        client.onEvent = {
            if case .functionCall = $0 { calls += 1 }
            if case .responseDone = $0 { completed = true }
        }
        fake.emit(["type": RealtimeWire.functionDone.rawValue, "call_id": "cancelled-call", "name": "fictional_tool", "arguments": "{}"])
        fake.emit(["type": RealtimeWire.responseDone.rawValue, "response": ["id": "cancelled-response", "status": "cancelled"]])
        await settle { completed }
        XCTAssertEqual(calls, 0); client.disconnect()
    }
    func testMissingKeyDoesNotOpenTransport() async {
        var opened = false
        let client = RealtimeVoiceClient(apiKey: { "" }, transportFactory: { opened = true; return FakeRealtimeTransport() })
        client.connect(configuration: .init(instructions: ""))
        await settle { client.state == .failed(RealtimeConnectionError.authentication.description) }
        XCTAssertFalse(opened); XCTAssertEqual(client.reconnectAttempt, 0); client.disconnect()
    }
    func testPCMConversionClampingAndEndianness() {
        XCTAssertEqual(VoicePCM.encode([-2, -1, 0, 1, 2, .nan, .infinity]), Data([0, 128, 0, 128, 0, 0, 255, 127, 255, 127, 0, 0, 255, 127]))
        XCTAssertEqual(VoicePCM.decode(Data([0, 128, 0, 0])), [-1, 0])
    }
    func testRMSKnownSignals() {
        XCTAssertEqual(VoicePCM.rms([]), 0); XCTAssertEqual(VoicePCM.rms([0, 0]), 0)
        XCTAssertEqual(VoicePCM.rms([1, -1]), 1)
        XCTAssertEqual(VoicePCM.rms([0.5, -0.5]), 0.5)
        XCTAssertEqual(VoicePCM.rms([0, 1, 0, -1]), sqrt(0.5), accuracy: 0.00001)
    }
    func testResamplingAndChunkBoundaries() {
        XCTAssertEqual(VoicePCM.resamplingRatio(from: 48000), 0.5)
        XCTAssertEqual(VoicePCM.resamplingRatio(from: 44100), 24000.0 / 44100)
        XCTAssertEqual(VoicePCM.resamplingRatio(from: 0), 0)
        XCTAssertEqual(VoicePCM.chunkBytes(milliseconds: 1), 1920)
        XCTAssertEqual(VoicePCM.chunkBytes(milliseconds: 200), 4800)
        var chunker = VoicePCM.Chunker()
        XCTAssertTrue(chunker.append(Data(count: 1000)).isEmpty)
        XCTAssertEqual(chunker.append(Data(count: 5000)).map(\.count), [2880, 2880])
        XCTAssertEqual(chunker.append(Data(count: 2640)).map(\.count), [2880])
    }
    func testPlayedDurationUsesRenderedNotQueuedFrames() {
        XCTAssertEqual(VoicePCM.playedMilliseconds(renderedFrames: 12000, itemStartFrame: 2400, itemFrames: 24000), 400)
        XCTAssertEqual(VoicePCM.playedMilliseconds(renderedFrames: 48000, itemStartFrame: 0, itemFrames: 2400), 100)
        XCTAssertEqual(VoicePCM.playedMilliseconds(renderedFrames: 0, itemStartFrame: 2400, itemFrames: 24000), 0)
    }
    func testAudioEngineInitializationAndStopArePassiveAndIdempotent() {
        let audio = VoiceAudioEngine()
        XCTAssertFalse(audio.isRunning); XCTAssertFalse(audio.isPlaying)
        audio.stop(); audio.stop(); XCTAssertEqual(audio.flush(), 0)
    }
}

@MainActor
final class VoiceSessionIntegrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var client: PreviewVoiceClient!
    private var audio: PreviewVoiceAudio!
    private var overlay: PreviewVoiceOverlay!
    private var frames: PreviewVoiceFrames!
    private func make(microphone: Bool = true, screen: Bool = true) -> VoiceSessionController {
        defaults = UserDefaults(suiteName: "VoiceSessionTests.\(UUID())")!
        defaults.set(2, forKey: "voice.acknowledgementVersion")
        client = PreviewVoiceClient(); audio = PreviewVoiceAudio(); overlay = PreviewVoiceOverlay(); frames = PreviewVoiceFrames()
        let session = VoiceSessionController(client: client, audio: audio, overlay: overlay, frames: frames, defaults: defaults, permission: { microphone }, screenPermission: { screen })
        session.eligible = { true }; session.hasKey = { true }; session.releaseTail = .zero; session.tapThreshold = 0; return session
    }
    /// Holds the talk key, speaks `bytes` of audio and releases.
    private func say(_ s: VoiceSessionController, bytes: Int = 9600) async {
        await s.talk(true); audio.onInput?(Data(count: bytes)); await s.talk(false); await settle()
    }
    private func settle() async { for _ in 0..<50 { await Task.yield() } }
    func testConsentAndUpdatedNoticeGateAndRevokeSession() async {
        let s = make(); s.consent = { false }; await s.toggle()
        XCTAssertNil(client.configuration); XCTAssertTrue(s.error?.contains("OpenAI analysis") == true)
        s.consent = { true }; defaults.set(0, forKey: "voice.acknowledgementVersion"); defaults.set(true, forKey: "voice.billingAcknowledged")
        await s.toggle(); XCTAssertTrue(s.needsAcknowledgement); XCTAssertNil(client.configuration)
        s.acknowledge(); await s.toggle(); XCTAssertTrue(s.active)
        s.consent = { false }; s.tick(now: Date()); XCTAssertFalse(s.active)
    }
    func testInvalidArgumentsAlwaysReturnErrorAndUnchangedTicksDoNotPublish() async {
        let s = make(); await s.toggle(); s.handle(.sessionUpdated)
        s.handle(.functionCall(callID: "bad", name: "recall", argumentsJSON: "{")); await settle()
        XCTAssertEqual(client.results, ["{\"error\":\"invalid arguments\"}"])
        var changes = 0; s.onChange = { changes += 1 }
        s.tick(now: Date()); let baseline = changes
        for _ in 0..<10 { s.tick(now: Date()) }; XCTAssertEqual(changes, baseline); s.stop()
    }
    func testTimedEndPreservesReviewAndReconnectRestoresItWithoutEmptyContext() async {
        let s = make(); var cancelled = 0; s.cancelPending = { cancelled += 1 }; s.waitingForReview = { true }
        await s.toggle(); s.handle(.sessionUpdated); XCTAssertEqual(s.state, .waitingForReview)
        client.onReconnect?(); s.handle(.sessionUpdated); await settle()
        XCTAssertEqual(s.state, .waitingForReview); XCTAssertTrue(client.texts.isEmpty)
        s.tick(now: Date().addingTimeInterval(61)); XCTAssertEqual(cancelled, 0)
        s.stop(); XCTAssertEqual(cancelled, 1)
    }
    func testStateTransitionsAndToggleReleasesMicrophone() async {
        let s = make(); await s.toggle(); XCTAssertEqual(s.state, .connecting)
        s.handle(.sessionUpdated); XCTAssertEqual(s.state, .listening); XCTAssertTrue(audio.running)
        s.handle(.responseCreated); XCTAssertEqual(s.state, .thinking)
        s.handle(.audio(itemID: "fictional", contentIndex: 0, data: Data())); XCTAssertEqual(s.state, .speaking)
        s.review(true); XCTAssertEqual(s.state, .waitingForReview)
        await s.toggle(); XCTAssertEqual(s.state, .ended); XCTAssertFalse(audio.running)
    }
    func testMissingKeyNeverConnects() async {
        let s = make(); s.hasKey = { false }; await s.toggle(); XCTAssertTrue(s.needsKey); XCTAssertNil(client.configuration)
    }
    func testBillingAcknowledgementRequired() async {
        let s = make(); defaults.set(0, forKey: "voice.acknowledgementVersion"); await s.toggle()
        XCTAssertTrue(s.needsAcknowledgement); XCTAssertNil(client.configuration)
        s.acknowledge(); await s.toggle(); XCTAssertEqual(s.state, .connecting); s.stop()
    }
    func testMicrophoneDeniedBlocksStart() async { let s = make(microphone: false); await s.toggle(); XCTAssertEqual(s.state, .failed); XCTAssertNil(client.configuration) }
    func testScreenDeniedContinuesVoiceOnly() async {
        let s = make(screen: false); await s.toggle(); s.handle(.sessionUpdated); await say(s)
        XCTAssertEqual(client.images, 0); XCTAssertEqual(client.commits, 1); XCTAssertEqual(client.responses, 1); XCTAssertNotNil(s.error); s.stop()
    }
    func testExactlyOneFramePerTurnAndNoPeriodicFrames() async {
        let s = make(); await s.toggle(); s.handle(.sessionUpdated)
        s.tick(now: Date().addingTimeInterval(5)); XCTAssertEqual(frames.captures, 0)
        overlay.marks = [FocusMark(kind: .point, points: [.zero], displayID: 1, timestamp: Date())]
        await say(s); XCTAssertEqual(client.images, 1); XCTAssertEqual(frames.captures, 1); XCTAssertTrue(overlay.marks.isEmpty)
        s.tick(now: Date().addingTimeInterval(10)); XCTAssertEqual(frames.captures, 1); s.stop()
    }
    func testDrawingAloneNeverSendsAndMarksRideWithNextTurn() async throws {
        let s = make(); await s.toggle(); s.handle(.sessionUpdated)
        overlay.marks = [FocusMark(kind: .point, points: [.zero], displayID: 1, timestamp: Date())]
        overlay.onMarksChanged?(overlay.marks); await settle()
        XCTAssertEqual(frames.captures, 0); XCTAssertEqual(client.responses, 0)
        await say(s)
        XCTAssertEqual(frames.captures, 1); XCTAssertEqual(client.images, 1); XCTAssertTrue(overlay.marks.isEmpty); s.stop()
    }
    func testPushToTalkSendsAudioOnlyWhileHeld() async {
        let s = make(); await s.toggle(); s.handle(.sessionUpdated)
        XCTAssertTrue(client.configuration?.pushToTalk == true)
        XCTAssertFalse(client.configuration?.tools.contains { $0.objectValue?["name"]?.stringValue == "ask_user" } ?? true)
        XCTAssertTrue(client.configuration?.instructions.contains("Current instant:") == true)
        audio.onInput?(Data(count: 9600)); await settle()
        XCTAssertEqual(client.commits, 0); XCTAssertEqual(client.responses, 0)
        await say(s); XCTAssertEqual(client.commits, 1); XCTAssertEqual(client.responses, 1); XCTAssertEqual(s.state, .thinking); s.stop()
    }
    func testTooShortHoldIsDiscardedAndQuickTapEndsSession() async throws {
        let s = make(); await s.toggle(); s.handle(.sessionUpdated)
        await s.talk(true); audio.onInput?(Data(count: 960)); try await Task.sleep(for: .milliseconds(400)); await s.talk(false); await settle()
        XCTAssertEqual(client.commits, 0); XCTAssertEqual(client.responses, 0); XCTAssertTrue(s.active)
        s.tapThreshold = 0.35; await s.talk(true); await s.talk(false); XCTAssertEqual(s.state, .ended)
    }
    func testPressStartsSessionBuffersSpeechUntilReadyAndInterruptsLaterReplies() async {
        let s = make(); await s.talk(true); XCTAssertTrue(s.active); XCTAssertTrue(s.talking)
        audio.onInput?(Data(count: 9600)); await s.talk(false); await settle()
        XCTAssertEqual(client.commits, 0)
        s.handle(.sessionUpdated); await settle(); XCTAssertEqual(client.commits, 1); XCTAssertEqual(client.responses, 1)
        s.handle(.audio(itemID: "fictional", contentIndex: 0, data: Data())); XCTAssertEqual(s.state, .speaking)
        await s.talk(true); await settle(); XCTAssertEqual(client.interrupts, 1); XCTAssertEqual(s.state, .listening)
        s.stop(); XCTAssertFalse(s.talking)
    }
    func testReleaseDuringStartupLeavesSessionOpenAndIdle() async {
        let s = make(); var release: (() -> Void)?
        let pressed = Task { await s.talk(true) }
        release = { Task { await s.talk(false) } }; release?()
        await pressed.value; await settle()
        XCTAssertFalse(s.talking); await s.talk(true); XCTAssertTrue(s.talking); s.stop()
    }
    func testReconnectSendsTranscriptsAndNeverReplaysTool() async {
        let s = make(); var finish: CheckedContinuation<String, Never>?
        s.execute = { _, _ in await withCheckedContinuation { finish = $0 } }
        await s.toggle(); s.handle(.sessionUpdated)
        s.handle(.functionCall(callID: "old", name: "recall", argumentsJSON: "{}")); await settle()
        XCTAssertNotNil(finish)
        s.handle(.userTranscript(itemID: "fictional", text: "My fictional schedule", final: true))
        client.onReconnect?(); s.handle(.sessionUpdated); finish?.resume(returning: "{\"saved\":true}"); await settle()
        XCTAssertTrue(client.texts.first?.contains("My fictional schedule") == true); XCTAssertTrue(client.results.isEmpty); s.stop()
    }
    func testIdleAndAccountLossEndSession() async {
        let s = make(); await s.toggle(); s.tick(now: Date().addingTimeInterval(61)); XCTAssertEqual(s.state, .ended)
        await s.toggle(); s.eligible = { false }; s.tick(now: Date()); XCTAssertEqual(s.state, .ended)
    }
    func testTenMinuteCapWithActiveTurns() async {
        let s = make(); await s.toggle(); s.handle(.sessionUpdated)
        s.handle(.speechStarted); s.tick(now: Date().addingTimeInterval(601)); XCTAssertEqual(s.state, .ended)
    }
    func testMonthlyCapBlocksNewSession() async {
        let s = make(); defaults.set(0.0, forKey: "voice.cap"); await s.toggle(); XCTAssertEqual(s.state, .failed); XCTAssertNil(client.configuration)
    }
    func testHotkeyRoutingKeepsCaptureVoiceAndEscapeIndependent() {
        let hotkey = HotKeyController.shared
        let oldCapture = hotkey.onPress, oldVoice = hotkey.onVoicePress
        defer { hotkey.onPress = oldCapture; hotkey.onVoicePress = oldVoice }
        var capture = 0, voice = 0
        var released = 0
        hotkey.onPress = { capture += 1 }; hotkey.onVoicePress = { $0 ? (voice += 1) : (released += 1) }
        hotkey.dispatch(id: 1); hotkey.dispatch(id: 1, pressed: false); hotkey.dispatch(id: 2); hotkey.dispatch(id: 2, pressed: false); hotkey.dispatch(id: 3)
        XCTAssertEqual(capture, 1); XCTAssertEqual(voice, 1); XCTAssertEqual(released, 1)
    }
    func testNewSessionInvalidatesControlToken() async { let s = make(); let old = s.token; await s.toggle(); XCTAssertNotEqual(old, s.token); s.stop() }
}
