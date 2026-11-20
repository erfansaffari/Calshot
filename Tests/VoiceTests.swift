import XCTest
import AVFoundation
@testable import Calshot

// MARK: Fakes. None of them opens a socket, plays audio, captures a display or contacts a service.

@MainActor final class FakeVoiceSocket: VoiceSocket {
    var sent: [[String: Any]] = []
    var url: URL?, headers: [String: String] = [:]
    var continuation: AsyncThrowingStream<String, Error>.Continuation?
    var closed = 0
    func connect(url: URL, headers: [String: String]) async throws { self.url = url; self.headers = headers }
    func send(text: String) async throws { sent.append(try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]) }
    func receive() -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { continuation = $0 } }
    func close() { closed += 1; continuation?.finish(); continuation = nil }
    func emit(_ json: [String: Any]) { continuation?.yield(String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self)) }
    var kinds: [String] { sent.map { message in
        if message["setup"] != nil { return "setup" }
        let input = message["realtimeInput"] as? [String: Any] ?? [:]
        return input["activityStart"] != nil ? "start" : input["activityEnd"] != nil ? "end" : input["audio"] != nil ? "audio" : "other"
    } }
}
@MainActor final class FakeVoiceService: VoiceServicing {
    var grants: [[String]] = []
    var grantError: Error?
    var spoken: [(text: String, voice: String)] = []
    /// Per sentence: the chunks it streams. A sentence without an entry streams one 4-byte chunk.
    var audio: [String: [Data]] = [:]
    var speechError: Error?
    /// When set, speech for these sentences waits until released.
    var gates: [String: CheckedContinuation<Void, Never>] = [:]
    var held: Set<String> = []
    func listeningGrant(vocabulary: [String]) async throws -> VoiceListeningGrant {
        grants.append(vocabulary)
        if let grantError { throw grantError }
        return .init(token: "auth_tokens/fictional", url: URL(string: "wss://generativelanguage.googleapis.com/ws/fictional")!, model: "models/gemini-3.5-transcribe-live")
    }
    func speech(_ text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        spoken.append((text, voice))
        let chunks = audio[text] ?? [Data(count: 4)], error = speechError, wait = held.contains(text)
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                if wait { await withCheckedContinuation { self.gates[text] = $0 } }
                if let error { continuation.finish(throwing: error); return }
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        }
    }
    func release(_ text: String) { gates.removeValue(forKey: text)?.resume() }
}
@MainActor final class RecordingVoiceAudio: VoiceAudio {
    var onInput: ((Data) -> Void)?
    var onError: ((VoiceAudioEngine.AudioError) -> Void)?
    var isPlaying = false
    var inputLevel: Float = 0.4, outputLevel: Float = 0
    var played: [(Data, String)] = []
    var flushes = 0
    func start() async throws {}
    func stop() {}
    func flush() -> VoicePlaybackStop { flushes += 1; isPlaying = false; return .init(item: nil, playedMilliseconds: 0) }
    func enqueuePCM16(_ data: Data, itemID: String) throws { played.append((data, itemID)); isPlaying = true }
}
/// A scripted model. Each reply streams `text` then returns `calls`. Every request is recorded.
@MainActor final class ScriptedModelClient: CalendarAgentModelClient {
    struct Reply { var text = ""; var calls: [AgentFunctionCall] = []; var wait = false }
    struct Request { var conversation: [AgentMessage]; var tools: [String]; var options: AgentRequestOptions; var instructions: String }
    var replies: [Reply] = []
    var requests: [Request] = []
    var gate: CheckedContinuation<Void, Never>?
    /// The warm-up request at session start is answered without consuming a scripted reply.
    var answersPrewarm = true
    func turn(conversation: [AgentMessage], imageDataURL: String?, instructions: String, tools: [JSONValue],
              onText: @escaping @MainActor (String) -> Void) async throws -> AgentModelResponse {
        try await turn(conversation: conversation, imageDataURL: imageDataURL, instructions: instructions, tools: tools, options: .init(), onText: onText)
    }
    func turn(conversation: [AgentMessage], imageDataURL: String?, instructions: String, tools: [JSONValue],
              options: AgentRequestOptions, onText: @escaping @MainActor (String) -> Void) async throws -> AgentModelResponse {
        requests.append(.init(conversation: conversation, tools: tools.compactMap { $0.objectValue?["name"]?.stringValue }, options: options, instructions: instructions))
        if answersPrewarm, conversation.last?.value.objectValue?["content"]?.stringValue?.hasPrefix("Native check: the voice session opened") == true {
            return .init(output: [], calls: [], text: "ready", usage: nil)
        }
        guard !replies.isEmpty else { throw CancellationError() }
        let reply = replies.removeFirst()
        if reply.wait { await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        for word in reply.text.split(separator: " ", omittingEmptySubsequences: false) { onText(String(word) + " ") }
        var output: [AgentMessage] = []
        if !reply.text.isEmpty { output.append(.init(value: .object(["type": .string("message"), "role": .string("assistant"), "content": .array([.object(["type": .string("output_text"), "text": .string(reply.text)])])]))) }
        for call in reply.calls { output.append(.init(value: .object(["type": .string("function_call"), "name": .string(call.name), "call_id": .string(call.callID), "arguments": .string(call.arguments)]))) }
        return .init(output: output, calls: reply.calls, text: reply.text, usage: AgentUsage(input: 100, cachedInput: 80, output: 10))
    }
    var turnRequests: [Request] { requests.filter { $0.conversation.last?.value.objectValue?["content"]?.stringValue?.hasPrefix("Native check") != true } }
    func release() { gate?.resume(); gate = nil }
}
@MainActor final class ScriptedExecutor: CalendarAgentToolExecuting {
    var availableToolNames: Set<String> = CalendarAgent.toolNames
    var calls: [(String, JSONValue)] = []
    var result = #"{"ok":true}"#
    func execute(name: String, arguments: JSONValue, sessionID: UUID) async -> String { calls.append((name, arguments)); return result }
    func cancelPending(sessionID: UUID) {}
}
@MainActor private func settle(_ rounds: Int = 200) async { for _ in 0..<rounds { await Task.yield() } }
@MainActor private func eventually(_ condition: () -> Bool, rounds: Int = 4000) async { for _ in 0..<rounds where !condition() { await Task.yield() } }
private func text(_ message: AgentMessage) -> String {
    let object = message.value.objectValue
    if let content = object?["content"]?.stringValue { return content }
    return object?["content"]?.arrayValue?.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n") ?? ""
}

// MARK: Speech segmentation

final class VoiceSentenceSplitterTests: XCTestCase {
    func testSentencesLeaveAsSoonAsTheyAreCompleteWithoutBreakingAbbreviationsOrNumbers() {
        var splitter = VoiceSentenceSplitter()
        XCTAssertEqual(splitter.append("Checking your calendar."), [], "A sentence end needs what follows")
        XCTAssertEqual(splitter.append(" You have 2.5 hours free"), ["Checking your calendar."])
        XCTAssertEqual(splitter.append(" before Dr. Ahmadi at 3 p.m. on Friday! Then"), ["You have 2.5 hours free before Dr. Ahmadi at 3 p.m. on Friday!"])
        XCTAssertEqual(splitter.finish(), ["Then"])
        XCTAssertEqual(splitter.finish(), [])
    }
    func testPersianQuestionMarksAndLineBreaksEndSentences() {
        var splitter = VoiceSentenceSplitter()
        XCTAssertEqual(splitter.append("فردا ساعت سه؟ بله\nاضافه شد"), ["فردا ساعت سه؟", "بله"])
        XCTAssertEqual(splitter.finish(), ["اضافه شد"])
    }
    func testLongSentencesSplitAtACommaAndFormattingIsNotSpoken() {
        var splitter = VoiceSentenceSplitter(); splitter.limit = 40
        let parts = splitter.append("You have a dentist appointment, then a long planning meeting with the whole team")
        XCTAssertEqual(parts, ["You have a dentist appointment,", "then a long planning meeting with the"])
        XCTAssertEqual(splitter.finish(), ["whole team"])
        XCTAssertEqual(VoiceSentenceSplitter.speakable("**Done** — see [the event](https://example.invalid) `id`"), "Done — see the event id")
        XCTAssertEqual(VoiceSentenceSplitter.speakable("- First\n2. Second"), "First Second")
    }
}

// MARK: Ears

@MainActor
final class GeminiEarsTests: XCTestCase {
    private var service: FakeVoiceService!
    private var socket: FakeVoiceSocket!
    private func make() -> GeminiEars {
        service = FakeVoiceService(); socket = FakeVoiceSocket()
        let ears = GeminiEars(service: service, makeSocket: { [unowned self] in self.socket }); ears.finalTimeout = .milliseconds(300)
        return ears
    }
    private func ready(_ ears: GeminiEars) async {
        ears.warm(vocabulary: ["CS 245"])
        await eventually { self.socket.continuation != nil }
        socket.emit(["setupComplete": [:]]); await settle()
    }
    func testWarmMintsAOneUseTokenWithTheVocabularyAndSendsOnlyTheModelInSetup() async {
        let ears = make(); await ready(ears)
        XCTAssertEqual(service.grants, [["CS 245"]])
        XCTAssertEqual(socket.headers["Authorization"], "Token auth_tokens/fictional")
        XCTAssertEqual(socket.url?.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(socket.sent.first as NSDictionary?, ["setup": ["model": "models/gemini-3.5-transcribe-live"]] as NSDictionary)
        ears.warm(vocabulary: ["CS 245"]); await settle()
        XCTAssertEqual(service.grants.count, 1, "An open connection is reused")
        ears.close()
    }
    func testSpeechBeforeTheConnectionIsReadyIsBufferedAndSentInOrder() async throws {
        let ears = make()
        ears.warm(vocabulary: [])
        ears.begin(); ears.append(Data([1, 2])); ears.append(Data([3, 4]))
        await eventually { self.socket.continuation != nil }
        XCTAssertEqual(socket.kinds, ["setup"], "Nothing but setup before the server is ready")
        socket.emit(["setupComplete": [:]]); await settle()
        XCTAssertEqual(socket.kinds, ["setup", "start", "audio", "audio"])
        let audio = try XCTUnwrap((socket.sent[2]["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any])
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=24000")
        XCTAssertEqual(audio["data"] as? String, Data([1, 2]).base64EncodedString())
        ears.close()
    }
    func testReleaseReturnsEveryFinalSegmentOnceGenerationCompletes() async throws {
        let ears = make(); await ready(ears)
        var interim: [String] = []; ears.onInterim = { interim.append($0) }
        ears.begin(); ears.append(Data([1]))
        socket.emit(["serverContent": ["interimInputTranscription": ["text": "what's on"]]])
        let finished = Task { try await ears.finish() }
        await settle()
        XCTAssertEqual(socket.kinds.last, "end")
        socket.emit(["serverContent": ["inputTranscription": ["text": "What's on my calendar"]]])
        socket.emit(["serverContent": ["inputTranscription": ["text": " this Friday?"]]])
        socket.emit(["serverContent": ["generationComplete": true]])
        let words = try await finished.value
        XCTAssertEqual(words, "What's on my calendar this Friday?")
        XCTAssertEqual(interim.first, "what's on"); XCTAssertEqual(interim.last, "What's on my calendar this Friday?")
        ears.close()
    }
    func testWithoutACompletionTheRecognizedWordsStillReturnAndSilenceFails() async throws {
        let ears = make(); await ready(ears)
        ears.begin(); ears.append(Data([1]))
        let first = Task { try await ears.finish() }
        socket.emit(["serverContent": ["inputTranscription": ["text": "Add lunch"]]])
        let words = try await first.value
        XCTAssertEqual(words, "Add lunch")
        ears.begin(); ears.append(Data([1]))
        do { _ = try await ears.finish(); XCTFail("Nothing heard must fail") } catch { XCTAssertEqual(error as? VoiceListeningError, .unavailable) }
        ears.close()
    }
    func testADiscardedHoldNeverReturnsWordsAndTheNextHoldKeepsItsOwn() async throws {
        let ears = make(); await ready(ears)
        ears.begin(); ears.append(Data([1])); ears.discard()
        ears.begin(); ears.append(Data([2]))
        let next = Task { try await ears.finish() }
        socket.emit(["serverContent": ["inputTranscription": ["text": "tap noise"]]])
        socket.emit(["serverContent": ["generationComplete": true]])
        socket.emit(["serverContent": ["inputTranscription": ["text": "Real request"]]])
        socket.emit(["serverContent": ["generationComplete": true]])
        let words = try await next.value
        XCTAssertEqual(words, "Real request")
        ears.close()
    }
    func testALostConnectionFailsTheHoldAndTheNextHoldReconnects() async throws {
        let ears = make(); await ready(ears)
        ears.begin(); ears.append(Data([1]))
        let held = Task { try await ears.finish() }
        await settle(); socket.continuation?.finish(throwing: VoiceSocketError.unavailable)
        do { _ = try await held.value; XCTFail("A lost connection must fail the hold") } catch {}
        ears.begin(); await eventually { self.service.grants.count == 2 }
        XCTAssertEqual(service.grants.count, 2); ears.close()
    }
    func testTheDailyLimitReachesTheHoldAsItsOwnMessage() async throws {
        let ears = make(); service.grantError = VoiceServiceError.limit
        ears.warm(vocabulary: []); ears.begin(); ears.append(Data([1]))
        do { _ = try await ears.finish(); XCTFail("Limit must fail") } catch { XCTAssertEqual(error as? VoiceServiceError, .limit) }
        XCTAssertTrue(VoiceServiceError.limit.errorDescription?.contains("today’s voice limit") == true)
        XCTAssertEqual(VoiceServiceError.from(status: 401), .signIn); XCTAssertEqual(VoiceServiceError.from(status: 403), .verify)
        XCTAssertEqual(VoiceServiceError.from(status: 502), .unavailable)
    }
}

// MARK: Mouth

@MainActor
final class VoiceMouthTests: XCTestCase {
    func testSentencesPlayInOrderEvenWhenALaterOneArrivesFirst() async {
        let service = FakeVoiceService(), audio = RecordingVoiceAudio()
        service.audio = ["One.": [Data([1]), Data([2])], "Two.": [Data([3])], "Three.": [Data([4])]]
        service.held = ["One."]
        let mouth = VoiceMouth(service: service, audio: audio); mouth.voice = "Kore"
        var first = 0; mouth.onFirstAudio = { first += 1 }
        mouth.say("One."); mouth.say("Two."); mouth.say("Three.")
        await settle()
        XCTAssertEqual(service.spoken.map(\.text), ["One.", "Two."], "Two sentences are fetched ahead, not more")
        XCTAssertTrue(audio.played.isEmpty, "Nothing plays before the first sentence")
        XCTAssertTrue(mouth.isSpeaking)
        service.release("One."); await eventually { audio.played.count == 4 }
        XCTAssertEqual(audio.played.map { $0.0 }, [Data([1]), Data([2]), Data([3]), Data([4])])
        XCTAssertEqual(service.spoken.map(\.voice), ["Kore", "Kore", "Kore"])
        XCTAssertEqual(first, 1)
        audio.isPlaying = false
        await eventually { !mouth.isSpeaking }
        XCTAssertFalse(mouth.isSpeaking, "Done once every sentence arrived and the speaker is quiet")
    }
    func testStopDropsEverythingAndSilencesTheSpeaker() async {
        let service = FakeVoiceService(), audio = RecordingVoiceAudio()
        service.held = ["Long answer."]
        let mouth = VoiceMouth(service: service, audio: audio)
        mouth.say("Long answer."); mouth.say("More."); await settle()
        mouth.stop()
        XCTAssertFalse(mouth.isSpeaking); XCTAssertEqual(audio.flushes, 1)
        service.release("Long answer."); await settle()
        XCTAssertTrue(audio.played.isEmpty, "Audio arriving after a stop is never played")
    }
    func testAFailedSentenceIsReportedAndTheRestStillPlays() async {
        let service = FakeVoiceService(), audio = RecordingVoiceAudio()
        let mouth = VoiceMouth(service: service, audio: audio)
        var errors: [Error] = []; mouth.onError = { errors.append($0) }
        service.speechError = VoiceServiceError.limit
        mouth.say("Blocked."); await settle()
        XCTAssertEqual(errors.first as? VoiceServiceError, .limit)
        service.speechError = nil; mouth.say("Next."); await eventually { !audio.played.isEmpty }
        XCTAssertEqual(audio.played.count, 1)
    }
}

// MARK: Brain

@MainActor
final class VoiceBrainTests: XCTestCase {
    private func make(_ client: ScriptedModelClient, _ executor: ScriptedExecutor? = nil) -> VoiceBrain {
        let brain = VoiceBrain(client: client, executor: executor ?? ScriptedExecutor(), sessionID: UUID())
        brain.begin(context: "Fictional memory: prefers mornings")
        return brain
    }
    func testFixedInstructionsLeadAndEachRequestOnlyAppendsToThePreviousOne() async throws {
        let client = ScriptedModelClient(); client.replies = [.init(text: "You have two meetings tomorrow."), .init(text: "The first is at nine.")]
        let brain = make(client)
        var streamed = ""
        let first = try await brain.respond(.init(words: "What's tomorrow?", context: "Clock: fictional")) { streamed += $0 }
        XCTAssertEqual(first, "You have two meetings tomorrow."); XCTAssertTrue(streamed.contains("two meetings"))
        _ = try await brain.respond(.init(words: "When is the first?", context: "Clock: later")) { _ in }
        let requests = client.turnRequests
        XCTAssertEqual(requests.count, 2)
        let one = requests[0].conversation, two = requests[1].conversation
        XCTAssertEqual(one[0].value.objectValue?["role"]?.stringValue, "developer")
        XCTAssertEqual(text(one[0]), VoiceBrain.instructions)
        XCTAssertTrue(VoiceBrain.instructions.hasPrefix("SPEAKING STYLE"))
        XCTAssertTrue(VoiceBrain.instructions.contains(CalendarAgent.instructions), "Voice keeps every typed-agent rule")
        XCTAssertTrue(text(one[1]).contains("prefers mornings"))
        XCTAssertTrue(text(one[2]).hasPrefix(VoiceBrain.turnHeader)); XCTAssertEqual(text(one[3]), "What's tomorrow?")
        XCTAssertEqual(Array(two.prefix(one.count)), one, "The second request starts with the whole first one, so its prefix is cached")
        XCTAssertTrue(requests.allSatisfy { var options = $0.options; options.cacheKey = nil; return $0.instructions.isEmpty && options == .voice })
        XCTAssertNotNil(client.requests.first?.options.cacheKey)
        XCTAssertEqual(Set(client.requests.map(\.options.cacheKey)).count, 1, "Every request of the session shares one cache key")
        XCTAssertFalse(requests[0].tools.contains("ask_user"))
    }
    func testToolsRunThroughTheVoiceExecutorAndTheAnswerFollows() async throws {
        let client = ScriptedModelClient(), executor = ScriptedExecutor()
        client.replies = [.init(text: "Checking your calendar.", calls: [.init(name: "get_agenda", callID: "c1", arguments: #"{"day":"2026-11-20"}"#)]),
                          .init(text: "Friday is free.")]
        let brain = make(client, executor)
        var streamed = ""
        let reply = try await brain.respond(.init(words: "Am I free Friday?", context: "")) { streamed += $0 }
        XCTAssertEqual(executor.calls.map(\.0), ["get_agenda"])
        XCTAssertEqual(reply, "Checking your calendar. Friday is free.")
        XCTAssertTrue(streamed.contains("Checking your calendar. \n"), "The acknowledgement is flushed before the tool runs")
        let last = try XCTUnwrap(client.turnRequests.last?.conversation.last?.value.objectValue)
        XCTAssertEqual(last["type"]?.stringValue, "function_call_output"); XCTAssertEqual(last["output"]?.stringValue, #"{"ok":true}"#)
    }
    func testInvalidOrUnknownToolCallsNeverReachTheExecutor() async throws {
        let client = ScriptedModelClient(), executor = ScriptedExecutor()
        client.replies = [.init(calls: [.init(name: "ask_user", callID: "a", arguments: "{}"), .init(name: "get_agenda", callID: "b", arguments: "{")]), .init(text: "Sorry.")]
        _ = try await make(client, executor).respond(.init(words: "Hi", context: "")) { _ in }
        XCTAssertTrue(executor.calls.isEmpty)
    }
    func testLookAtScreenAttachesTheTurnsImageAndFinishedTurnsDropImages() async throws {
        let client = ScriptedModelClient()
        client.replies = [.init(calls: [.init(name: VoiceBrain.lookToolName, callID: "l", arguments: "{}")]), .init(text: "It's a bar chart."), .init(text: "Yes.")]
        let brain = make(client); brain.look = { Data([0xFF, 0xD8]) }
        _ = try await brain.respond(.init(words: "What's this?", context: "")) { _ in }
        let during = try XCTUnwrap(client.turnRequests.last?.conversation.last?.value.jsonString())
        XCTAssertTrue(during.contains("input_image"))
        XCTAssertTrue(client.turnRequests[0].tools.contains(VoiceBrain.lookToolName))
        _ = try await brain.respond(.init(words: "Is it rising?", context: "")) { _ in }
        XCTAssertFalse(brain.conversation.contains { $0.value.jsonString().contains("input_image") }, "Old images are not resent")
    }
    func testAnInterruptedTurnLeavesOnlyTheRequestBehind() async throws {
        let client = ScriptedModelClient()
        client.replies = [.init(text: "Checking.", calls: [.init(name: "get_agenda", callID: "c", arguments: "{}")]), .init(text: "Too late.", wait: true)]
        let brain = make(client)
        let turn = Task { try await brain.respond(.init(words: "Move my dentist", context: "Clock")) { _ in } }
        await eventually { client.gate != nil }
        turn.cancel(); client.release()
        do { _ = try await turn.value; XCTFail("Cancelled") } catch {}
        let tail = brain.conversation.suffix(2).map(text)
        XCTAssertEqual(tail.first, "Move my dentist")
        XCTAssertTrue(tail.last?.contains("interrupted") == true)
        XCTAssertFalse(brain.conversation.contains { $0.value.objectValue?["type"]?.stringValue == "function_call" }, "No half-finished tool exchange remains")
    }
    func testAnAnnouncementCanOnlySpeak() async throws {
        let client = ScriptedModelClient(); client.replies = [.init(text: "Your dentist starts in ten minutes.")]
        _ = try await make(client).respond(.init(words: "Proactive alert", context: "", announcement: true)) { _ in }
        XCTAssertEqual(client.turnRequests.first?.tools, [])
    }
    func testPrewarmReadsTheSessionPrefixWithoutEnteringTheConversation() async {
        let client = ScriptedModelClient(); let brain = make(client)
        let before = brain.conversation
        await brain.prewarm()
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(Array(client.requests[0].conversation.prefix(before.count)), before)
        XCTAssertEqual(brain.conversation, before)
    }
    func testALongSessionDropsItsOldestTurnsButKeepsInstructionsContextAndRecentTurns() async throws {
        let client = ScriptedModelClient(); let brain = make(client)
        let filler = String(repeating: "x", count: 90_000)
        for index in 0..<4 { client.replies.append(.init(text: "Answer \(index)")); _ = try await brain.respond(.init(words: "Request \(index) " + filler, context: "")) { _ in } }
        let all = brain.conversation.map(text).joined()
        XCTAssertFalse(all.contains("Request 0")); XCTAssertTrue(all.contains("Request 3"))
        XCTAssertEqual(text(brain.conversation[0]), VoiceBrain.instructions); XCTAssertTrue(text(brain.conversation[1]).contains("prefers mornings"))
    }
    func testSpeedOptionsAreSentOnlyWhereTheRouteBillsThem() {
        var plan: [String: JSONValue] = [:], key: [String: JSONValue] = [:]
        ResponsesCalendarAgentClient.apply(.voice, to: &plan, usesPlan: true, skipping: [])
        ResponsesCalendarAgentClient.apply(.voice, to: &key, usesPlan: false, skipping: [])
        XCTAssertEqual(plan["service_tier"], .string("ultrafast")); XCTAssertNil(key["service_tier"], "An API key is never billed the Ultrafast multiplier")
        XCTAssertEqual(plan["reasoning"], .object(["effort": .string("low")])); XCTAssertEqual(key["text"], .object(["verbosity": .string("low")]))
        var skipped: [String: JSONValue] = [:]
        ResponsesCalendarAgentClient.apply(.voice, to: &skipped, usesPlan: true, skipping: ["service_tier", "reasoning"])
        XCTAssertNil(skipped["service_tier"]); XCTAssertNil(skipped["reasoning"]); XCTAssertNotNil(skipped["text"])
        XCTAssertEqual(ResponsesCalendarAgentClient.rejectedOption(in: "Unsupported value. Parameter: service_tier."), "service_tier")
        XCTAssertEqual(ResponsesCalendarAgentClient.rejectedOption(in: "Code: subscription_sharing_unsupported_capability.", alreadyRejected: ["service_tier"]), "text")
        XCTAssertNil(ResponsesCalendarAgentClient.rejectedOption(in: "Invalid tool schema."))
        let session = UUID(); var keyed: [String: JSONValue] = [:]
        ResponsesCalendarAgentClient.apply(.voice(session: session), to: &keyed, usesPlan: true, skipping: [])
        XCTAssertEqual(keyed["prompt_cache_key"], .string("calshot-voice-" + session.uuidString.lowercased()))
        XCTAssertNil(plan["prompt_cache_key"]); XCTAssertEqual(ResponsesCalendarAgentClient.rejectedOption(in: "Unknown parameter: 'prompt_cache_key'."), "prompt_cache_key")
        keyed = [:]; ResponsesCalendarAgentClient.apply(.voice(session: session), to: &keyed, usesPlan: true, skipping: ["prompt_cache_key"])
        XCTAssertNil(keyed["prompt_cache_key"])
        XCTAssertEqual(ResponsesCalendarAgentClient.rejectedOption(in: "The model gpt-6.1-sol is not available on this plan."), "model")
    }
    func testTheVoiceServerReceivesOnlyTheConversationToolsAndSessionCacheKey() throws {
        let session = UUID(), options = AgentRequestOptions.voice(session: session)
        let conversation = [AgentMessage.text(role: "developer", content: "Fictional voice rules."), .text(role: "user", content: "What's on Friday?")]
        let tool = JSONValue.object(["type": .string("function"), "name": .string("get_agenda"), "parameters": .object([:])])
        let body = try XCTUnwrap(CalshotBrainClient.body(conversation: conversation, instructions: "", tools: [tool], cacheKey: options.cacheKey).objectValue)
        XCTAssertEqual(Set(body.keys), ["input", "tools", "cache_key"], "The server fixes the model, tier and limits")
        XCTAssertEqual(body["input"]?.arrayValue?.count, 2); XCTAssertEqual(body["tools"]?.arrayValue, [tool])
        let key = try XCTUnwrap(body["cache_key"]?.stringValue)
        XCTAssertEqual(key, "calshot-voice-" + session.uuidString.lowercased())
        XCTAssertNotNil(key.range(of: "^[a-z0-9-]{8,80}$", options: .regularExpression), "Matches what the server accepts")
        let withInstructions = CalshotBrainClient.body(conversation: conversation, instructions: "Fictional extra.", tools: [], cacheKey: nil).objectValue
        XCTAssertEqual(withInstructions?["input"]?.arrayValue?.first?.objectValue?["role"], .string("developer"))
    }
    func testVoiceOnThePlanUsesTheModelOfferingUltrafastElseTheFastTier() {
        typealias Option = ChatGPTConnection.ModelOption
        let luna = Option(slug: "gpt-5.6-luna", displayName: "Luna", serviceTiers: ["priority"])
        let sol = Option(slug: "gpt-5.6-sol", displayName: "Sol", serviceTiers: ["priority", "ultrafast"])
        let plain = Option(slug: "gpt-6-sol", displayName: "Six", serviceTiers: [])
        XCTAssertTrue(ChatGPTConnection.fastest(in: [luna, sol], selected: "gpt-5.6-luna") == ("gpt-5.6-sol", "ultrafast"))
        XCTAssertTrue(ChatGPTConnection.fastest(in: [luna, plain], selected: "gpt-5.6-luna") == ("gpt-5.6-luna", "priority"))
        XCTAssertTrue(ChatGPTConnection.fastest(in: [luna, plain], selected: "gpt-6-sol") == ("gpt-6-sol", nil))
        let unlisted = [Option(slug: "gpt-5.6-luna", displayName: "Luna"), Option(slug: "gpt-5.6-sol", displayName: "Sol")]
        XCTAssertTrue(ChatGPTConnection.fastest(in: unlisted, selected: "gpt-5.6-luna") == ("gpt-5.6-sol", "ultrafast"), "A list without tiers still finds a known Ultrafast model")
        let current = [Option(slug: "gpt-6.2-sol", displayName: "6.2"), Option(slug: "gpt-6.1-sol", displayName: "6.1"), Option(slug: "gpt-5.6-sol", displayName: "5.6")]
        XCTAssertTrue(ChatGPTConnection.fastest(in: current, selected: "gpt-6.2-sol") == ("gpt-6.1-sol", "ultrafast"), "GPT-6.1 Sol is OpenAI's Ultrafast model")
        let offered = [Option(slug: "gpt-6.2-sol", displayName: "6.2", serviceTiers: ["priority", "ultrafast"]), Option(slug: "gpt-6.1-sol", displayName: "6.1", serviceTiers: [])]
        XCTAssertTrue(ChatGPTConnection.fastest(in: offered, selected: "gpt-6.1-sol") == ("gpt-6.2-sol", "ultrafast"), "What the plan says it offers wins")
        XCTAssertTrue(ChatGPTConnection.fastest(in: [], selected: "gpt-5.6-luna") == ("gpt-5.6-luna", nil))
    }
}

// MARK: Session

@MainActor
final class VoiceSessionIntegrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var ears: PreviewVoiceEars!
    private var mouth: PreviewVoiceMouth!
    private var audio: PreviewVoiceAudio!
    private var overlay: PreviewVoiceOverlay!
    private var frames: PreviewVoiceFrames!
    private var model: ScriptedModelClient!
    private var executor: ScriptedExecutor!
    private func make(microphone: Bool = true, screen: Bool = true) -> VoiceSessionController {
        defaults = UserDefaults(suiteName: "VoiceSessionTests.\(UUID())")!
        defaults.set(VoiceSessionController.acknowledgementVersion, forKey: "voice.acknowledgementVersion")
        ears = PreviewVoiceEars(); mouth = PreviewVoiceMouth(); audio = PreviewVoiceAudio(); overlay = PreviewVoiceOverlay(); frames = PreviewVoiceFrames()
        model = ScriptedModelClient(); executor = ScriptedExecutor()
        let session = VoiceSessionController(ears: ears, mouth: mouth, audio: audio, overlay: overlay, frames: frames, defaults: defaults, permission: { microphone }, screenPermission: { screen })
        session.eligible = { true }; session.hasKey = { true }; session.releaseTail = .zero; session.tapThreshold = 0
        session.makeBrain = { [unowned self] _ in VoiceBrain(client: self.model, executor: self.executor, sessionID: UUID()) }
        return session
    }
    /// Holds the talk key, speaks `bytes` of audio and releases; the transcriber returns `words`.
    private func say(_ s: VoiceSessionController, _ words: String = "What's on today?", bytes: Int = 9600) async {
        ears.results.append(.success(words))
        await s.talk(true); audio.onInput?(Data(count: bytes)); await s.talk(false)
        await eventually { self.model.turnRequests.count > 0 && !s.isTurning }
    }
    func testGatesNeverOpenListeningWithoutConsentAIServiceOrTheNewNotice() async {
        let s = make(); s.consent = { false }; await s.toggle()
        XCTAssertTrue(ears.warmed.isEmpty); XCTAssertTrue(s.error?.contains("OpenAI analysis") == true)
        s.consent = { true }; s.hasKey = { false }; await s.toggle()
        XCTAssertTrue(s.needsKey); XCTAssertTrue(s.error?.contains("AI service") == true); XCTAssertTrue(ears.warmed.isEmpty)
        s.hasKey = { true }; defaults.set(2, forKey: "voice.acknowledgementVersion"); await s.toggle()
        XCTAssertTrue(s.needsAcknowledgement, "The Realtime-era notice does not cover Google listening"); XCTAssertTrue(ears.warmed.isEmpty)
        s.acknowledge(); await s.toggle(); XCTAssertTrue(s.active); XCTAssertEqual(ears.warmed.count, 1)
        let closes = ears.closes
        s.consent = { false }; s.tick(now: Date()); XCTAssertFalse(s.active); XCTAssertEqual(ears.closes, closes + 1)
    }
    func testStartWarmsListeningAndReadsWhatCalshotKnowsIntoTheCache() async {
        let s = make(); s.vocabulary = { ["CS 245", "Dr. Ahmadi"] }
        s.context = { "Fictional memory" }; s.history = { "user: fictional earlier turn" }; s.schedule = { "Fictional schedule: dentist at 3" }
        await s.toggle(); await eventually { self.model.requests.count == 1 }
        XCTAssertEqual(ears.warmed, [["CS 245", "Dr. Ahmadi"]])
        XCTAssertEqual(s.state, .listening, "The user can talk at once; listening buffers until it is connected")
        let seeded = text(model.requests[0].conversation[1])
        XCTAssertTrue(seeded.contains("Fictional memory") && seeded.contains("fictional earlier turn") && seeded.contains("dentist at 3"))
        XCTAssertTrue(s.scheduleContextForInspection.contains("dentist at 3"))
        s.stop()
    }
    func testAHeldTurnIsHeardTranscribedAnsweredAndSpokenSentenceBySentence() async throws {
        let s = make(screen: false); var saved: [(String, String)] = []; s.transcript = { saved.append(($0, $1)) }
        let now = Date(timeIntervalSince1970: 1_800_000_000); s.clock = { now }
        model.replies = [.init(text: "You have two meetings. The first is at nine.")]
        await s.toggle()
        await s.talk(true); XCTAssertEqual(ears.begins, 1); XCTAssertEqual(s.state, .listening)
        audio.onInput?(Data(count: 9600)); XCTAssertEqual(ears.audio.count, 9600)
        ears.results.append(.success("What's on today?"))
        await s.talk(false); await eventually { self.mouth.spoken.count == 2 }
        XCTAssertEqual(mouth.spoken, ["You have two meetings.", "The first is at nine."])
        XCTAssertEqual(saved.map(\.0), ["user", "assistant"]); XCTAssertEqual(saved.first?.1, "What's on today?")
        let request = try XCTUnwrap(model.turnRequests.first)
        XCTAssertTrue(text(request.conversation[request.conversation.count - 2]).contains(CalendarAgent.clockContext(now: now)))
        XCTAssertTrue(text(request.conversation[request.conversation.count - 2]).contains("Screen Recording is off") == false)
        audio.onInput?(Data(count: 9600)); XCTAssertEqual(ears.audio.count, 9600, "Audio is sent only while held")
        s.stop()
    }
    func testSpeakingLastsUntilSpeechEndsThenItListens() async {
        let s = make(screen: false); model.replies = [.init(text: "Done.")]
        await s.toggle()
        await say(s); mouth.playing = true; s.tick(now: Date())
        XCTAssertEqual(s.state, .speaking)
        mouth.playing = false; s.tick(now: Date())
        XCTAssertEqual(s.state, .listening, "No stuck speaking state once the speaker is quiet")
        s.stop()
    }
    func testTooShortSilentOrUnheardHoldsAreDroppedWithAReason() async {
        let s = make(screen: false); await s.toggle()
        await s.talk(true); audio.onInput?(Data(count: 100)); await s.talk(false)
        XCTAssertEqual(ears.discards, 1); XCTAssertTrue(s.error?.contains("too short") == true)
        audio.inputLevel = 0.0001
        await s.talk(true); audio.onInput?(Data(count: 9600)); await s.talk(false)
        XCTAssertEqual(ears.discards, 2); XCTAssertTrue(s.error?.contains("isn’t hearing your microphone") == true); XCTAssertEqual(s.audioIssue, "devices")
        audio.inputLevel = 0.3
        ears.results.append(.success("   ")); await s.talk(true); audio.onInput?(Data(count: 9600)); await s.talk(false)
        await eventually { s.error?.contains("didn’t catch") == true }
        XCTAssertTrue(model.turnRequests.isEmpty, "Nothing reaches the agent without words")
        ears.results.append(.failure(VoiceServiceError.limit)); await s.talk(true); audio.onInput?(Data(count: 9600)); await s.talk(false)
        await eventually { s.error?.contains("voice limit") == true }
        XCTAssertTrue(s.active, "A listening failure keeps the session"); s.stop()
    }
    func testAQuickTapEndsTheSessionAndKeepsAnOpenReview() async {
        let s = make(); s.tapThreshold = 0.35; var cancelled = 0; s.cancelPending = { cancelled += 1 }; s.waitingForReview = { true }
        await s.toggle(); await s.talk(true); await s.talk(false)
        XCTAssertFalse(s.active); XCTAssertEqual(cancelled, 0)
    }
    func testTalkingOverCalshotStopsItAtOnceAndTheNextTurnIsTold() async throws {
        let s = make(screen: false); var interrupted: [Bool] = []; s.onReplyEnded = { interrupted.append($0); return false }
        model.replies = [.init(text: "A long answer."), .init(text: "Short.")]
        await s.toggle(); await say(s)
        mouth.playing = true
        await say(s, "Shorter please")
        XCTAssertEqual(mouth.stops, 1); XCTAssertEqual(s.interruptions, 1); XCTAssertEqual(interrupted.first(where: { $0 }), true)
        let context = text(try XCTUnwrap(model.turnRequests.last?.conversation.dropLast().last))
        XCTAssertTrue(context.contains("cut off your last spoken reply"))
        s.stop()
    }
    func testANewerRequestReplacesOneStillRunningUnlessAReviewIsOpen() async {
        let s = make(screen: false)
        model.replies = [.init(text: "Old.", wait: true), .init(text: "New.")]
        await s.toggle()
        ears.results.append(.success("Add lunch Friday")); await s.talk(true); audio.onInput?(Data(count: 9600)); await s.talk(false)
        await eventually { self.model.gate != nil }
        await say(s, "No, Thursday")
        model.release(); await settle()
        XCTAssertEqual(mouth.spoken, ["New."], "The replaced request never speaks")
        var review = true; s.waitingForReview = { review }
        model.replies = [.init(text: "Saved.", wait: true)]
        ears.results.append(.success("Add a meeting with guests")); await s.talk(true); audio.onInput?(Data(count: 9600)); await s.talk(false)
        await eventually { self.model.gate != nil }
        model.replies = [.init(text: "And done.")]
        ears.results.append(.success("Also add lunch")); await s.talk(true); audio.onInput?(Data(count: 9600)); await s.talk(false)
        await settle()
        XCTAssertFalse(mouth.spoken.contains("And done."), "The new request waits behind the one under review")
        model.release(); await eventually { self.mouth.spoken.contains("And done.") }
        XCTAssertEqual(Array(mouth.spoken.suffix(2)), ["Saved.", "And done."], "A request whose review is open is never cancelled; both answer in order")
        review = false; s.stop()
    }
    func testTypedTextIsAnsweredAloudWithItsExactWords() async throws {
        let s = make(); var saved: [String] = []; s.transcript = { saved.append($1) }
        model.replies = [.init(text: "Added.")]
        await s.toggle(); await eventually { self.model.requests.count == 1 }
        try s.typed("Add dentist Nov 12 at 3")
        await eventually { self.mouth.spoken == ["Added."] }
        XCTAssertEqual(saved.first, "Add dentist Nov 12 at 3"); XCTAssertEqual(ears.begins, 0); XCTAssertEqual(frames.captures, 0)
        XCTAssertEqual(model.turnRequests.last.map { text($0.conversation.last!) }, "Add dentist Nov 12 at 3")
        s.stop()
    }
    func testTheScreenTravelsAsTextAndAnUnchangedScreenIsOneLine() async throws {
        let s = make(); frames.text = ScreenTextRecognition(lines: [RecognizedScreenLine(text: "Fictional syllabus: exam Dec 16", region: SourceRegion(x: 0, y: 0, width: 1, height: 0.1))])
        model.replies = [.init(text: "One."), .init(text: "Two.")]
        var recognized: [String] = []; s.onScreenText = { recognized.append($0.text) }
        await s.toggle(); await say(s); await say(s, "And the other one?")
        let first = text(model.turnRequests[0].conversation.dropLast().last!), second = text(model.turnRequests[1].conversation.dropLast().last!)
        XCTAssertTrue(first.contains("exam Dec 16")); XCTAssertFalse(second.contains("exam Dec 16")); XCTAssertTrue(second.contains("same text"))
        XCTAssertEqual(frames.captures, 2, "One frame per turn, prefetched while talking")
        XCTAssertFalse(model.turnRequests.flatMap(\.conversation).contains { $0.value.jsonString().contains("input_image") }, "No picture unless the user drew")
        XCTAssertTrue(recognized.contains { $0.contains("exam Dec 16") })
        s.stop()
    }
    func testASlowScreenNeverHoldsTheAnswerBackAndLookingWaitsForIt() async throws {
        let s = make(); frames.delay = .milliseconds(1500)
        model.replies = [.init(calls: [.init(name: VoiceBrain.lookToolName, callID: "l", arguments: "{}")]), .init(text: "It's a chart.")]
        await s.toggle()
        let started = Date()
        ears.results.append(.success("What's this?"))
        await s.talk(true); audio.onInput?(Data(count: 9600)); await s.talk(false)
        for _ in 0..<100 where model.turnRequests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.2, "The agent starts without the screen once the wait is over")
        XCTAssertTrue(text(model.turnRequests[0].conversation.dropLast().last!).contains("still being read"))
        for _ in 0..<150 where s.isTurning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(frames.captures, 1, "Looking waits for this turn's capture instead of taking another")
        XCTAssertTrue(model.turnRequests.last?.conversation.last?.value.jsonString().contains("input_image") == true)
        s.stop()
    }
    func testWhatTheUserDrewRidesWithTheTurnAsTheSubject() async throws {
        let s = make()
        frames.text = ScreenTextRecognition(lines: [RecognizedScreenLine(text: "Dentist Nov 12 3 PM", region: SourceRegion(x: 0.1, y: 0.1, width: 0.3, height: 0.05)),
                                                    RecognizedScreenLine(text: "Unrelated footer", region: SourceRegion(x: 0.1, y: 0.9, width: 0.3, height: 0.05))])
        frames.regions = [CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.15)]
        model.replies = [.init(text: "Added.")]
        await s.toggle()
        overlay.marks = [FocusMark(kind: .point, points: [.zero], displayID: 1, timestamp: Date())]
        await say(s, "Add this")
        let request = try XCTUnwrap(model.turnRequests.first)
        let caption = text(request.conversation.dropLast().last!)
        XCTAssertTrue(caption.contains("Text inside the user's marks") && caption.contains("Dentist Nov 12 3 PM"))
        XCTAssertTrue(request.conversation.last!.value.jsonString().contains("input_image"))
        XCTAssertTrue(overlay.marks.isEmpty)
        s.stop()
    }
    func testWithoutScreenRecordingVoiceContinuesWithoutFrames() async {
        let s = make(screen: false); model.replies = [.init(text: "Okay.")]
        await s.toggle(); XCTAssertNotNil(s.error)
        await say(s); XCTAssertEqual(frames.captures, 0); XCTAssertEqual(mouth.spoken, ["Okay."])
        XCTAssertFalse(model.turnRequests[0].tools.contains(VoiceBrain.lookToolName)); s.stop()
    }
    func testEachTurnAddsOnlyNewRelevantMemoriesAndARefreshedSchedule() async throws {
        let s = make(screen: false); var version = "v1"
        s.context = { #"["fictional-1","prefers mornings"]"# }
        s.memoryFor = { _ in "[\"fictional-1\",\"prefers mornings\"]\n[\"fictional-2\",\"dentist is Dr. Ahmadi\"]" }
        s.scheduleVersion = { version }; s.schedule = { "Fictional schedule " + version }
        model.replies = [.init(text: "One."), .init(text: "Two."), .init(text: "Three.")]
        await s.toggle(); await say(s)
        var context = text(model.turnRequests[0].conversation.dropLast().last!)
        XCTAssertTrue(context.contains("dentist is Dr. Ahmadi")); XCTAssertFalse(context.contains("prefers mornings")); XCTAssertFalse(context.contains("Updated near-term schedule"))
        await say(s, "Again")
        context = text(model.turnRequests[1].conversation.dropLast().last!)
        XCTAssertFalse(context.contains("Dr. Ahmadi"), "A memory already in the conversation is not repeated")
        version = "v2"; await say(s, "And now?")
        context = text(model.turnRequests[2].conversation.dropLast().last!)
        XCTAssertTrue(context.contains("Updated near-term schedule") && context.contains("Fictional schedule v2"))
        s.stop()
    }
    func testAnAlertIsSpokenWhenIdleWithoutTools() async {
        let s = make(screen: false); model.replies = [.init(text: "Your dentist starts in ten minutes.")]
        let opened = await s.announce("Event alert: Fictional dentist, in 10 minutes.")
        XCTAssertTrue(opened); XCTAssertTrue(s.proactive)
        await eventually { self.model.requests.count >= 1 }
        s.tick(now: Date()); await eventually { !self.mouth.spoken.isEmpty }
        XCTAssertEqual(mouth.spoken, ["Your dentist starts in ten minutes."])
        XCTAssertEqual(model.turnRequests.first?.tools, [])
        XCTAssertTrue(text(model.turnRequests.first!.conversation.last!).contains("not permission to change anything"))
        s.tick(now: Date().addingTimeInterval(VoiceSessionController.proactiveIdle + 1)); XCTAssertFalse(s.active)
    }
    func testAReviewIsAnnouncedOnceByCalshotItself() async {
        let s = make(screen: false); await s.toggle()
        s.review(true); s.review(true)
        XCTAssertEqual(s.state, .waitingForReview); XCTAssertEqual(mouth.spoken, ["It’s ready for you to check in the notch."])
        s.review(false); XCTAssertEqual(s.state, .listening); s.stop()
    }
    func testIdleTenMinuteAndAccountLossEndTheSession() async {
        let s = make(screen: false); await s.toggle()
        s.tick(now: Date().addingTimeInterval(61)); XCTAssertFalse(s.active)
        await s.toggle(); mouth.playing = true
        s.tick(now: Date().addingTimeInterval(541)); XCTAssertTrue(s.error?.contains("10 minutes") == true, "Speech counts as activity")
        s.tick(now: Date().addingTimeInterval(601)); XCTAssertFalse(s.active)
        await s.toggle(); s.eligible = { false }; s.tick(now: Date()); XCTAssertFalse(s.active)
    }
    func testSessionEndHandsSpokenTurnsAndScreenTextToReflection() async {
        let s = make(); frames.text = ScreenTextRecognition(lines: [RecognizedScreenLine(text: "Fictional course page", region: SourceRegion(x: 0, y: 0, width: 1, height: 0.1))])
        var ended: ([(String, String)], String)?; s.onConversationEnded = { ended = ($0, $1) }
        model.replies = [.init(text: "Noted.")]
        await s.toggle(); await say(s, "I'm a student"); s.stop()
        XCTAssertEqual(ended?.0.map(\.0), ["user", "assistant"]); XCTAssertTrue(ended?.1.contains("Fictional course page") == true)
    }
    func testMicrophoneDeniedOrBrokenNeverOpensListening() async {
        var s = make(microphone: false); await s.toggle(); XCTAssertEqual(s.state, .failed); XCTAssertTrue(model.requests.isEmpty)
        s = make(); audio.startFailures = Array(repeating: .noInputDevice, count: 4); await s.toggle()
        XCTAssertEqual(s.state, .failed); XCTAssertEqual(s.audioIssue, "devices"); XCTAssertTrue(s.error?.contains("Sound → Input") == true)
        XCTAssertTrue(model.requests.isEmpty)
    }
    func testNoAIServiceMeansNoSession() async {
        let s = make(); s.makeBrain = { _ in nil }; await s.toggle()
        XCTAssertEqual(s.state, .failed); XCTAssertTrue(s.needsKey)
    }
    func testUnchangedTicksDoNotPublishAndANewSessionInvalidatesControls() async {
        let s = make(screen: false); let old = s.token; await s.toggle(); XCTAssertNotEqual(old, s.token)
        var changes = 0; s.onChange = { changes += 1 }
        s.tick(now: Date()); let baseline = changes
        for _ in 0..<10 { s.tick(now: Date()) }; XCTAssertEqual(changes, baseline); s.stop()
    }
    func testTheSnapshotOffersTheListedVoicesAndFallsBackFromAnOldOne() async {
        let s = make(); defaults.set("marin", forKey: "voice.voice")
        XCTAssertEqual(s.voice, VoiceMouth.defaultVoice)
        let voices = s.snapshot.objectValue?["voices"]?.arrayValue ?? []
        XCTAssertEqual(voices.count, VoiceMouth.voices.count)
        XCTAssertNil(s.snapshot.objectValue?["usage"]); XCTAssertNil(s.snapshot.objectValue?["engine"]); XCTAssertNil(s.snapshot.objectValue?["model"])
        defaults.set("Kore", forKey: "voice.voice"); XCTAssertEqual(s.voice, "Kore")
    }
}

// MARK: Audio

final class VoicePCMTests: XCTestCase {
    func testPlaybackStopNamesTheAudibleQueuedItem() {
        let queue = [VoicePCM.Segment(item: "first", start: 0, frames: 2400), .init(item: "second", start: 2400, frames: 4800)]
        XCTAssertEqual(VoicePCM.stop(segments: queue, renderedFrames: 1200), .init(item: "first", playedMilliseconds: 50))
        XCTAssertEqual(VoicePCM.stop(segments: queue, renderedFrames: 3600), .init(item: "second", playedMilliseconds: 50))
        XCTAssertEqual(VoicePCM.stop(segments: queue, renderedFrames: 9000), .init(item: "second", playedMilliseconds: 200))
        XCTAssertEqual(VoicePCM.stop(segments: [], renderedFrames: 100), .init(item: nil, playedMilliseconds: 0))
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
    /// Opt in on a developer Mac with existing permission; never prompts, records files, or contacts a service.
    @MainActor func testOptInMicrophoneHardwareCapture() async throws {
        guard ProcessInfo.processInfo.environment["CALSHOT_AUDIO_HARDWARE_CHECK"] == "1" else { throw XCTSkip("Set TEST_RUNNER_CALSHOT_AUDIO_HARDWARE_CHECK=1 to check local hardware.") }
        guard VoiceAudioEngine.microphonePermission == .authorized else { throw XCTSkip("Microphone permission must already be authorized; this test never prompts.") }
        let uid = try XCTUnwrap(AVCaptureDevice.default(for: .audio)?.uniqueID)
        XCTAssertTrue(VoiceAudioBoundary.inputDevices().contains { ($0["uid"] as? String) == uid }, "Picker UIDs must identify capture devices")
        let prefs = UserDefaults(suiteName: "MicrophoneHardwareCheck-" + UUID().uuidString)!
        prefs.set(uid, forKey: "voice.inputUID")
        let audio = VoiceAudioEngine(defaults: prefs); var bytes = 0
        audio.onInput = { bytes += $0.count }
        defer { audio.stop() }
        try await VoiceAudioStartup.start(attempt: { try await audio.start() }, shouldContinue: { true })
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(audio.isRunning); XCTAssertGreaterThan(bytes, 0)
        audio.stop(); XCTAssertFalse(audio.isRunning)
    }
    @MainActor func testAudioEngineInitializationAndStopArePassiveAndIdempotent() {
        let audio = VoiceAudioEngine()
        XCTAssertFalse(audio.isRunning); XCTAssertFalse(audio.isPlaying)
        audio.stop(); audio.stop(); XCTAssertEqual(audio.flush(), .init(item: nil, playedMilliseconds: 0))
    }
    @MainActor func testAudioStartupWaitsForTransientInputAndUsesBoundedBackoff() async throws {
        var attempts = 0, waits: [Duration] = []
        try await VoiceAudioStartup.start(attempt: {
            attempts += 1
            if attempts < 3 { throw VoiceAudioEngine.AudioError.noInputDevice }
        }, shouldContinue: { true }, wait: { waits.append($0) })
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(waits, [.milliseconds(200), .milliseconds(400)])
    }
    @MainActor func testAudioStartupDoesNotRetryDeniedPermission() async {
        for issue in [VoiceAudioEngine.AudioError.permission(.denied), .permission(.restricted)] {
            var attempts = 0, waits = 0
            do {
                try await VoiceAudioStartup.start(attempt: { attempts += 1; throw issue }, shouldContinue: { true }, wait: { _ in waits += 1 })
                XCTFail("Permission must fail")
            } catch { XCTAssertEqual(error as? VoiceAudioEngine.AudioError, issue) }
            XCTAssertEqual(attempts, 1); XCTAssertEqual(waits, 0)
        }
    }
    @MainActor func testAudioStartupStopsAfterFourAttemptsAndNeverContinuesAStoppedSession() async {
        var attempts = 0
        do {
            try await VoiceAudioStartup.start(attempt: { attempts += 1; throw VoiceAudioEngine.AudioError.graph }, shouldContinue: { true }, wait: { _ in })
            XCTFail("Unavailable graph must fail")
        } catch { XCTAssertEqual(error as? VoiceAudioEngine.AudioError, .graph) }
        XCTAssertEqual(attempts, 4)
        var current = true; attempts = 0
        do {
            try await VoiceAudioStartup.start(attempt: { attempts += 1; throw VoiceAudioEngine.AudioError.noInputDevice }, shouldContinue: { current }, wait: { _ in current = false })
            XCTFail("Stopped session must not reopen the mic")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(attempts, 1)
    }
}

@MainActor
final class VoiceInputSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "VoiceInputTests-" + UUID().uuidString)! }
    func testSelectionPersistsByUIDAndRejectsDisconnectedDevices() throws {
        let prefs = defaults()
        var devices = [VoiceInputSettings.Device(uid: "fictional-built-in", name: "Built-in microphone")]
        let input = VoiceInputSettings(defaults: prefs, devices: { devices }, observesHardware: false)
        prefs.set(true, forKey: "voice.echoCancellation") // Older preferences must not re-enable the removed engine path.
        try input.configure(uid: "fictional-built-in")
        XCTAssertNil(input.snapshot.objectValue?["echoCancellation"])
        XCTAssertEqual(prefs.string(forKey: "voice.inputUID"), "fictional-built-in")
        devices = []; input.refresh()
        XCTAssertFalse(input.selectedAvailable)
        XCTAssertEqual(input.selectedUID, "fictional-built-in", "Unplugging never changes the saved choice")
        XCTAssertThrowsError(try input.configure(uid: "fictional-unknown"))
    }
    func testTestUsesOnlyLocalAudioAndStopDiscardsLateCallbacks() async {
        let audio = PreviewVoiceAudio()
        let input = VoiceInputSettings(defaults: defaults(), devices: { [.init(uid: "fictional-mic", name: "Microphone")] }, makeAudio: { audio }, permission: { true }, observesHardware: false)
        await input.startTest()
        XCTAssertEqual(input.testState, "testing"); XCTAssertTrue(audio.running)
        let callback = audio.onInput
        callback?(Data(count: 32))
        XCTAssertTrue(input.detectedSound); XCTAssertGreaterThan(input.level, 0)
        XCTAssertNil(input.snapshot.objectValue?["inputLevel"], "Levels never enter React snapshots")
        input.stopTest(); XCTAssertFalse(audio.running); XCTAssertEqual(input.level, 0)
        callback?(Data(count: 32)); XCTAssertEqual(input.testState, "cancelled")
    }
    func testDeniedPermissionNeverStartsGraph() async {
        let audio = PreviewVoiceAudio()
        let input = VoiceInputSettings(defaults: defaults(), devices: { [.init(uid: "fictional-mic", name: "Microphone")] }, makeAudio: { audio }, permission: { false }, observesHardware: false)
        await input.startTest()
        XCTAssertEqual(audio.startAttempts, 0); XCTAssertEqual(input.testState, "failed")
        XCTAssertTrue(input.error?.contains("Microphone") == true)
    }
    func testStopWhilePermissionIsPendingCannotReopenMicrophone() async {
        let audio = PreviewVoiceAudio()
        var continuation: CheckedContinuation<Bool, Never>?
        let input = VoiceInputSettings(defaults: defaults(), devices: { [.init(uid: "fictional-mic", name: "Microphone")] }, makeAudio: { audio }, permission: { await withCheckedContinuation { continuation = $0 } }, observesHardware: false)
        let pending = Task { await input.startTest() }
        while continuation == nil { await Task.yield() }
        input.stopTest(); continuation?.resume(returning: true); await pending.value
        XCTAssertEqual(audio.startAttempts, 0); XCTAssertEqual(input.testState, "cancelled")
    }
    func testTestEndsAutomaticallyAndReportsDeviceFailure() async throws {
        let audio = PreviewVoiceAudio()
        let input = VoiceInputSettings(defaults: defaults(), devices: { [.init(uid: "fictional-mic", name: "Microphone")] }, makeAudio: { audio }, permission: { true }, duration: .milliseconds(5), observesHardware: false)
        await input.startTest()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(input.testState, "finished"); XCTAssertFalse(audio.running)
        await input.startTest(); audio.onError?(.selectedInputUnavailable)
        XCTAssertEqual(input.testState, "failed"); XCTAssertFalse(audio.running)
    }
}


@MainActor
private final class ControlledMicrophone: VoiceMicrophone {
    var samples: (@MainActor (Data, Float) -> Void)?
    var failure: (@MainActor (VoiceAudioEngine.AudioError) -> Void)?
    var starts = 0, stops = 0
    var uid = ""
    var running = false
    var suspendStart = false
    var continuation: CheckedContinuation<Void, Error>?
    func start(uid: String, samples: @escaping @MainActor (Data, Float) -> Void,
               failure: @escaping @MainActor (VoiceAudioEngine.AudioError) -> Void) async throws {
        starts += 1; self.uid = uid; self.samples = samples; self.failure = failure
        if suspendStart { try await withCheckedThrowingContinuation { continuation = $0 } }
        running = true
    }
    func stop() { stops += 1; running = false }
}

@MainActor
final class IndependentMicrophoneTests: XCTestCase {
    func testMicrophoneStartAndMeterNeverOpenSpeakerOrLegacyVoiceProcessing() async throws {
        let mic = ControlledMicrophone(); var playbackStarts = 0, chunks = 0
        let prefs = UserDefaults(suiteName: "IndependentMic-" + UUID().uuidString)!
        prefs.set("fictional-selected-mic", forKey: "voice.inputUID")
        prefs.set(true, forKey: "voice.echoCancellation")
        let engine = VoiceAudioEngine(defaults: prefs, makeMicrophone: { mic }, makePlayback: {
            playbackStarts += 1; throw VoiceAudioEngine.AudioError.noOutputDevice
        }, permission: { .authorized })
        engine.onInput = { _ in chunks += 1 }
        try await engine.start()
        XCTAssertEqual(mic.uid, "fictional-selected-mic"); XCTAssertTrue(mic.running)
        XCTAssertEqual(playbackStarts, 0); XCTAssertFalse(engine.playbackPrepared)
        mic.samples?(Data(count: VoicePCM.chunkBytes()), 0.25)
        XCTAssertEqual(chunks, 1); XCTAssertEqual(engine.inputLevel, 0.25)
        try engine.enqueuePCM16(Data(), itemID: "empty")
        XCTAssertThrowsError(try engine.enqueuePCM16(Data(count: 1), itemID: "malformed"))
        XCTAssertEqual(playbackStarts, 0, "Empty or invalid reply data must not open output hardware")
        XCTAssertThrowsError(try engine.enqueuePCM16(Data(count: 48), itemID: "fictional-reply"))
        XCTAssertEqual(playbackStarts, 1); XCTAssertTrue(mic.running, "An output failure must not be part of microphone startup")
        engine.stop(); XCTAssertFalse(mic.running)
    }
    func testStopDuringAsynchronousMicrophoneStartFencesCompletionAndSamples() async {
        let mic = ControlledMicrophone(); mic.suspendStart = true
        let engine = VoiceAudioEngine(makeMicrophone: { mic }, permission: { .authorized })
        var chunks = 0; engine.onInput = { _ in chunks += 1 }
        let pending = Task { try await engine.start() }
        while mic.continuation == nil { await Task.yield() }
        engine.stop(); mic.continuation?.resume()
        do { try await pending.value; XCTFail("Stopped startup must not succeed") } catch { XCTAssertTrue(error is CancellationError) }
        mic.samples?(Data(count: VoicePCM.chunkBytes()), 0.5)
        XCTAssertFalse(engine.isRunning); XCTAssertFalse(mic.running); XCTAssertEqual(chunks, 0)
        XCTAssertFalse(engine.playbackPrepared)
    }
    func testPermissionDenialCannotCreateCaptureOrOutput() async {
        let mic = ControlledMicrophone()
        let engine = VoiceAudioEngine(makeMicrophone: { mic }, makePlayback: { XCTFail("Opened speakers without permission"); throw VoiceAudioEngine.AudioError.graph }, permission: { .denied })
        do { try await engine.start(); XCTFail("Started denied microphone") } catch { XCTAssertEqual(error as? VoiceAudioEngine.AudioError, .permission(.denied)) }
        XCTAssertEqual(mic.starts, 0)
    }
}

/// GPT-Live protocol adapter: session.start, push-to-talk through mute, reply boundaries, delegation and appends.
