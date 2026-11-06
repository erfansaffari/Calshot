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

    static let captureDefaultsKey = "globalShortcut", voiceDefaultsKey = "voice.shortcut"

    static func load(key: String, fallback: GlobalShortcut, from defaults: UserDefaults) -> GlobalShortcut {
        guard let data = defaults.data(forKey: key), var value = try? JSONDecoder().decode(GlobalShortcut.self, from: data) else { return fallback }
        // Older versions saved a label from JavaScript, which could read ⌃⌥√ for ⌃⌥V.
        if keyName(value.keyCode) != nil { value.label = label(keyCode: value.keyCode, modifiers: value.modifiers) }
        return value
    }

    static let supportedModifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    /// Marks a shortcut made only of held modifiers, like ⌃⌥. macOS hot keys need a real key, so these are watched instead.
    static let modifierOnlyKeyCode: UInt32 = 0xFFFF
    var isModifierOnly: Bool { keyCode == Self.modifierOnlyKeyCode }

    func sameKeys(as other: GlobalShortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }

    /// Native code builds every shortcut, label included, from the key the user actually pressed.
    static func candidate(from event: NSEvent) -> GlobalShortcut {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let carbon = carbonModifiers(flags), code = UInt32(event.keyCode)
        return GlobalShortcut(keyCode: code, modifiers: carbon, label: label(keyCode: code, modifiers: carbon))
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    static func modifierOnly(_ flags: NSEvent.ModifierFlags) -> GlobalShortcut {
        let carbon = carbonModifiers(flags)
        return GlobalShortcut(keyCode: modifierOnlyKeyCode, modifiers: carbon, label: label(keyCode: modifierOnlyKeyCode, modifiers: carbon))
    }

    static func label(keyCode: UInt32, modifiers: UInt32) -> String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "")
            + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "")
            + (keyCode == modifierOnlyKeyCode ? "" : keyName(keyCode) ?? "Key \(keyCode)")
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"]

    /// A registrable key's name in the ASCII keyboard layout, or nil for Return, Tab, arrows and other keys Calshot does not accept.
    static func keyName(_ keyCode: UInt32) -> String? {
        if let name = namedKeys[Int(keyCode)] { return name }
        guard keyCode < 128, let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0, length = 0, characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(base, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length).uppercased()
        let printable = text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains($0) && !$0.properties.isNoncharacterCodePoint && $0.value < 0xE000 }
        return printable ? text : nil
    }

    /// Why this combination cannot be registered, in the words shown beside the control.
    var problem: String? {
        if isModifierOnly {
            let count = [cmdKey, shiftKey, optionKey, controlKey].filter { modifiers & UInt32($0) != 0 }.count
            return count >= 2 && modifiers & UInt32(controlKey) != 0 ? nil : "To use modifier keys alone, hold ⌃ with one more, like ⌃⌥."
        }
        guard modifiers & ~Self.supportedModifiers == 0, modifiers & UInt32(cmdKey | controlKey) != 0 else { return "Include ⌃ or ⌘ in the shortcut." }
        guard modifiers != UInt32(cmdKey) else { return "⌘ with one key belongs to other apps, like ⌘C and ⌘V. Add ⌃, ⌥ or ⇧." }
        guard Self.keyName(keyCode) != nil else { return "Use a letter, number, symbol, Space or function key." }
        return nil
    }

    /// Calshot's own menu command. It can't be changed, so a global shortcut must not take it.
    static let quickMenu = GlobalShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘K")

    /// macOS keyboard shortcuts turned on in System Settings. macOS can take these without failing registration.
    static func isReservedBySystem(_ shortcut: GlobalShortcut) -> Bool {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let items = array?.takeRetainedValue() as? [[String: Any]] else { return false }
        return items.contains { item in
            guard (item[kHISymbolicHotKeyEnabled] as? Bool) == true, let code = item[kHISymbolicHotKeyCode] as? Int,
                  let modifiers = item[kHISymbolicHotKeyModifiers] as? Int else { return false }
            return UInt32(truncatingIfNeeded: code) == shortcut.keyCode && UInt32(truncatingIfNeeded: modifiers) & supportedModifiers == shortcut.modifiers
        }
    }
}

enum ShortcutTarget: String, Codable, CaseIterable {
    case capture, voice
    var name: String { self == .capture ? "capture" : "voice" }
}

/// The registration calls the model depends on, so tests never touch the Mac's real hot keys.
protocol HotKeyRegistering: AnyObject {
    @discardableResult func register(_ shortcut: GlobalShortcut) -> OSStatus
    @discardableResult func registerVoice(_ shortcut: GlobalShortcut) -> OSStatus
    func unregister()
    func unregisterVoice()
}

/// Decides when a held modifier chord counts as a press. The short wait lets combinations such as ⌃⌥← belong to other apps.
struct ModifierHoldDetector {
    static let holdDelay: TimeInterval = 0.18
    let modifiers: UInt32
    private var chordStart: Date?
    private var pressed = false
    private var spoiled = false
    init(modifiers: UInt32) { self.modifiers = modifiers }

    /// Returns true or false when the press state changes. `otherKeyDown` is any non-modifier key being held.
    mutating func update(modifiers current: UInt32, otherKeyDown: Bool, now: Date) -> Bool? {
        guard current == modifiers else {
            chordStart = nil
            if current == 0 { spoiled = false }
            if pressed { pressed = false; return false }
            return nil
        }
        if otherKeyDown { spoiled = true }
        guard !pressed, !spoiled else { return nil }
        guard let start = chordStart else { chordStart = now; return nil }
        guard now.timeIntervalSince(start) >= Self.holdDelay else { return nil }
        pressed = true
        return true
    }
}

final class HotKeyController: HotKeyRegistering {
    static let shared = HotKeyController()
    var onPress: (() -> Void)?
    /// Voice is push-to-talk: true on key down, false on key up.
    var onVoicePress: ((Bool) -> Void)?
    private var voiceRef: EventHotKeyRef?
    private var modifierTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private(set) var lastRegistrationStatus: OSStatus = noErr

    private init() {}

    private func installHandlerIfNeeded() -> OSStatus {
        guard !handlerInstalled else { return noErr }
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
            var key = EventHotKeyID()
            if let event { GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key) }
            let id = key.id, pressed = event.map { GetEventKind($0) == UInt32(kEventHotKeyPressed) } ?? true
            DispatchQueue.main.async { controller.dispatch(id: id, pressed: pressed) }
            return noErr
        }, eventTypes.count, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), nil)
        if status == noErr { handlerInstalled = true }
        return status
    }

    @discardableResult
    func register(_ shortcut: GlobalShortcut) -> OSStatus {
        unregister()
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else { lastRegistrationStatus = handlerStatus; return handlerStatus }
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
    func unregisterVoice() {
        if let voiceRef { UnregisterEventHotKey(voiceRef); self.voiceRef = nil }
        modifierTimer?.invalidate(); modifierTimer = nil
    }
    /// Reading the modifier state needs no Accessibility or Input Monitoring permission, unlike watching keystrokes.
    private func watchModifiers(_ modifiers: UInt32) {
        var detector = ModifierHoldDetector(modifiers: modifiers)
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            let flags = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
            let other = (0..<UInt16(128)).contains { code in !Self.modifierKeyCodes.contains(Int(code)) && CGEventSource.keyState(.combinedSessionState, key: code) }
            if let pressed = detector.update(modifiers: GlobalShortcut.carbonModifiers(flags), otherKeyDown: other, now: Date()) {
                self?.dispatch(id: 2, pressed: pressed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierTimer = timer
    }
    private static let modifierKeyCodes: Set<Int> = [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function]
    @discardableResult func registerVoice(_ shortcut: GlobalShortcut) -> OSStatus {
        unregisterVoice()
        if shortcut.isModifierOnly { watchModifiers(shortcut.modifiers); return noErr }
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else { return handlerStatus }
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: OSType(0x43414C53), id: 2), GetApplicationEventTarget(), 0, &voiceRef)
    }
    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
    }
}
