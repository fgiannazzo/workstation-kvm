import Foundation
import SwitchboardCore

/// What the Log window shows and copies.
public enum LogPresentation {
    /// The entries at `minimum` severity or above, newest first (the order the window lists them).
    /// `nil` keeps every level.
    public static func entries(_ log: [LogEntry], minimum: LogEntry.Level?) -> [LogEntry] {
        let kept = minimum.map { level in log.filter { $0.level >= level } } ?? log
        return Array(kept.reversed())
    }

    /// `2026-10-11T20:15:03Z info run guest started (2 steps)`, one line per entry, oldest first,
    /// the way a log file reads. This is what "Copy all" puts on the pasteboard.
    public static func text(_ log: [LogEntry]) -> String {
        log.map { line($0) }.joined(separator: "\n")
    }

    public static func line(_ entry: LogEntry) -> String {
        "\(timestamp(entry.date)) \(entry.level.rawValue) \(entry.message)"
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// "5 s ago" for the State section, where the exact time is noise.
public enum RelativeTime {
    /// `never` for the placeholder date of a state nothing has been read into yet, `just now` under
    /// 5 s, then seconds, minutes, hours, days. A date in the future reads as `just now`.
    public static func text(for date: Date, now: Date = Date()) -> String {
        if date == .distantPast { return "never" }
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<5: return "just now"
        case 5..<60: return "\(seconds) s ago"
        case 60..<3600: return "\(seconds / 60) min ago"
        case 3600..<86_400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }
}
