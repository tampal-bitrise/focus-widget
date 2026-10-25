import AppKit

/// Modal dialogs. The app is a background (accessory) app, so each one activates it first.
enum Prompts {
    static func bringToFront() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Asks for a tag, offering recent tags in a combo box. Returns nil on cancel or empty input.
    static func tag(initial: String, recent: [String]) -> String? {
        bringToFront()
        let alert = NSAlert()
        alert.messageText = "What are you focusing on?"
        alert.informativeText = "Pick a recent tag or type a new one."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        combo.addItems(withObjectValues: recent)
        combo.completes = true
        combo.stringValue = initial
        combo.placeholderString = "e.g. coding, review, writing"
        alert.accessoryView = combo
        alert.window.initialFirstResponder = combo
        alert.window.level = .floating

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = combo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Records the next key press as a shortcut. Returns nil on Escape/Cancel.
    static func recordShortcut(current: KeyCombo) -> KeyCombo? {
        bringToFront()
        let alert = NSAlert()
        alert.messageText = "Record shortcut"
        alert.informativeText = """
            Press the key combination that should start and stop focus.
            It must include ⌘, ⌃ or ⌥. Current: \(current.displayString). Press Esc to cancel.
            """
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating

        var captured: KeyCombo?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                NSApp.stopModal(withCode: .cancel)
                return nil
            }
            guard let combo = KeyCombo(event: event) else {
                NSSound.beep()
                return nil
            }
            captured = combo
            NSApp.stopModal(withCode: .OK)
            return nil
        }
        alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        return captured
    }

    static func error(_ message: String) {
        bringToFront()
        let alert = NSAlert()
        alert.messageText = "Focus"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.window.level = .floating
        alert.runModal()
    }
}
