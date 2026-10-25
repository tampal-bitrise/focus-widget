import Foundation

public struct DayTotal: Equatable {
    /// Start of the local day.
    public let day: Date
    public let seconds: Int

    public init(day: Date, seconds: Int) {
        self.day = day
        self.seconds = seconds
    }
}

/// Aggregates over a set of sessions. Time is split at hour boundaries, so a session that crosses
/// midnight counts toward both days and the hour-of-day histogram is exact. A running session counts up to `now`.
public struct FocusStats {
    /// Sessions at least this long count as deep work.
    public static let deepWorkSeconds = 50 * 60

    public let now: Date
    public let calendar: Calendar
    public let sessionCount: Int
    public let totalSeconds: Int
    /// Keyed by start of local day. Only days with focus time are present.
    public let secondsByDay: [Date: Int]
    /// Index 0...23 = local hour of day.
    public let secondsByHour: [Int]
    /// Index 0...6 = `Calendar.component(.weekday) - 1`, so 0 is Sunday.
    public let secondsByWeekday: [Int]
    /// Largest first.
    public let tags: [TagTotal]
    public let longestSession: Session?
    public let deepSessionCount: Int
    public let firstStart: Date?

    public init(sessions: [Session], now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar

        var total = 0
        var byDay: [Date: Int] = [:]
        var byHour = [Int](repeating: 0, count: 24)
        var byWeekday = [Int](repeating: 0, count: 7)
        var byTag: [String: Int] = [:]
        var longest: Session?
        var longestSeconds = -1
        var deep = 0
        var first: Date?

        for session in sessions {
            let end = max(session.endedAt ?? now, session.startedAt)
            let seconds = Int(end.timeIntervalSince(session.startedAt))
            total += seconds
            byTag[session.tag, default: 0] += seconds
            // Ties go to the earlier session: it set the record first.
            if seconds > longestSeconds || (seconds == longestSeconds && session.startedAt < longest!.startedAt) {
                longest = session
                longestSeconds = seconds
            }
            if seconds >= Self.deepWorkSeconds { deep += 1 }
            if first.map({ session.startedAt < $0 }) ?? true { first = session.startedAt }

            var t = session.startedAt
            while t < end {
                let next = min(end, calendar.dateInterval(of: .hour, for: t)?.end ?? end)
                let slice = Int(next.timeIntervalSince(t))
                byDay[calendar.startOfDay(for: t), default: 0] += slice
                byHour[calendar.component(.hour, from: t)] += slice
                byWeekday[calendar.component(.weekday, from: t) - 1] += slice
                t = next
            }
        }

        sessionCount = sessions.count
        totalSeconds = total
        secondsByDay = byDay.filter { $0.value > 0 }
        secondsByHour = byHour
        secondsByWeekday = byWeekday
        tags = byTag.map { TagTotal(tag: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.tag < $1.tag }
        longestSession = longest
        deepSessionCount = deep
        firstStart = first
    }

    // MARK: - Derived

    public var today: Date { calendar.startOfDay(for: now) }
    public var todaySeconds: Int { secondsByDay[today] ?? 0 }
    public var activeDays: Int { secondsByDay.count }
    public var averageSessionSeconds: Int { sessionCount == 0 ? 0 : totalSeconds / sessionCount }

    /// Start of the current calendar week (respects the calendar's first weekday).
    public var weekStart: Date { calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today }

    /// Focus time on days in `[from, to)`.
    public func seconds(from: Date, to: Date) -> Int {
        secondsByDay.reduce(0) { $1.key >= from && $1.key < to ? $0 + $1.value : $0 }
    }

    /// One entry per day for the last `count` days, oldest first, ending today. Days without focus are 0.
    public func dailyTotals(last count: Int) -> [DayTotal] {
        (0..<max(0, count)).reversed().map { back in
            let day = self.day(byAdding: -back, to: today)
            return DayTotal(day: day, seconds: secondsByDay[day] ?? 0)
        }
    }

    /// Consecutive days with focus, ending today, or ending yesterday if nothing has been logged today yet.
    public var currentStreak: Int {
        var day = secondsByDay[today] != nil ? today : self.day(byAdding: -1, to: today)
        var streak = 0
        while secondsByDay[day] != nil {
            streak += 1
            day = self.day(byAdding: -1, to: day)
        }
        return streak
    }

    public var longestStreak: Int {
        var best = 0, run = 0
        var previous: Date?
        for day in secondsByDay.keys.sorted() {
            run = previous.map { self.day(byAdding: 1, to: $0) == day } == true ? run + 1 : 1
            best = max(best, run)
            previous = day
        }
        return best
    }

    public var bestDay: DayTotal? {
        secondsByDay.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
            .map { DayTotal(day: $0.key, seconds: $0.value) }
    }

    /// Hour of day with the most focus time, nil when there is no data.
    public var peakHour: Int? {
        guard totalSeconds > 0 else { return nil }
        return secondsByHour.indices.max { secondsByHour[$0] < secondsByHour[$1] }
    }

    /// Weekday index (0 = Sunday) with the most focus time, nil when there is no data.
    public var peakWeekday: Int? {
        guard totalSeconds > 0 else { return nil }
        return secondsByWeekday.indices.max { secondsByWeekday[$0] < secondsByWeekday[$1] }
    }

    /// A GitHub-style grid: `weeks` columns, oldest first, each holding 7 days starting on the calendar's
    /// first weekday. Days after today are nil.
    public func heatmap(weeks: Int) -> [[DayTotal?]] {
        let firstWeek = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: weekStart) ?? weekStart
        return (0..<max(0, weeks)).map { week in
            (0..<7).map { offset in
                let day = self.day(byAdding: week * 7 + offset, to: firstWeek)
                return day > today ? nil : DayTotal(day: day, seconds: secondsByDay[day] ?? 0)
            }
        }
    }

    private func day(byAdding days: Int, to date: Date) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: days, to: date) ?? date)
    }
}
