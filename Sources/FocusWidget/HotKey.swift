import AppKit
import Carbon

/// A global keyboard shortcut, stored in Carbon terms so it can be re-registered on launch.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// Human-readable key name ("F", "Space", "F5"), captured when the shortcut was recorded.
    var label: String

    /// Control + Option + F
    static let `default` = KeyCombo(
        keyCode: UInt32(kVK_ANSI_F),
        carbonModifiers: UInt32(controlKey | optionKey),
        label: "F"
    )

    /// Control + Option + S, opens and closes the stats window.
    static let stats = KeyCombo(
        keyCode: UInt32(kVK_ANSI_S),
        carbonModifiers: UInt32(controlKey | optionKey),
        label: "S"
    )

    init(keyCode: UInt32, carbonModifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.label = label
    }

    /// Builds a combo from a key-down event. Returns nil unless ⌘, ⌃ or ⌥ is held,
    /// so a recorded shortcut can never swallow plain typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: mods, label: KeyCombo.keyName(for: event))
    }

    /// "⌃⌥F"
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }

    /// Cocoa flags, for showing the shortcut next to a menu item.
    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// Key equivalent string for an NSMenuItem, or "" when the key has no single-character form.
    var menuKeyEquivalent: String {
        label.count == 1 ? label.lowercased() : ""
    }

    private static let specialNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func keyName(for event: NSEvent) -> String {
        if let name = specialNames[Int(event.keyCode)] { return name }
        if let chars = event.charactersIgnoringModifiers,
           let scalar = chars.unicodeScalars.first, scalar.value >= 0x20 {
            return chars.uppercased()
        }
        return "Key \(event.keyCode)"
    }
}

/// Registers a system-wide hotkey through Carbon. Works without Accessibility permission.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let hotKeyID: EventHotKeyID
    private let onPress: () -> Void
    private(set) var combo: KeyCombo?

    /// `id` tells several HotKey instances apart; each one only handles its own presses.
    init(id: UInt32 = 1, onPress: @escaping () -> Void) {
        hotKeyID = EventHotKeyID(signature: 0x464F_4355 /* "FOCU" */, id: id)
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed
            )
            guard status == noErr else { return status }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            guard pressed.signature == hotKey.hotKeyID.signature, pressed.id == hotKey.hotKeyID.id else {
                return OSStatus(eventNotHandledErr)
            }
            hotKey.onPress()
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Replaces the current registration. Returns false if the system refused the combo.
    @discardableResult
    func register(_ combo: KeyCombo) -> Bool {
        unregister()
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard status == noErr else {
            hotKeyRef = nil
            return false
        }
        self.combo = combo
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        combo = nil
    }
}
