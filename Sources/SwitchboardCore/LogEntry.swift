import Foundation

/// One line of the app's log (`~/Library/Application Support/Switchboard/log.txt` and the
/// popover's log view).
public struct LogEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Level: String, Codable, Sendable, Comparable, CaseIterable {
        case debug, info, warning, error

        public static func < (lhs: Level, rhs: Level) -> Bool {
            let order = Level.allCases
            guard let l = order.firstIndex(of: lhs), let r = order.firstIndex(of: rhs) else { return false }
            return l < r
        }
    }

    public var id: UUID
    public var date: Date
    public var level: Level
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), level: Level = .info, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}
