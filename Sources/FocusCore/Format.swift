import Foundation

public enum Format {
    /// "25:13" or "1:05:13" for a running clock.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// "2h 15m", "35m", "<1m" for totals.
    public static func hoursMinutes(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if minutes == 0 { return seconds > 0 ? "<1m" : "0m" }
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
