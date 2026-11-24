import Foundation

// Notifications by app (D-289): which app sent one, and when. Never a title, a body or anything
// else in it, and macOS's log doesn't hold those anyway.

public struct NotificationEvent: Hashable, Sendable {
    public let at: Date
    /// A bundle ID, or `NotificationEvent.website`.
    public let app: String

    /// Web notifications are kept as this, not by the site.
    public static let website = "_website"

    public init(at: Date, app: String) {
        self.at = at
        self.app = app
    }
}

public enum NotificationLogReading: Hashable, Sendable {
    /// The log couldn't be read, or its lines no longer add up: no count is better than a wrong one.
    case unreadable
    case read([NotificationEvent])
}

/// Where deliveries are read from (D-289): macOS's log, or Simulated.
public protocol NotificationLogSource: Sendable {
    func deliveries(from: Date, to: Date) async -> NotificationLogReading
}

/// Where they're kept, since macOS's log keeps them for about a day (D-289).
public protocol NotificationHistoryStore: Sendable {
    func recordNotifications(_ events: [NotificationEvent]) async throws
    /// Oldest first.
    func notifications(from: Date, to: Date) async throws -> [NotificationEvent]
    /// The earliest and the latest kept, nil when there are none.
    func notificationSpan() async throws -> ClosedRange<Date>?
}

/// Pure: who sent how many, and when in the day.
public enum NotificationStats {
    public struct AppRow: Hashable, Sendable, Identifiable {
        public let app: String
        public let count: Int
        /// Count in each hour of the day, midnight first: always 24.
        public let byHour: [Int]

        public var id: String {
            app
        }

        public init(app: String, count: Int, byHour: [Int]) {
            self.app = app
            self.count = count
            self.byHour = byHour
        }

        /// The hour most of them came in, the earliest if tied.
        public var busiestHour: Int {
            byHour.indices.max { (byHour[$0], -$0) < (byHour[$1], -$1) } ?? 0
        }
    }

    /// Most first; a tie by name, so rows don't swap between reloads.
    public static func apps(_ events: [NotificationEvent], calendar: Calendar = .current) -> [AppRow] {
        Dictionary(grouping: events, by: \.app).map { app, sent in
            AppRow(app: app, count: sent.count, byHour: byHour(sent, calendar: calendar))
        }
        .sorted { ($1.count, $0.app) < ($0.count, $1.app) }
    }

    /// Count in each hour of the day on the Mac's clock, midnight first.
    public static func byHour(_ events: [NotificationEvent], calendar: Calendar = .current) -> [Int] {
        var hours = Array(repeating: 0, count: 24)
        for event in events {
            hours[calendar.component(.hour, from: event.at) % 24] += 1
        }
        return hours
    }
}
