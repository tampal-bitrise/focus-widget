// Self-checking smoke test for FocusCore. Run with `swift run FocusCheck` (or `make test`).
// Lives in an executable because Command Line Tools-only installs ship no XCTest/Swift Testing.
import Foundation
import FocusCore

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ label: String, file: String = #fileID, line: Int = #line) {
    if condition() {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)  (\(file):\(line))")
    }
}

func withStore(_ name: String, _ body: (SessionStore, URL) throws -> Void) {
    print(name)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focus-check-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("focus.sqlite")
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        try body(try SessionStore(url: url), url)
    } catch {
        failures += 1
        print("  FAIL threw \(error)")
    }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)

withStore("start/stop round trip") { store, _ in
    let started = try store.start(tag: "coding", at: t0)
    check(started.isRunning, "new session is running")
    check(store.current() == started, "current() returns it")
    let stopped = try store.stop(at: t0.addingTimeInterval(1500))
    check(stopped?.duration() == 1500, "duration is 1500s")
    check(store.current() == nil, "no current session after stop")
    check(store.sessions(since: t0).count == 1, "one session persisted")
}

withStore("open session survives reopen") { store, url in
    try store.start(tag: "writing", at: t0)
    let reopened = try SessionStore(url: url)
    check(reopened.current()?.tag == "writing", "running session resumes from disk")
}

withStore("start closes previous session") { store, _ in
    try store.start(tag: "a", at: t0)
    try store.start(tag: "b", at: t0.addingTimeInterval(60))
    let all = store.sessions(since: t0)
    check(all.map(\.tag) == ["b", "a"], "newest first")
    check(all[0].isRunning && !all[1].isRunning, "only the newest is running")
}

withStore("short sessions are discarded") { store, _ in
    try store.start(tag: "oops", at: t0)
    let result = try store.stop(at: t0.addingTimeInterval(2), minimumSeconds: 5)
    check(result == nil, "stop returns nil")
    check(store.sessions(since: t0).isEmpty, "nothing persisted")
}

withStore("recent tags and totals") { store, _ in
    try store.start(tag: "coding", at: t0)
    try store.stop(at: t0.addingTimeInterval(600))
    try store.start(tag: "review", at: t0.addingTimeInterval(700))
    try store.stop(at: t0.addingTimeInterval(1000))
    try store.start(tag: "coding", at: t0.addingTimeInterval(2000)) // still running
    check(store.recentTags() == ["coding", "review"], "recent tags ordered by last use")
    let totals = store.totals(since: t0, now: t0.addingTimeInterval(2100))
    check(totals == [TagTotal(tag: "coding", seconds: 700), TagTotal(tag: "review", seconds: 300)],
          "totals include the running session up to now")
    check(store.totals(since: t0.addingTimeInterval(5000), now: t0.addingTimeInterval(6000)).isEmpty,
          "totals respect the since bound")
}

withStore("retag") { store, _ in
    let session = try store.start(tag: "wrong", at: t0)
    try store.retag(id: session.id, tag: "right")
    check(store.current()?.tag == "right", "running session retagged")
}

var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
utc.firstWeekday = 2 // Monday
let monday = Date(timeIntervalSince1970: 1_767_571_200) // 2026-01-05 00:00 UTC, a Monday
func at(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    monday.addingTimeInterval(TimeInterval(day * 86_400 + hour * 3600 + minute * 60))
}

withStore("stats") { store, _ in
    try store.start(tag: "coding", at: at(day: 0, 9)); try store.stop(at: at(day: 0, 10))
    try store.start(tag: "writing", at: at(day: 0, 23, 30)); try store.stop(at: at(day: 1, 0, 30)) // crosses midnight
    try store.start(tag: "coding", at: at(day: 1, 14)); try store.stop(at: at(day: 1, 14, 55))
    try store.start(tag: "review", at: at(day: 3, 10)); try store.stop(at: at(day: 3, 10, 10))
    let stats = FocusStats(sessions: store.sessions(since: monday), now: at(day: 3, 12), calendar: utc)

    check(stats.sessionCount == 4 && stats.totalSeconds == 11_100, "count and total")
    check(stats.secondsByDay[at(day: 0, 0)] == 5400 && stats.secondsByDay[at(day: 1, 0)] == 5100,
          "midnight-crossing session is split between days")
    check(stats.secondsByHour[23] == 1800 && stats.secondsByHour[0] == 1800 && stats.secondsByHour[14] == 3300,
          "hour histogram")
    check(stats.secondsByWeekday[1] == 5400 && stats.secondsByWeekday[2] == 5100, "weekday histogram")
    check(stats.tags == [TagTotal(tag: "coding", seconds: 6900), TagTotal(tag: "writing", seconds: 3600),
                         TagTotal(tag: "review", seconds: 600)], "tag totals")
    check(stats.todaySeconds == 600 && stats.activeDays == 3, "today and active days")
    check(stats.currentStreak == 1 && stats.longestStreak == 2, "streaks")
    check(stats.bestDay == DayTotal(day: at(day: 0, 0), seconds: 5400), "best day")
    check(stats.peakHour == 9 && stats.peakWeekday == 1, "peak hour and weekday")
    check(stats.deepSessionCount == 3 && stats.longestSession?.tag == "coding", "deep work and longest")
    check(stats.averageSessionSeconds == 2775, "average session")
    check(stats.secondsByHour(last: 3)[14] == 3300 && stats.secondsByHour(last: 3)[0] == 1800
          && stats.secondsByHour(last: 3)[9] == 0 && stats.secondsByHour(last: 3)[23] == 0,
          "hour histogram over recent days")
    check(stats.dailyTotals(last: 4).map(\.seconds) == [5400, 5100, 0, 600], "daily totals include empty days")
    check(stats.seconds(from: at(day: 1, 0), to: at(day: 3, 0)) == 5100, "seconds in range")

    let grid = stats.heatmap(weeks: 2)
    check(grid.count == 2 && grid[1][0]?.day == monday && grid[1][0]?.seconds == 5400, "heatmap aligns to week start")
    check(grid[1][3]?.seconds == 600 && grid[1][4] == nil, "heatmap stops at today")

    let tomorrow = FocusStats(sessions: store.sessions(since: monday), now: at(day: 4, 8), calendar: utc)
    check(tomorrow.currentStreak == 1, "streak survives until a day is missed")
}

withStore("stats with a running session") { store, _ in
    try store.start(tag: "coding", at: at(day: 0, 9))
    let stats = FocusStats(sessions: store.sessions(since: monday), now: at(day: 0, 9, 20), calendar: utc)
    check(stats.totalSeconds == 1200 && stats.todaySeconds == 1200, "running session counts up to now")
    check(FocusStats(sessions: [], now: monday, calendar: utc).peakHour == nil, "no peak without data")
}

print("formatting")
check(Format.clock(0) == "00:00", "clock 0")
check(Format.clock(1513) == "25:13", "clock mm:ss")
check(Format.clock(3913) == "1:05:13", "clock h:mm:ss")
check(Format.hoursMinutes(0) == "0m", "0m")
check(Format.hoursMinutes(30) == "<1m", "<1m")
check(Format.hoursMinutes(2100) == "35m", "35m")
check(Format.hoursMinutes(8100) == "2h 15m", "2h 15m")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
