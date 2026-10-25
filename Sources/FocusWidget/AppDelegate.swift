import AppKit
import FocusCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Stops shorter than this are treated as accidental double-presses and discarded.
    private let minimumSessionSeconds = 5

    private var store: SessionStore!
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var hotKey: HotKey!
    private var statsHotKey: HotKey!
    private var ticker: Timer?
    private var current: Session?
    private var statsWindow: StatsWindowController?

    private let idleImage = NSImage(systemSymbolName: "timer", accessibilityDescription: "Focus: idle")
    private let runningImage = NSImage(systemSymbolName: "timer.circle.fill", accessibilityDescription: "Focus: running")
    private let statusFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    // MARK: - Preferences

    private let defaults = UserDefaults.standard

    /// Tag used by the next Start. Remembered across launches.
    private var tag: String {
        get { defaults.string(forKey: "tag") ?? "" }
        set { defaults.set(newValue, forKey: "tag") }
    }

    private var combo: KeyCombo {
        get {
            guard let data = defaults.data(forKey: "shortcut"),
                  let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) else { return .default }
            return combo
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "shortcut") }
    }

    private var stopOnSleep: Bool {
        get { defaults.object(forKey: "stopOnSleep") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stopOnSleep") }
    }

    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, no Dock icon

        do {
            store = try SessionStore(url: SessionStore.defaultURL)
        } catch {
            Prompts.error("Could not open the database at \(SessionStore.defaultURL.path).\n\n\(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }

        // A session left open by a previous run (quit, crash, reboot) simply resumes.
        current = store.current()
        if let current { tag = current.tag }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu

        hotKey = HotKey { [weak self] in self?.toggle() }
        if hotKey.register(combo) {
            FileHandle.standardError.write(Data("FocusWidget: shortcut \(combo.displayString) registered, database at \(store.url.path)\n".utf8))
        } else {
            Prompts.error("The shortcut \(combo.displayString) could not be registered. It may be taken by another app. Pick another one under Options › Change Shortcut.")
        }

        statsHotKey = HotKey(id: 2) { [weak self] in self?.toggleStats() }
        if !statsHotKey.register(.stats) {
            FileHandle.standardError.write(Data("FocusWidget: stats shortcut \(KeyCombo.stats.displayString) is taken, skipping\n".utf8))
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil
        )

        // `.common` keeps the clock ticking while a menu is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        refreshStatus()
    }

    // MARK: - Actions

    @objc func toggle() {
        if current != nil { stopSession() } else { startSession() }
    }

    @objc func startWithNewTag() {
        guard let picked = Prompts.tag(initial: tag, recent: store.recentTags()) else { return }
        tag = picked
        startSession()
    }

    @objc func selectTag(_ sender: NSMenuItem) {
        guard let picked = sender.representedObject as? String else { return }
        apply(tag: picked)
    }

    @objc func newTag() {
        guard let picked = Prompts.tag(initial: tag, recent: store.recentTags()) else { return }
        apply(tag: picked)
    }

    @objc func changeShortcut() {
        hotKey.unregister() // so the recorder can see the keys, including the current combo
        defer { if hotKey.combo == nil { hotKey.register(combo) } }
        guard let recorded = Prompts.recordShortcut(current: combo) else { return }
        if hotKey.register(recorded) {
            combo = recorded
        } else {
            Prompts.error("\(recorded.displayString) could not be registered. It may be reserved by the system or another app.")
        }
    }

    @objc func toggleStopOnSleep() {
        stopOnSleep.toggle()
    }

    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            Prompts.error("Could not change Launch at Login.\n\n\(error.localizedDescription)")
        }
    }

    @objc func showStats() {
        if statsWindow == nil { statsWindow = StatsWindowController(store: store, commands: self) }
        statsWindow?.show()
    }

    private func toggleStats() {
        if let statsWindow { statsWindow.toggle() } else { showStats() }
    }

    @objc func revealDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    @objc func systemWillSleep() {
        if stopOnSleep, current != nil { stopSession() }
    }

    // MARK: - Session control

    private func startSession() {
        if tag.isEmpty {
            guard let picked = Prompts.tag(initial: "", recent: store.recentTags()) else { return }
            tag = picked
        }
        do {
            current = try store.start(tag: tag)
        } catch {
            Prompts.error("Could not start the session.\n\n\(error.localizedDescription)")
        }
        refreshStatus()
        statsWindow?.reload()
    }

    private func stopSession() {
        do {
            try store.stop(minimumSeconds: minimumSessionSeconds)
        } catch {
            Prompts.error("Could not stop the session.\n\n\(error.localizedDescription)")
        }
        current = nil
        refreshStatus()
        statsWindow?.reload()
    }

    /// Sets the tag for the next session, and retags the running one if there is one.
    private func apply(tag newTag: String) {
        tag = newTag
        if let running = current {
            do {
                try store.retag(id: running.id, tag: newTag)
                current?.tag = newTag
            } catch {
                Prompts.error("Could not change the tag.\n\n\(error.localizedDescription)")
            }
        }
        refreshStatus()
        statsWindow?.reload()
    }

    // MARK: - Status item

    private func refreshStatus() {
        guard let button = statusItem.button else { return }
        if let current {
            let shownTag = current.tag.count > 18 ? String(current.tag.prefix(17)) + "…" : current.tag
            button.image = runningImage
            button.attributedTitle = NSAttributedString(
                string: " \(Format.clock(current.duration())) \(shownTag)",
                attributes: [.font: statusFont]
            )
        } else {
            button.image = idleImage
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcut = combo

        // Start / Stop
        let toggleItem: NSMenuItem
        if let current {
            toggleItem = NSMenuItem(
                title: "Stop  \(current.tag)  ·  \(Format.clock(current.duration()))",
                action: #selector(toggle), keyEquivalent: shortcut.menuKeyEquivalent
            )
            toggleItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        } else {
            toggleItem = NSMenuItem(
                title: tag.isEmpty ? "Start…" : "Start  \(tag)",
                action: #selector(toggle), keyEquivalent: shortcut.menuKeyEquivalent
            )
            toggleItem.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        }
        toggleItem.keyEquivalentModifierMask = shortcut.cocoaModifiers
        toggleItem.target = self
        menu.addItem(toggleItem)

        if current == nil {
            let newItem = NSMenuItem(title: "Start with New Tag…", action: #selector(startWithNewTag), keyEquivalent: "n")
            newItem.target = self
            menu.addItem(newItem)
        }
        menu.addItem(.separator())

        // Tag picker
        let tagItem = NSMenuItem(title: tag.isEmpty ? "Tag: none" : "Tag: \(tag)", action: nil, keyEquivalent: "")
        let tagMenu = NSMenu()
        for recent in store.recentTags(limit: 15) {
            let item = NSMenuItem(title: recent, action: #selector(selectTag(_:)), keyEquivalent: "")
            item.representedObject = recent
            item.state = recent == tag ? .on : .off
            item.target = self
            tagMenu.addItem(item)
        }
        if tagMenu.items.isEmpty == false { tagMenu.addItem(.separator()) }
        let newTagItem = NSMenuItem(title: "New Tag…", action: #selector(newTag), keyEquivalent: "t")
        newTagItem.target = self
        tagMenu.addItem(newTagItem)
        tagItem.submenu = tagMenu
        menu.addItem(tagItem)
        menu.addItem(.separator())

        // Today
        let totals = store.totals(since: Calendar.current.startOfDay(for: Date()))
        let todaySeconds = totals.reduce(0) { $0 + $1.seconds }
        menu.addItem(disabledItem("Today  ·  \(Format.hoursMinutes(todaySeconds))"))
        for total in totals.prefix(8) {
            let item = disabledItem("")
            item.attributedTitle = columns(total.tag, Format.hoursMinutes(total.seconds))
            item.indentationLevel = 1
            menu.addItem(item)
        }
        let statsItem = NSMenuItem(title: "Stats…", action: #selector(showStats), keyEquivalent: KeyCombo.stats.menuKeyEquivalent)
        statsItem.keyEquivalentModifierMask = KeyCombo.stats.cocoaModifiers
        statsItem.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)
        statsItem.target = self
        menu.addItem(statsItem)
        menu.addItem(.separator())

        // Options
        let optionsItem = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        let options = NSMenu()
        let shortcutItem = NSMenuItem(title: "Change Shortcut…  (\(shortcut.displayString))", action: #selector(changeShortcut), keyEquivalent: "")
        shortcutItem.target = self
        options.addItem(shortcutItem)
        let sleepItem = NSMenuItem(title: "Stop When Mac Sleeps", action: #selector(toggleStopOnSleep), keyEquivalent: "")
        sleepItem.state = stopOnSleep ? .on : .off
        sleepItem.target = self
        options.addItem(sleepItem)
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginItem.target = isBundled ? self : nil // only works from a .app bundle
        loginItem.toolTip = isBundled ? nil : "Available when running the built FocusWidget.app"
        options.addItem(loginItem)
        options.addItem(.separator())
        let revealItem = NSMenuItem(title: "Reveal Database in Finder", action: #selector(revealDatabase), keyEquivalent: "")
        revealItem.target = self
        options.addItem(revealItem)
        optionsItem.submenu = options
        menu.addItem(optionsItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Focus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// "tag ........ 1h 40m" with the duration right-aligned on a tab stop.
    private func columns(_ left: String, _ right: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(type: .rightTabStopType, location: 230)]
        return NSAttributedString(
            string: "\(left)\t\(right)",
            attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style]
        )
    }
}

// MARK: - Stats window commands

extension AppDelegate: SessionCommands {
    var nextTag: String { tag }

    func toggleFocus() { toggle() }

    func startFocus(tag newTag: String) {
        tag = newTag
        startSession()
    }

    func stopFocus() {
        if current != nil { stopSession() }
    }

    func retagFocus(_ newTag: String) { apply(tag: newTag) }
}
