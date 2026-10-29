import AppKit
import Carbon.HIToolbox

struct GlobalShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

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
        guard carbon != 0, let key = event.charactersIgnoringModifiers?.uppercased(),
              !key.isEmpty, event.keyCode < 128 else { return nil }
        let prefix = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
        return GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: carbon, label: prefix + key)
    }
}

final class HotKeyController {
    static let shared = HotKeyController()
    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private(set) var lastRegistrationStatus: OSStatus = noErr

    private init() {}

    @discardableResult
    func register(_ shortcut: GlobalShortcut) -> OSStatus {
        unregister()
        if !handlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { controller.onPress?() }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
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

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
    }
}
