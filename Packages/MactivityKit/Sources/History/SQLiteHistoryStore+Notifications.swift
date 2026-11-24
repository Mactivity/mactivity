import Core
import Foundation
import GRDB

/// Notifications by app (D-289): one row per delivery, the app and the time and nothing else.
extension SQLiteHistoryStore: NotificationHistoryStore {
    public func recordNotifications(_ events: [NotificationEvent]) throws {
        guard !events.isEmpty else {
            return
        }
        try database.write { db in
            for event in events {
                // A read overlaps the one before it, so the same line can come twice.
                try db.execute(
                    sql: "INSERT OR IGNORE INTO notification_event (t, app) VALUES (?, ?)",
                    arguments: [event.at.timeIntervalSince1970, event.app]
                )
            }
        }
    }

    public func notifications(from: Date, to: Date) throws -> [NotificationEvent] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT t, app FROM notification_event WHERE t >= ? AND t < ? ORDER BY t", arguments: [
                from.timeIntervalSince1970, to.timeIntervalSince1970,
            ]).map { NotificationEvent(at: Date(timeIntervalSince1970: $0["t"]), app: $0["app"]) }
        }
    }

    public func notificationSpan() throws -> ClosedRange<Date>? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT MIN(t) AS first, MAX(t) AS last FROM notification_event"),
                  let first: Double = row["first"], let last: Double = row["last"]
            else {
                return nil
            }
            return Date(timeIntervalSince1970: first) ... Date(timeIntervalSince1970: last)
        }
    }
}
