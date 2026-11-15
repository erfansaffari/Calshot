import AppKit
import CoreAudio

/// Device-local input selection and a bounded, local-only test. Never creates an agent session.
@MainActor
final class VoiceInputSettings {
    struct Device: Equatable {
        let uid: String
        let name: String
    }
    let defaults: UserDefaults
    var onChange: (() -> Void)?
    private(set) var devices: [Device] = []
    private(set) var token = UUID().uuidString
    private(set) var testState = "idle"
    private(set) var error: String?
    private(set) var detectedSound = false
    private var generation = UUID()
    private var audio: (any VoiceAudio)?
    private var timeout: Task<Void, Never>?
    private let listDevices: () -> [Device]
    private let makeAudio: () -> any VoiceAudio
    private let permission: () async -> Bool
    private let duration: Duration
    private var hardwareListener: AudioObjectPropertyListenerBlock?
    private var resignObserver: NSObjectProtocol?
    private static let selectors: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    init(defaults: UserDefaults = .standard, devices: (() -> [Device])? = nil,
         makeAudio: (() -> any VoiceAudio)? = nil, permission: (() async -> Bool)? = nil,
         duration: Duration = .seconds(15), observesHardware: Bool = true) {
        self.defaults = defaults
        self.listDevices = devices ?? { VoiceAudioBoundary.inputDevices().compactMap { row in
            guard let uid = row["uid"] as? String, let name = row["name"] as? String else { return nil }
            return Device(uid: uid, name: name)
        } }
        self.makeAudio = makeAudio ?? { VoiceAudioEngine(defaults: defaults) }
        self.permission = permission ?? { await VoiceAudioEngine.requestMicrophonePermission() == .authorized }
        self.duration = duration
        refresh()
        guard observesHardware else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.testing { self.finish("failed", error: "The microphone connection changed. Check the selected input and test again.") }
                self.refresh()
            }
        }
        hardwareListener = listener
        for selector in Self.selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.testState == "testing" { self?.stopTest() } }
        }
    }
    var selectedUID: String { defaults.string(forKey: "voice.inputUID") ?? "" }
    var testing: Bool { testState == "checking" || testState == "testing" }
    var level: Float { testState == "testing" ? min(1, max(0, (audio?.inputLevel ?? 0) * 4)) : 0 }
    var selectedAvailable: Bool { selectedUID.isEmpty || devices.contains { $0.uid == selectedUID } }
    func refresh() {
        let next = listDevices().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if next != devices { devices = next; token = UUID().uuidString; onChange?() }
    }
    func configure(uid: String) throws {
        guard !testing else { throw CalendarToolArgumentError("Stop the microphone test before changing input.") }
        refresh()
        guard uid.isEmpty || devices.contains(where: { $0.uid == uid }) else { throw CalendarToolArgumentError("That microphone is no longer connected. Refresh the input list.") }
        defaults.set(uid, forKey: "voice.inputUID")
        error = nil; testState = "idle"; detectedSound = false; token = UUID().uuidString; onChange?()
    }
    func startTest() async {
        guard !testing else { return }
        refresh()
        guard selectedAvailable, !devices.isEmpty else {
            finish("failed", error: "No selected microphone is available. Connect it or choose another input."); return
        }
        generation = UUID(); let id = generation
        testState = "checking"; error = nil; detectedSound = false; token = UUID().uuidString; onChange?()
        let allowed = await permission()
        guard generation == id, testing else { return }
        guard allowed else { finish("failed", error: VoiceAudioEngine.AudioError.permission(.denied).localizedDescription); return }
        let audio = makeAudio(); self.audio = audio
        audio.onInput = { [weak self, weak audio] _ in
            guard let self, self.generation == id, self.testState == "testing" else { return }
            if !self.detectedSound, (audio?.inputLevel ?? 0) >= 0.002 {
                self.detectedSound = true; self.onChange?()
            }
        }
        audio.onError = { [weak self] issue in
            guard let self, self.generation == id else { return }
            self.finish("failed", error: issue.localizedDescription)
        }
        do {
            try await VoiceAudioStartup.start(attempt: { try await audio.start() }, shouldContinue: { self.generation == id && self.testing })
            guard generation == id, testing else { audio.stop(); return }
            testState = "testing"; onChange?()
            timeout = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: self.duration) } catch { return }
                guard self.generation == id else { return }
                self.finish("finished")
            }
        } catch {
            guard generation == id else { return }
            finish("failed", error: error.localizedDescription)
        }
    }
    func stopTest() { if testing { finish("cancelled") } }
    private func finish(_ state: String, error: String? = nil) {
        generation = UUID(); timeout?.cancel(); timeout = nil
        audio?.onInput = nil; audio?.onError = nil; audio?.stop(); audio = nil
        testState = state; self.error = error; token = UUID().uuidString; onChange?()
    }
    var snapshot: JSONValue { .object([
        "token": .string(token), "devices": .array(devices.map { .object(["uid": .string($0.uid), "name": .string($0.name)]) }),
        "selectedUID": .string(selectedUID), "selectedAvailable": .bool(selectedAvailable),
        "testState": .string(testState), "detectedSound": .bool(detectedSound),
        "error": error.map(JSONValue.string) ?? .null
    ]) }
    deinit {
        timeout?.cancel()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let hardwareListener {
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, hardwareListener)
            }
        }
    }
}
