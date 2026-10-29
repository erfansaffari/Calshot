import AVFoundation
import Combine

/// Pure PCM helpers. Wire format is signed little-endian PCM16, mono, 24 kHz.
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

/// Main-actor graph ownership. Conversion runs on AVAudioEngine's tap thread; UI/callbacks run on main.
/// Initialization never prompts or acquires the microphone. Step D must request permission explicitly.
@MainActor
final class VoiceAudioEngine: ObservableObject {
    enum MicrophonePermission: Equatable { case authorized, denied, restricted, notDetermined }
    enum AudioError: Error, Equatable { case permission(MicrophonePermission), noInputDevice, conversion, graph }
    @Published private(set) var isRunning = false
    @Published private(set) var isPlaying = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var failure: AudioError?
    var onInput: ((Data) -> Void)?
    var onError: ((AudioError) -> Void)?
    /// A device rebuild flushes queued output. Caller can truncate/cancel the interrupted server item.
    var onPlaybackInterrupted: ((Int) -> Void)?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observer: NSObjectProtocol?
    private var generation = UUID()
    private var playbackGeneration = UUID()
    private var queuedFrames: Int64 = 0
    private var completedFrames: Int64 = 0
    private var itemStart: Int64 = 0
    private var itemFrames: Int64 = 0
    private var currentItem: String?
    private var wantedRunning = false
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
    func start() throws {
        guard !isRunning else { return }
        guard Self.microphonePermission == .authorized else { throw AudioError.permission(Self.microphonePermission) }
        wantedRunning = true
        do { try buildGraph(); failure = nil } catch {
            stop(); let typed = error as? AudioError ?? .graph; failure = typed; throw typed
        }
    }
    func stop() {
        wantedRunning = false; generation = UUID()
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        _ = flush(); engine?.inputNode.removeTap(onBus: 0); engine?.stop()
        engine = nil; player = nil; isRunning = false; inputLevel = 0
    }
    private func buildGraph() throws {
        let graph = AVAudioEngine(), node = AVAudioPlayerNode()
        let input = graph.inputNode
        guard input.inputFormat(forBus: 0).sampleRate > 0, input.inputFormat(forBus: 0).channelCount > 0 else { throw AudioError.noInputDevice }
        // Some devices do not support voice processing; capture remains available there.
        try? input.setVoiceProcessingEnabled(true)
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: VoicePCM.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: source, to: mono) else { throw AudioError.conversion }
        graph.attach(node); graph.connect(node, to: graph.mainMixerNode, format: mono)
        let id = UUID(); generation = id
        // Tap state belongs exclusively to the serial input callback, never to the main actor.
        let pipeline = InputPipeline(converter: converter, outputFormat: mono)
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { [weak self] buffer, _ in
            let result = pipeline.process(buffer)
            Task { @MainActor [weak self] in
                guard let self, self.generation == id, self.wantedRunning else { return }
                if result.failed { self.failure = .conversion; self.onError?(.conversion); return }
                self.inputLevel = result.level
                for chunk in result.chunks { self.onInput?(chunk) }
            }
        }
        engine = graph; player = node
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: graph, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuild() }
        }
        graph.prepare(); try graph.start(); isRunning = true
    }
    private func rebuild() {
        guard wantedRunning else { return }
        let played = flush(); onPlaybackInterrupted?(played)
        stop()
        do { try start() } catch {
            let typed = error as? AudioError ?? .graph
            failure = typed; onError?(typed)
        }
    }
    /// itemID must be the server's audio item ID. It scopes flush's played-duration result.
    func enqueuePCM16(_ data: Data, itemID: String) throws {
        guard isRunning, let player, let format = AVAudioFormat(standardFormatWithSampleRate: VoicePCM.sampleRate, channels: 1),
              data.count % 2 == 0 else { throw AudioError.graph }
        let samples = VoicePCM.decode(data)
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw AudioError.conversion }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        // Responses are sequential. Flush any prior item's tail before changing the truncation scope.
        if currentItem != itemID {
            if isPlaying { _ = flush() }
            currentItem = itemID; itemStart = queuedFrames; itemFrames = 0
        }
        itemFrames += Int64(samples.count); queuedFrames += Int64(samples.count)
        let end = queuedFrames, id = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == id else { return }
                self.completedFrames = max(self.completedFrames, end)
                self.isPlaying = self.completedFrames < self.queuedFrames
            }
        }
        if !player.isPlaying { player.play() }
        isPlaying = true
    }
    /// Stops immediately, drops queued buffers and returns rendered (not queued) ms for this item.
    @discardableResult func flush() -> Int {
        var rendered = completedFrames
        if let player, let time = player.lastRenderTime, let position = player.playerTime(forNodeTime: time) {
            // Render time leads the speakers by the downstream/device latency.
            let latencyFrames = Int64(max(0, player.outputPresentationLatency) * VoicePCM.sampleRate)
            rendered = max(rendered, position.sampleTime - latencyFrames)
        }
        let played = VoicePCM.playedMilliseconds(renderedFrames: rendered, itemStartFrame: itemStart, itemFrames: itemFrames)
        playbackGeneration = UUID(); player?.stop()
        queuedFrames = 0; completedFrames = 0; itemStart = 0; itemFrames = 0; currentItem = nil; isPlaying = false
        return played
    }
}

/// AVAudioConverter and chunker are used only by the input tap, which AVAudioEngine serializes.
private final class InputPipeline {
    let converter: AVAudioConverter
    let outputFormat: AVAudioFormat
    var chunker = VoicePCM.Chunker()
    init(converter: AVAudioConverter, outputFormat: AVAudioFormat) { self.converter = converter; self.outputFormat = outputFormat }
    func process(_ input: AVAudioPCMBuffer) -> (chunks: [Data], level: Float, failed: Bool) {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * VoicePCM.resamplingRatio(from: input.format.sampleRate))) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return ([], 0, true) }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, error == nil, let pointer = output.floatChannelData?[0] else { return ([], 0, true) }
        let samples = Array(UnsafeBufferPointer(start: pointer, count: Int(output.frameLength)))
        return (chunker.append(VoicePCM.encode(samples)), VoicePCM.rms(samples), false)
    }
}
