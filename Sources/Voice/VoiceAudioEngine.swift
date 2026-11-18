import AVFoundation
import os

private let audioLog = Logger(subsystem: "com.calshot.voice", category: "audio")
import Combine

/// Pure PCM helpers. Wire format is signed little-endian PCM16, mono, 24 kHz.
/// Where playback stopped: the audible server item and how many milliseconds of it were heard.
struct VoicePlaybackStop: Equatable { var item: String?; var playedMilliseconds: Int }

enum VoicePCM {
    static let sampleRate = 24_000.0
    static func encode(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let finite = sample.isNaN ? Float(0) : sample
            let clamped = min(1, max(-1, finite))
            let value = Int16(clamped < 0 ? clamped * 32768 : clamped * 32767)
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(bits & 255)); data.append(UInt8(bits >> 8))
        }
        return data
    }
    static func decode(_ data: Data) -> [Float] {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count - bytes.count % 2, by: 2).map {
            Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32768
        }
    }
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(0.0) { $0 + ($1.isFinite ? Double($1) * Double($1) : 0) }
        return Float(min(1, sqrt(energy / Double(samples.count))))
    }
    static func resamplingRatio(from rate: Double, to target: Double = sampleRate) -> Double {
        guard rate.isFinite, target.isFinite, rate > 0, target > 0 else { return 0 }
        return target / rate
    }
    static func chunkBytes(milliseconds: Int = 60) -> Int {
        // 40–100 ms; always a whole PCM16 sample.
        min(100, max(40, milliseconds)) * 48
    }
    static func playedMilliseconds(renderedFrames: Int64, itemStartFrame: Int64, itemFrames: Int64,
                                   sampleRate: Double = sampleRate) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return Int(Double(min(max(0, renderedFrames - itemStartFrame), max(0, itemFrames))) * 1000 / sampleRate)
    }
    /// One server audio item in the playback queue, in queue frames.
    struct Segment: Equatable { var item: String; var start: Int64; var frames: Int64 }
    /// The item the speakers were on when playback stopped and how much of it was heard.
    /// Items queued behind it were not heard at all.
    static func stop(segments: [Segment], renderedFrames: Int64, sampleRate: Double = sampleRate) -> VoicePlaybackStop {
        guard let audible = segments.first(where: { $0.start + $0.frames > renderedFrames }) ?? segments.last else { return .init(item: nil, playedMilliseconds: 0) }
        return .init(item: audible.item, playedMilliseconds: playedMilliseconds(renderedFrames: renderedFrames, itemStartFrame: audible.start, itemFrames: audible.frames, sampleRate: sampleRate))
    }
    struct Chunker {
        private var pending = Data()
        let bytes: Int
        init(milliseconds: Int = 60) { bytes = VoicePCM.chunkBytes(milliseconds: milliseconds) }
        mutating func append(_ data: Data) -> [Data] {
            pending.append(data)
            var result: [Data] = []
            while pending.count >= bytes { result.append(Data(pending.prefix(bytes))); pending.removeFirst(bytes) }
            return result
        }
    }
}

/// Input is captured independently; output hardware is created only for an actual spoken reply.
@MainActor
final class VoiceAudioEngine: ObservableObject {
    enum MicrophonePermission: Equatable { case authorized, denied, restricted, notDetermined }
    enum AudioError: Error, Equatable, LocalizedError {
        case permission(MicrophonePermission), noInputDevice, selectedInputUnavailable, noOutputDevice, conversion, graph
        var errorDescription: String? {
            switch self {
            case .permission(.restricted): return "Microphone access is restricted on this Mac. Check with the person managing its privacy settings."
            case .permission: return "Allow Microphone for Calshot in System Settings → Privacy & Security → Microphone, then start voice again."
            case .selectedInputUnavailable: return "The selected microphone is unavailable. Reconnect it or choose another microphone in Settings → Voice."
            case .noInputDevice: return "macOS hasn’t provided a usable microphone. Select the built-in microphone in System Settings → Sound → Input, then retry voice."
            case .noOutputDevice: return "macOS hasn’t provided usable speakers or headphones. Select an output in System Settings → Sound → Output, then retry voice."
            case .conversion: return "Calshot couldn’t read the microphone’s audio format. Check Sound → Input, try another microphone if available, then retry voice."
            case .graph: return "Calshot couldn’t start this Mac’s audio devices. Check Sound → Input and Output, close apps using them exclusively, then retry voice."
            }
        }
        var recovery: String { if case .permission = self { return "permission" }; return "devices" }
        var canRetryStartup: Bool { if case .permission = self { return false }; if self == .selectedInputUnavailable { return false }; return true }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isPlaying = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var failure: AudioError?
    var outputLevel: Float { isPlaying ? lastOutputLevel : 0 }
    private var lastOutputLevel: Float = 0
    var onInput: ((Data) -> Void)?
    var onError: ((AudioError) -> Void)?
    var onPlaybackInterrupted: ((Int) -> Void)?
    private var capture: (any VoiceMicrophone)?
    private let makeMicrophone: () -> any VoiceMicrophone
    private let makePlayback: () throws -> (AVAudioEngine, AVAudioPlayerNode)
    private let defaults: UserDefaults
    private let permission: () -> MicrophonePermission
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var outputObserver: NSObjectProtocol?
    private var rebuildTask: Task<Void, Never>?
    private var recoveryGeneration = UUID()
    private var generation = UUID()
    private var startID: UUID?
    private var startupFailure: AudioError?
    private var wantedRunning = false
    private var chunker = VoicePCM.Chunker()
    private var playbackGeneration = UUID()
    private var queuedFrames: Int64 = 0
    private var completedFrames: Int64 = 0
    /// Server audio items queued back to back. A new response's audio waits for the previous one to finish.
    private var segments: [VoicePCM.Segment] = []
    var playbackPrepared: Bool { player != nil }
    static var microphonePermission: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .restricted
        }
    }
    static func requestMicrophonePermission() async -> MicrophonePermission {
        if microphonePermission == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        return microphonePermission
    }

    init(defaults: UserDefaults = .standard, makeMicrophone: (() -> any VoiceMicrophone)? = nil,
         makePlayback: (() throws -> (AVAudioEngine, AVAudioPlayerNode))? = nil,
         permission: (() -> MicrophonePermission)? = nil) {
        self.defaults = defaults; self.permission = permission ?? { Self.microphonePermission }
        self.makeMicrophone = makeMicrophone ?? { VoiceCaptureInput() }
        self.makePlayback = makePlayback ?? { try Self.makePlaybackGraph() }
    }
    func start() async throws {
        guard !isRunning else { return }
        guard startID == nil else { throw AudioError.graph }
        guard permission() == .authorized else { throw AudioError.permission(permission()) }
        let id = UUID(); generation = id; startID = id; startupFailure = nil
        wantedRunning = true; chunker = VoicePCM.Chunker()
        let microphone = makeMicrophone(); capture = microphone
        defer { if startID == id { startID = nil } }
        do {
            try await microphone.start(uid: defaults.string(forKey: "voice.inputUID") ?? "", samples: { [weak self] pcm, level in
                guard let self, self.generation == id, self.wantedRunning, self.isRunning else { return }
                self.inputLevel = level
                // Push-to-talk interrupts playback first; never feed Calshot its own reply.
                guard !self.isPlaying else { self.chunker = VoicePCM.Chunker(); return }
                for chunk in self.chunker.append(pcm) { self.onInput?(chunk) }
            }, failure: { [weak self] issue in
                guard let self, self.generation == id, self.wantedRunning else { return }
                if self.startID == id { self.startupFailure = issue }
                else { self.rebuild() }
            })
            try Task.checkCancellation()
            guard generation == id, wantedRunning else { microphone.stop(); throw CancellationError() }
            if let startupFailure { throw startupFailure }
            isRunning = true; failure = nil
        } catch {
            microphone.stop()
            if generation == id {
                wantedRunning = false; capture = nil; inputLevel = 0; isRunning = false
                if !(error is CancellationError) { failure = error as? AudioError ?? .graph }
            }
            throw error
        }
    }
    func stop() {
        recoveryGeneration = UUID(); rebuildTask?.cancel(); rebuildTask = nil
        wantedRunning = false; generation = UUID(); startID = nil
        teardown()
    }
    private func teardown() {
        capture?.stop(); capture = nil; isRunning = false; inputLevel = 0
        _ = flush()
        if let outputObserver { NotificationCenter.default.removeObserver(outputObserver) }; outputObserver = nil
        if let engine { _ = VoiceAudioBoundary.stop(engine) }
        engine = nil; player = nil; chunker = VoicePCM.Chunker()
    }
    private func rebuild() {
        guard wantedRunning else { return }
        let played = flush(); onPlaybackInterrupted?(played.playedMilliseconds)
        generation = UUID(); startID = nil; teardown()
        rebuildTask?.cancel()
        let id = UUID(); recoveryGeneration = id
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await VoiceAudioStartup.start(attempt: { try await self.start() }, shouldContinue: { self.recoveryGeneration == id })
            } catch is CancellationError { }
            catch {
                guard self.recoveryGeneration == id else { return }
                let issue = error as? AudioError ?? .graph
                self.failure = issue; self.onError?(issue)
            }
        }
    }
    private static func makePlaybackGraph() throws -> (AVAudioEngine, AVAudioPlayerNode) {
        let graph = AVAudioEngine(), node = AVAudioPlayerNode()
        do {
            guard let output = VoiceAudioBoundary.outputFormat(for: graph), output.sampleRate.isFinite,
                  output.sampleRate > 0, output.channelCount > 0 else { throw AudioError.noOutputDevice }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: VoicePCM.sampleRate, channels: 1) else { throw AudioError.conversion }
            if VoiceAudioBoundary.connectPlayer(node, engine: graph, format: format) != nil { throw AudioError.graph }
            if VoiceAudioBoundary.start(graph) != nil { throw AudioError.graph }
            return (graph, node)
        } catch { _ = VoiceAudioBoundary.stop(graph); throw error }
    }
    private func checkAudioOperation(_ error: Error?) throws {
        if error != nil { throw AudioError.graph }
    }
    /// itemID must be the server's audio item ID. It scopes flush's played-duration result.
    func enqueuePCM16(_ data: Data, itemID: String) throws {
        guard isRunning, data.count % 2 == 0 else { throw AudioError.graph }
        guard !data.isEmpty else { return }
        if player == nil {
            let pair = try makePlayback(); engine = pair.0; player = pair.1
            let id = generation, outputID = ObjectIdentifier(pair.0)
            outputObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: pair.0, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let engine = self.engine, ObjectIdentifier(engine) == outputID, self.generation == id, self.player != nil else { return }
                    let played = self.flush(); self.onPlaybackInterrupted?(played.playedMilliseconds)
                    if let observer = self.outputObserver { NotificationCenter.default.removeObserver(observer) }; self.outputObserver = nil
                    if let engine = self.engine { _ = VoiceAudioBoundary.stop(engine) }
                    self.engine = nil; self.player = nil
                }
            }
        }
        guard let player, let format = AVAudioFormat(standardFormatWithSampleRate: VoicePCM.sampleRate, channels: 1) else { throw AudioError.graph }
        let samples = VoicePCM.decode(data)
        guard !samples.isEmpty else { return }
        lastOutputLevel = min(1, VoicePCM.rms(samples) * 4)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw AudioError.conversion }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        // Responses are sequential: the answer after a tool call queues behind the words still playing
        // ("let me check…") instead of cutting them off. Only barge-in or Stop flushes.
        if segments.last?.item == itemID { segments[segments.count - 1].frames += Int64(samples.count) }
        else { segments.append(.init(item: itemID, start: queuedFrames, frames: Int64(samples.count))) }
        queuedFrames += Int64(samples.count)
        let end = queuedFrames, id = playbackGeneration
        try checkAudioOperation(VoiceAudioBoundary.scheduleBuffer(buffer, player: player, completion: { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == id else { return }
                self.completedFrames = max(self.completedFrames, end)
                self.isPlaying = self.completedFrames < self.queuedFrames
            }
        }))
        isPlaying = true
    }
    /// Stops immediately, drops queued buffers and returns the audible item with its rendered (not queued) ms.
    @discardableResult func flush() -> VoicePlaybackStop {
        var rendered = completedFrames
        if let player, let time = player.lastRenderTime, let position = player.playerTime(forNodeTime: time) {
            // Render time leads the speakers by the downstream/device latency.
            let latencyFrames = Int64(max(0, player.outputPresentationLatency) * VoicePCM.sampleRate)
            rendered = max(rendered, position.sampleTime - latencyFrames)
        }
        let played = VoicePCM.stop(segments: segments, renderedFrames: rendered)
        playbackGeneration = UUID(); if let player { _ = VoiceAudioBoundary.stopPlayer(player) }
        queuedFrames = 0; completedFrames = 0; segments = []; isPlaying = false
        return played
    }
}

@MainActor
protocol VoiceMicrophone: AnyObject {
    func start(uid: String, samples: @escaping @MainActor (Data, Float) -> Void,
               failure: @escaping @MainActor (VoiceAudioEngine.AudioError) -> Void) async throws
    func stop()
}

/// Objective-C calls back on its capture worker. Construct those blocks outside actor isolation,
/// then explicitly hop to main; an Objective-C delegate must never enter an inferred @MainActor block.
@MainActor
final class VoiceCaptureInput: VoiceMicrophone {
    private let capture = VoiceMicrophoneCapture()
    func start(uid: String, samples: @escaping @MainActor (Data, Float) -> Void,
               failure: @escaping @MainActor (VoiceAudioEngine.AudioError) -> Void) async throws {
        try await Self.open(capture, uid: uid, samples: samples, failure: failure)
    }
    func stop() { capture.stop() }
    private nonisolated static func issue(_ error: NSError) -> VoiceAudioEngine.AudioError {
        switch error.code {
        case 1: return .noInputDevice
        case 2: return .selectedInputUnavailable
        case 4: return .conversion
        default: return .graph
        }
    }
    private nonisolated static func open(_ capture: VoiceMicrophoneCapture, uid: String,
                                        samples: @escaping @MainActor (Data, Float) -> Void,
                                        failure: @escaping @MainActor (VoiceAudioEngine.AudioError) -> Void) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                capture.start(withUID: uid, samples: { pcm, level in
                    Task { @MainActor in samples(pcm, level) }
                }, failure: { error in
                    let issue = issue(error as NSError)
                    Task { @MainActor in failure(issue) }
                }, completion: { error in
                    if let error { continuation.resume(throwing: issue(error as NSError)) }
                    else { continuation.resume() }
                })
            }
            try Task.checkCancellation()
        } onCancel: { capture.stop() }
    }
}
