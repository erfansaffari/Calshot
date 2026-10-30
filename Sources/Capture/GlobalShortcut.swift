import AppKit
import Carbon.HIToolbox

struct GlobalShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    static let voiceDefault = GlobalShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧V")

    static let `default` = GlobalShortcut(keyCode: UInt32(kVK_ANSI_C),
                                          modifiers: UInt32(controlKey | shiftKey),
                                          label: "⌃⇧C")

    static func from(_ event: NSEvent) -> GlobalShortcut? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        guard carbon & UInt32(cmdKey | controlKey) != 0, let key = event.charactersIgnoringModifiers?.uppercased(),
              !key.isEmpty, event.keyCode < 128 else { return nil }
        let prefix = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
        return GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: carbon, label: prefix + key)
    }
}

final class HotKeyController {
    static let shared = HotKeyController()
    var onPress: (() -> Void)?
    /// Voice is push-to-talk: true on key down, false on key up.
    var onVoicePress: ((Bool) -> Void)?
    private var voiceRef: EventHotKeyRef?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private(set) var lastRegistrationStatus: OSStatus = noErr

    private init() {}

    @discardableResult
    func register(_ shortcut: GlobalShortcut) -> OSStatus {
        unregister()
        if !handlerInstalled {
            var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                              EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
                var key = EventHotKeyID()
                if let event { GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key) }
                let id = key.id, pressed = event.map { GetEventKind($0) == UInt32(kEventHotKeyPressed) } ?? true
                DispatchQueue.main.async { controller.dispatch(id: id, pressed: pressed) }
                return noErr
            }, eventTypes.count, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), nil)
            guard handlerStatus == noErr else { lastRegistrationStatus = handlerStatus; return handlerStatus }
            handlerInstalled = true
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x43414C53), id: 1)
        lastRegistrationStatus = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                                      GetApplicationEventTarget(), 0, &hotKeyRef)
        NSLog("Calshot: register shortcut %@ (keyCode=%u modifiers=%u), status=%d",
              shortcut.label, shortcut.keyCode, shortcut.modifiers, lastRegistrationStatus)
        return lastRegistrationStatus
    }

    func dispatch(id: UInt32, pressed: Bool = true) {
        switch id { case 1: if pressed { onPress?() }; case 2: onVoicePress?(pressed); default: break }
    }
    func unregisterVoice() { if let voiceRef { UnregisterEventHotKey(voiceRef); self.voiceRef = nil } }
    @discardableResult func registerVoice(_ shortcut: GlobalShortcut) -> OSStatus {
        if let voiceRef { UnregisterEventHotKey(voiceRef); self.voiceRef = nil }
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: OSType(0x43414C53), id: 2), GetApplicationEventTarget(), 0, &voiceRef)
    }
    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
    }
}
