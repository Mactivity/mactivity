import Core
import Foundation
import GRDB

/// Camera and microphone history (1.8, D-259): each change in what the privacy indicators show.
extension SQLiteHistoryStore: SensorHistoryStore {
    public func recordSensorChanges(_ changes: [SensorChange]) throws {
        guard !changes.isEmpty else {
            return
        }
        try database.write { db in
            for change in changes {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO sensor_change (t, active) VALUES (?, ?)",
                    arguments: [change.at.timeIntervalSince1970, change.encoded]
                )
            }
        }
    }

    public func sensorChanges(from: Date, to: Date) throws -> [SensorChange] {
        try database.read { db in
            // The one before the span too: what was in use as it began.
            try Row.fetchAll(db, sql: """
            SELECT t, active FROM sensor_change WHERE t < ? AND t >= (
                SELECT COALESCE(MAX(t), 0) FROM sensor_change WHERE t < ?
            ) ORDER BY t
            """, arguments: [to.timeIntervalSince1970, from.timeIntervalSince1970]).map(Self.sensorChange)
        }
    }

    public func lastSensorChange() throws -> SensorChange? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT t, active FROM sensor_change ORDER BY t DESC LIMIT 1").map(Self.sensorChange)
        }
    }

    static func sensorChange(_ row: Row) -> SensorChange {
        SensorChange(at: Date(timeIntervalSince1970: row["t"]), encoded: row["active"])
    }
}
