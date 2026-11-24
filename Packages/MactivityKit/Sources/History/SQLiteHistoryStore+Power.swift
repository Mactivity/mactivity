import Core
import Foundation
import GRDB

/// Sleep and wake (D-096).
extension SQLiteHistoryStore: PowerEventStore {
    public func recordPowerEvent(_ event: PowerEvent) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO power_event (t, kind, reason) VALUES (?, ?, ?)",
                arguments: [event.at.timeIntervalSince1970, event.kind.rawValue, event.reason]
            )
        }
    }

    public func powerEvents(days: Int) throws -> [PowerEvent] {
        let start = now().timeIntervalSince1970 - Double(max(1, days)) * 86400
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT t, kind, reason FROM power_event WHERE t >= ? ORDER BY t", arguments: [start])
                .compactMap { row in
                    guard let kind = PowerEvent.Kind(rawValue: row["kind"]) else {
                        return nil
                    }
                    return PowerEvent(at: Date(timeIntervalSince1970: row["t"]), kind: kind, reason: row["reason"])
                }
        }
    }
}
