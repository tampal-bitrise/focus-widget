import AppKit
import Charts
import FocusCore
import SwiftUI

/// What the stats window may do to sessions. Implemented by AppDelegate, so keys, menu and hotkey share one path.
protocol SessionCommands: AnyObject {
    /// Tag the next start uses; empty until one has been picked.
    var nextTag: String { get }
    func toggleFocus()
    /// Starts a session on `tag`, closing the running one first.
    func startFocus(tag: String)
    func stopFocus()
    /// Sets the tag for the next session and retags the running one.
    func retagFocus(_ tag: String)
}

/// The stats window: chrome-less, driven by vim-style keys. Created on first open and kept around.
final class StatsWindowController: NSWindowController, NSWindowDelegate {
    private let model: StatsModel
    private weak var commands: SessionCommands?
    /// Smallest window size at which every panel still fits without clipping.
    private static let minimumSize = NSSize(width: 1100, height: 840)
    private var keyMonitor: Any?

    init(store: SessionStore, commands: SessionCommands) {
        model = StatsModel(store: store)
        self.commands = commands
        // Titled (so it can become key and be resized) but with the title bar, title and buttons hidden.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Focus Stats"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.background)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: StatsView(model: model))
        hosting.sizingOptions = [] // the window decides the size and the content fits it, not the other way round
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1240, height: 880))
        window.center()
        window.setFrameAutosaveName("FocusStats")
        super.init(window: window)
        window.delegate = self

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event) ? nil : event
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func show() {
        model.reload()
        Prompts.bringToFront()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Opens the window, or closes it when it is already in front.
    func toggle() {
        if NSApp.isActive, window?.isKeyWindow == true { close() } else { show() }
    }

    func reload() {
        if window?.isVisible == true { model.reload() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.reload()
    }

    // Enforced here rather than with `minSize`, which the hosting view keeps resetting.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, Self.minimumSize.width), height: max(frameSize.height, Self.minimumSize.height))
    }

    func windowWillClose(_ notification: Notification) {
        model.commandLine = nil
        model.showHelp = false
        model.message = nil
        NSApp.hide(nil) // hand focus back to the app that was in front before
    }

    // MARK: - Keys

    /// Returns true when the key was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false } // ⌘W, ⌘Q, … keep working
        let key = event.charactersIgnoringModifiers ?? ""

        if model.commandLine != nil {
            handleCommandLine(event, key: key, control: flags.contains(.control))
            return true
        }
        model.message = nil

        if flags.contains(.control) { return false }
        if event.keyCode == 53 { model.showHelp = false; return true } // Esc

        switch key {
        case " ", "s": toggleFocus()
        case "x": stopFocus()
        case "1"..."9": startNumbered(Int(key)! - 1)
        case ":": model.commandLine = ""
        case "i": model.commandLine = "start "
        case "t": model.commandLine = "tag "
        case "r": model.reload(); info("reloaded")
        case "?": model.showHelp.toggle()
        case "q": if model.showHelp { model.showHelp = false } else { close() }
        default: return false
        }
        return true
    }

    private func handleCommandLine(_ event: NSEvent, key: String, control: Bool) {
        guard let line = model.commandLine else { return }
        if control {
            if key == "u" { model.commandLine = "" } // clear line
            if key == "w" { model.commandLine = Self.deletingLastWord(line) }
            if key == "c" { model.commandLine = nil }
            return
        }
        switch event.keyCode {
        case 53: model.commandLine = nil // Esc
        case 36, 76: // Return, Enter
            model.commandLine = nil
            run(line)
        case 51: model.commandLine = line.isEmpty ? nil : String(line.dropLast()) // ⌫ on an empty line leaves, like vim
        case 48: complete(line) // Tab
        default:
            guard let chars = event.characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && $0.value < 0xF700 }) else { return }
            model.commandLine = line + chars
        }
    }

    private func run(_ line: String) {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard let name = parts.first.map(String.init) else { return }
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "s", "start":
            let tag = argument.isEmpty ? commands?.nextTag ?? "" : argument
            guard !tag.isEmpty else { return error("E471: Argument required: :start <tag>") }
            startFocus(tag)
        case "stop": stopFocus()
        case "t", "tag":
            guard let commands else { return }
            if argument.isEmpty {
                info(commands.nextTag.isEmpty ? "no tag set" : "tag: \(commands.nextTag)")
            } else {
                commands.retagFocus(argument)
                info(model.running != nil ? "retagged → \(argument)" : "next tag: \(argument)")
            }
        case "e", "reload": model.reload(); info("reloaded")
        case "h", "help": model.showHelp = true
        case "q", "q!", "quit", "wq", "close": close()
        default: error("E492: Not an editor command: \(line)")
        }
    }

    /// Completes the tag argument of :start / :tag from recently used tags.
    private func complete(_ line: String) {
        guard let space = line.firstIndex(of: " "), ["s", "start", "t", "tag"].contains(String(line[..<space])) else { return }
        let prefix = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
        let matches = model.recentTags().filter { $0.hasPrefix(prefix) }
        guard let first = matches.first else { return error("no tag matches \"\(prefix)\"") }
        // Repeated Tab cycles through the matches.
        let next = matches.firstIndex(of: prefix).map { matches[($0 + 1) % matches.count] } ?? first
        model.commandLine = line[..<space] + " " + next
    }

    // MARK: - Session actions

    private func toggleFocus() {
        let before = model.running
        commands?.toggleFocus()
        model.reload()
        if let running = model.running {
            info("▶ started \(running.tag)")
        } else if let before {
            info("■ stopped \(before.tag) · \(Format.clock(before.duration()))")
        }
    }

    private func startFocus(_ tag: String) {
        guard model.running?.tag != tag else { return info("already on \(tag)") }
        commands?.startFocus(tag: tag)
        model.reload()
        info("▶ started \(tag)")
    }

    private func stopFocus() {
        guard let running = model.running else { return info("nothing running") }
        commands?.stopFocus()
        model.reload()
        info("■ stopped \(running.tag) · \(Format.clock(running.duration()))")
    }

    private func startNumbered(_ index: Int) {
        let tags = model.numberedTags
        guard index < tags.count else { return error("no tag #\(index + 1)") }
        startFocus(tags[index])
    }

    private func info(_ text: String) { model.message = StatusMessage(text: text, isError: false) }
    private func error(_ text: String) { model.message = StatusMessage(text: text, isError: true) }

    private static func deletingLastWord(_ line: String) -> String {
        var line = line
        while line.last == " " { line.removeLast() }
        while let last = line.last, last != " " { line.removeLast() }
        return line
    }
}

// MARK: - Model

struct StatusMessage: Equatable {
    let text: String
    let isError: Bool
}

final class StatsModel: ObservableObject {
    @Published private(set) var stats = FocusStats(sessions: [])
    @Published private(set) var recent: [Session] = []
    @Published private(set) var running: Session?
    /// Text after ":" while the command line is open; nil in normal mode.
    @Published var commandLine: String?
    @Published var message: StatusMessage?
    @Published var showHelp = false
    let databasePath: String
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
        databasePath = (store.url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Tags reachable with 1–9, in the order the tag panel lists them.
    var numberedTags: [String] { stats.tags.prefix(9).map(\.tag) }

    func recentTags() -> [String] { store.recentTags(limit: 50) }

    func reload() {
        let all = store.sessions(since: .distantPast)
        stats = FocusStats(sessions: all)
        recent = Array(all.prefix(9))
        running = all.first(where: \.isRunning)
    }
}

// MARK: - Theme

/// Near-black panels, hairline borders, terminal-green accent.
private enum Theme {
    static let background = Color(hex: 0x080B10)
    static let panel = Color(hex: 0x0E131A)
    static let border = Color(hex: 0x1C2631)
    static let empty = Color(hex: 0x151D27)
    static let text = Color(hex: 0xD5DDE5)
    static let dim = Color(hex: 0x66727F)
    static let accent = Color(hex: 0x3DFF9A)
    static let cyan = Color(hex: 0x38BDF8)
    static let amber = Color(hex: 0xFFB547)
    static let series: [Color] = [accent, cyan, amber, Color(hex: 0xC084FC), Color(hex: 0xF472B6), Color(hex: 0x2DD4BF)]

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private enum Dates {
    static let short: DateFormatter = make("MMM d")
    static let iso: DateFormatter = make("yyyy-MM-dd")
    static let log: DateFormatter = make("MM-dd HH:mm")
    static let weekday: DateFormatter = make("EEEE")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - Root view

private struct StatsView: View {
    @ObservedObject var model: StatsModel
    private let refresh = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var stats: FocusStats { model.stats }

    var body: some View {
        // No scrolling: the chart row absorbs whatever height is left, everything else has a fixed height.
        VStack(alignment: .leading, spacing: 12) {
            header
            kpis.fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                Panel("DAILY OUTPUT", trailing: "LAST 30 DAYS · HOURS") { DailyChart(stats: stats) }
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                Panel("CLOCK PROFILE", trailing: "LAST 30 DAYS · MINUTES") { HourChart(stats: stats) }
                    .frame(width: 380)
            }
            .frame(maxHeight: .infinity)
            Panel("ACTIVITY MATRIX", trailing: "HOVER A DAY FOR DETAIL") { Heatmap(stats: stats) }
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                Panel("TAG ALLOCATION", trailing: "ALL TIME") { TagBars(stats: stats) }
                Panel("TRIVIA") { Trivia(stats: stats) }
                Panel("SESSION LOG", trailing: "LATEST \(model.recent.count)") { SessionLog(sessions: model.recent) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top) // the title bar is hidden, use its space too
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusLine(model: model) }
        .overlay { if model.showHelp { HelpOverlay() } }
        .background(Theme.background)
        .foregroundColor(Theme.text)
        .preferredColorScheme(.dark)
        .onReceive(refresh) { _ in model.reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                (Text("◷ FOCUS").foregroundColor(Theme.accent) + Text(" // TELEMETRY").foregroundColor(Theme.text))
                    .font(Theme.mono(20, .bold))
                Text(subtitle)
                    .font(Theme.mono(10))
                    .foregroundColor(Theme.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            LiveBadge(running: model.running)
        }
    }

    private var subtitle: String {
        let since = stats.firstStart.map { "SINCE \(Dates.iso.string(from: $0))" } ?? "NO DATA YET"
        return "\(since) · DB \(model.databasePath)"
    }

    private var kpis: some View {
        let week = stats.seconds(from: stats.weekStart, to: .distantFuture)
        let lastWeekStart = stats.calendar.date(byAdding: .day, value: -7, to: stats.weekStart) ?? stats.weekStart
        let lastWeek = stats.seconds(from: lastWeekStart, to: stats.weekStart)
        // Compare against last week up to the same weekday, so a fresh Monday isn't a -90% week.
        let sameDayLastWeek = stats.calendar.date(byAdding: .day, value: -6, to: stats.today) ?? stats.today
        let lastWeekToDate = stats.seconds(from: lastWeekStart, to: sameDayLastWeek)
        let sevenDayAverage = stats.dailyTotals(last: 7).reduce(0) { $0 + $1.seconds } / 7
        return HStack(spacing: 14) {
            Kpi(label: "TODAY", value: Format.hoursMinutes(stats.todaySeconds),
                detail: "7D AVG \(Format.hoursMinutes(sevenDayAverage))")
            Kpi(label: "THIS WEEK", value: Format.hoursMinutes(week),
                detail: "LAST WEEK \(Format.hoursMinutes(lastWeek))", delta: delta(week, lastWeekToDate))
            Kpi(label: "STREAK", value: "\(stats.currentStreak)d",
                detail: "BEST \(stats.longestStreak)d", color: stats.currentStreak > 0 ? Theme.amber : Theme.dim)
            Kpi(label: "ALL TIME", value: Format.hoursMinutes(stats.totalSeconds),
                detail: "\(stats.sessionCount) SESSIONS · \(stats.activeDays) DAYS", color: Theme.cyan)
        }
    }

    private func delta(_ now: Int, _ before: Int) -> String? {
        guard before > 0 else { return nil }
        let percent = Int((Double(now - before) / Double(before) * 100).rounded())
        return percent >= 0 ? "▲\(percent)%" : "▼\(-percent)%"
    }
}

// MARK: - Building blocks

private struct Panel<Content: View>: View {
    let title: String
    let trailing: String?
    let content: Content

    init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                (Text("▍").foregroundColor(Theme.accent) + Text(title).foregroundColor(Theme.text))
                    .font(Theme.mono(11, .semibold))
                    .tracking(1.2)
                Spacer()
                if let trailing {
                    Text(trailing).font(Theme.mono(9)).foregroundColor(Theme.dim).tracking(0.8)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct Kpi: View {
    let label: String
    let value: String
    let detail: String
    var delta: String? = nil
    var color: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(Theme.mono(10, .semibold)).foregroundColor(Theme.dim).tracking(1.2)
                Spacer()
                if let delta {
                    Text(delta).font(Theme.mono(10, .semibold))
                        .foregroundColor(delta.hasPrefix("▲") ? Theme.accent : Color(hex: 0xFF6B6B))
                }
            }
            Text(value)
                .font(Theme.mono(26, .bold))
                .foregroundColor(color)
                .shadow(color: color.opacity(0.35), radius: 8)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail).font(Theme.mono(9)).foregroundColor(Theme.dim).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(color.opacity(0.8)).frame(height: 2) }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct LiveBadge: View {
    let running: Session?

    var body: some View {
        if let running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let on = Int(context.date.timeIntervalSince1970) % 2 == 0
                HStack(spacing: 8) {
                    Circle().fill(Theme.accent).frame(width: 8, height: 8)
                        .opacity(on ? 1 : 0.3)
                        .shadow(color: Theme.accent, radius: on ? 6 : 0)
                    Text("REC").foregroundColor(Theme.accent)
                    Text(running.tag).foregroundColor(Theme.text)
                    Text(Format.clock(running.duration(now: context.date))).foregroundColor(Theme.accent)
                }
                .font(Theme.mono(12, .semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent.opacity(0.4), lineWidth: 1))
            }
        } else {
            HStack(spacing: 8) {
                Circle().stroke(Theme.dim, lineWidth: 1).frame(width: 8, height: 8)
                Text("IDLE")
            }
            .font(Theme.mono(12, .semibold))
            .foregroundColor(Theme.dim)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
        }
    }
}

// MARK: - Charts

private struct DailyChart: View {
    let stats: FocusStats

    var body: some View {
        let days = stats.dailyTotals(last: 30)
        let active = days.filter { $0.seconds > 0 }
        let average = active.isEmpty ? 0 : Double(active.reduce(0) { $0 + $1.seconds }) / Double(active.count) / 3600
        Chart {
            ForEach(days, id: \.day) { day in
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Hours", Double(day.seconds) / 3600)
                )
                .foregroundStyle(day.day == stats.today ? Theme.accent : Theme.accent.opacity(0.45))
                .cornerRadius(2)
            }
            if average > 0 {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Theme.amber)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("AVG/ACTIVE DAY \(Format.hoursMinutes(Int(average * 3600)))")
                            .font(Theme.mono(9)).foregroundColor(Theme.amber)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(Theme.mono(9)).foregroundStyle(Theme.dim)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.dim)
            }
        }
        .frame(minHeight: 100, maxHeight: .infinity)
    }
}

private struct HourChart: View {
    let stats: FocusStats

    var body: some View {
        let hours = stats.secondsByHour(last: 30)
        let peak = hours.contains { $0 > 0 } ? hours.indices.max { hours[$0] < hours[$1] } : nil
        Chart {
            ForEach(0..<24, id: \.self) { hour in
                BarMark(
                    x: .value("Hour", String(format: "%02d", hour)),
                    y: .value("Minutes", Double(hours[hour]) / 60)
                )
                .foregroundStyle(hour == peak ? Theme.amber : Theme.cyan.opacity(0.6))
                .cornerRadius(1.5)
            }
        }
        .chartXAxis {
            AxisMarks(values: ["00", "06", "12", "18"]) { value in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel {
                    if let hour = value.as(String.self) { Text(hour) }
                }
                .font(Theme.mono(9)).foregroundStyle(Theme.dim)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.dim)
            }
        }
        .frame(minHeight: 100, maxHeight: .infinity)
    }
}

/// Reports the mouse position in top-left based coordinates, or nil when it leaves. Uses an `.activeAlways`
/// tracking area so it works while another app is frontmost; clicks pass through.
private struct MouseTracker: NSViewRepresentable {
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.onMove = onMove }

    final class TrackingView: NSView {
        var onMove: ((CGPoint?) -> Void)?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
        override func mouseEntered(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { onMove?(nil) }
    }
}

/// GitHub-style contribution grid. Hover a cell for its date and total.
private struct Heatmap: View {
    let stats: FocusStats
    private let cellSize: CGFloat = 12
    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 28
    @State private var hovered: DayTotal?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Square cells of a fixed size; a wider window shows more weeks of history.
            GeometryReader { proxy in
                let weeks = max(4, Int((proxy.size.width - labelWidth + gap) / (cellSize + gap)))
                grid(stats.heatmap(weeks: weeks))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 7 * cellSize + 6 * gap)
            HStack(spacing: 4) {
                if let hovered {
                    (Text(Dates.iso.string(from: hovered.day)).foregroundColor(Theme.text)
                        + Text(" · ").foregroundColor(Theme.dim)
                        + Text(hovered.seconds == 0 ? "no focus" : Format.hoursMinutes(hovered.seconds))
                            .foregroundColor(hovered.seconds == 0 ? Theme.dim : Theme.accent))
                        .font(Theme.mono(9))
                }
                Spacer()
                Text("LESS").font(Theme.mono(8)).foregroundColor(Theme.dim)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(color(level: level)).frame(width: 10, height: 10)
                }
                Text("MORE").font(Theme.mono(8)).foregroundColor(Theme.dim)
            }
            .frame(height: 12) // the hover readout must not change the panel's height
        }
    }

    private func grid(_ grid: [[DayTotal?]]) -> some View {
        let maxSeconds = max(1, grid.joined().compactMap { $0?.seconds }.max() ?? 1)
        return HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .trailing, spacing: gap) {
                ForEach(0..<7, id: \.self) { row in
                    Text(row % 2 == 0 ? weekdayLabel(row) : " ")
                        .font(Theme.mono(8)).foregroundColor(Theme.dim)
                        .frame(height: cellSize)
                }
            }
            .frame(width: labelWidth - gap, alignment: .trailing)
            ForEach(grid.indices, id: \.self) { column in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        cell(grid[column][row], maxSeconds: maxSeconds)
                    }
                }
            }
        }
        // SwiftUI's onHover (and .help) only fire while the app is active; this tracker works in the background too.
        .overlay {
            MouseTracker { point in
                hovered = point.flatMap { point in
                    let column = Int((point.x - labelWidth) / (cellSize + gap))
                    let row = Int(point.y / (cellSize + gap))
                    guard point.x >= labelWidth, grid.indices.contains(column), (0..<7).contains(row) else { return nil }
                    return grid[column][row]
                }
            }
        }
    }

    private func cell(_ day: DayTotal?, maxSeconds: Int) -> some View {
        let level = day.map { $0.seconds == 0 ? 0 : 1 + min(3, Int(Double($0.seconds) / Double(maxSeconds) * 4)) } ?? -1
        return RoundedRectangle(cornerRadius: 2)
            .fill(level < 0 ? Color.clear : color(level: level))
            .overlay {
                if day != nil, day?.day == hovered?.day {
                    RoundedRectangle(cornerRadius: 2).stroke(Theme.amber, lineWidth: 1.5)
                } else if day?.day == stats.today {
                    RoundedRectangle(cornerRadius: 2).stroke(Theme.text.opacity(0.7), lineWidth: 1)
                }
            }
            .frame(width: cellSize, height: cellSize)
    }

    private func color(level: Int) -> Color {
        level == 0 ? Theme.empty : Theme.accent.opacity([0.25, 0.45, 0.7, 1.0][min(level, 4) - 1])
    }

    private func weekdayLabel(_ row: Int) -> String {
        let calendar = stats.calendar
        let symbols = calendar.shortWeekdaySymbols
        return symbols[(calendar.firstWeekday - 1 + row) % 7].uppercased()
    }
}

// MARK: - Text panels

private struct TagBars: View {
    let stats: FocusStats
    private let width = 12

    var body: some View {
        let tags = Array(stats.tags.prefix(9))
        let top = max(1, tags.first?.seconds ?? 1)
        VStack(alignment: .leading, spacing: 7) {
            if tags.isEmpty { Placeholder() }
            ForEach(Array(tags.enumerated()), id: \.element.tag) { index, total in
                let filled = max(1, Int((Double(total.seconds) / Double(top) * Double(width)).rounded()))
                let share = Int((Double(total.seconds) / Double(max(1, stats.totalSeconds)) * 100).rounded())
                let color = Theme.series[index % Theme.series.count]
                HStack(spacing: 8) {
                    Text("\(index + 1)").foregroundColor(Theme.dim)
                    Text(total.tag)
                        .foregroundColor(Theme.text)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(width: 84, alignment: .leading)
                    (Text(String(repeating: "█", count: filled)).foregroundColor(color)
                        + Text(String(repeating: "░", count: width - filled)).foregroundColor(Theme.border))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 4)
                    Text(Format.hoursMinutes(total.seconds)).foregroundColor(Theme.text)
                    Text("\(share)%").foregroundColor(Theme.dim).frame(width: 36, alignment: .trailing)
                }
                .font(Theme.mono(11))
            }
        }
    }
}

private struct Trivia: View {
    let stats: FocusStats

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if stats.sessionCount == 0 {
                Placeholder()
            } else {
                row("CHRONOTYPE", chronotype, Theme.amber)
                row("LONGEST RUN", longestRun)
                row("BEST DAY", stats.bestDay.map { "\(Dates.short.string(from: $0.day)) · \(Format.hoursMinutes($0.seconds))" } ?? "—")
                row("FAVORITE DAY", stats.peakWeekday.map { weekdayName($0) } ?? "—")
                row("AVG SESSION", Format.hoursMinutes(stats.averageSessionSeconds))
                row("DEEP BLOCKS ≥50M", "\(stats.deepSessionCount)", Theme.cyan)
                row("POMODOROS", "\(stats.totalSeconds / (25 * 60)) × 25m")
                row("LOTR EXTENDED", String(format: "%.2f× trilogies", Double(stats.totalSeconds) / Double(682 * 60)))
                row("TRACKING", "\(daysTracking) DAYS · \(stats.activeDays) ACTIVE")
            }
        }
    }

    private func row(_ key: String, _ value: String, _ color: Color = Theme.text) -> some View {
        HStack(spacing: 6) {
            Text(">").foregroundColor(Theme.accent)
            Text(key).foregroundColor(Theme.dim)
            Spacer(minLength: 8)
            Text(value).foregroundColor(color).lineLimit(1).minimumScaleFactor(0.75)
        }
        .font(Theme.mono(11))
    }

    private var chronotype: String {
        guard let hour = stats.peakHour else { return "—" }
        let label: String
        switch hour {
        case 4..<9: label = "EARLY BIRD"
        case 9..<12: label = "MORNING GRINDER"
        case 12..<17: label = "AFTERNOON CRUISER"
        case 17..<21: label = "EVENING SPRINTER"
        default: label = "NIGHT OWL"
        }
        return "\(label) · PEAK \(String(format: "%02d:00", hour))"
    }

    private var longestRun: String {
        guard let session = stats.longestSession else { return "—" }
        let seconds = Int(session.duration(now: stats.now))
        return "\(Format.clock(TimeInterval(seconds))) · \(session.tag)"
    }

    private var daysTracking: Int {
        guard let first = stats.firstStart else { return 0 }
        let days = stats.calendar.dateComponents([.day], from: stats.calendar.startOfDay(for: first), to: stats.today).day ?? 0
        return days + 1
    }

    private func weekdayName(_ index: Int) -> String {
        stats.calendar.weekdaySymbols[index].uppercased()
    }
}

private struct SessionLog: View {
    let sessions: [Session]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if sessions.isEmpty { Placeholder() }
            ForEach(sessions, id: \.id) { session in
                HStack(spacing: 10) {
                    Text(Dates.log.string(from: session.startedAt)).foregroundColor(Theme.dim)
                    Text(session.tag).foregroundColor(Theme.text).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    if session.isRunning {
                        Text("● LIVE").foregroundColor(Theme.accent)
                    } else {
                        Text(Format.clock(session.duration()))
                            .foregroundColor(session.duration() >= TimeInterval(FocusStats.deepWorkSeconds) ? Theme.cyan : Theme.text)
                    }
                }
                .font(Theme.mono(11))
            }
        }
    }
}

private struct Placeholder: View {
    var body: some View {
        Text("// no sessions yet — start one from the menu bar")
            .font(Theme.mono(11))
            .foregroundColor(Theme.dim)
    }
}


// MARK: - Keyboard UI

/// Vim-style status line: mode, then the command line or the last message, then key hints.
private struct StatusLine: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        let command = model.commandLine
        HStack(spacing: 10) {
            Text(command == nil ? "NORMAL" : "COMMAND")
                .font(Theme.mono(11, .bold))
                .foregroundColor(Theme.background)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .background(command == nil ? Theme.accent : Theme.amber)
            if let command {
                HStack(spacing: 0) {
                    Text(":" + command).foregroundColor(Theme.text)
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        Rectangle().fill(Theme.amber).frame(width: 7, height: 14)
                            .opacity(Int(context.date.timeIntervalSince1970 * 2) % 2 == 0 ? 1 : 0)
                    }
                }
            } else if let message = model.message {
                Text(message.text).foregroundColor(message.isError ? Color(hex: 0xFF6B6B) : Theme.text)
            }
            Spacer(minLength: 8)
            if command == nil {
                Text("␣ start/stop · 1-9 tag · : cmd · ? help").foregroundColor(Theme.dim).lineLimit(1)
            }
        }
        .font(Theme.mono(11))
        .padding(.trailing, 14)
        .frame(height: 24)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

private struct HelpOverlay: View {
    private static let keys: [(String, String)] = [
        ("space s", "start / stop session"),
        ("x", "stop session"),
        ("1-9", "start the numbered tag"),
        ("i", ":start …"),
        ("t", ":tag …"),
        ("r", "reload"),
        ("?", "toggle help"),
        ("q", "close window"),
    ]
    private static let commands: [(String, String)] = [
        (":s[tart] [tag]", "start / switch tag"),
        (":stop", "stop session"),
        (":t[ag] <tag>", "set tag, retag running"),
        (":e  :reload", "reload"),
        (":q", "close window"),
        ("tab", "complete tag name"),
        ("⌃u ⌃w", "clear line / word"),
        ("esc", "leave command line"),
        ("⌃⌥S", "open / close (global)"),
    ]

    var body: some View {
        ZStack {
            Theme.background.opacity(0.75)
            Panel("KEYBINDINGS", trailing: "? OR ESC TO CLOSE") {
                HStack(alignment: .top, spacing: 28) {
                    column("NORMAL", Self.keys)
                    column("COMMAND", Self.commands)
                }
            }
            .frame(width: 640)
            .shadow(color: .black.opacity(0.6), radius: 30)
        }
    }

    private func column(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.mono(9, .semibold)).foregroundColor(Theme.dim).tracking(1.2)
            ForEach(rows, id: \.0) { key, action in
                HStack(spacing: 10) {
                    Text(key).foregroundColor(Theme.accent).frame(width: 118, alignment: .leading)
                    Text(action).foregroundColor(Theme.text)
                }
                .font(Theme.mono(11))
            }
        }
    }
}
