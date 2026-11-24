import Core
import Foundation
import GRDB

extension SQLiteHistoryStore: BatteryHistoryStore {
    public func batteryHistory(days: Int) throws -> [BatteryDay] {
        let cutoff = Int64(now().addingTimeInterval(-Double(max(1, days)) * 86400).timeIntervalSince1970)
        return try database.read { db in
            try Row.fetchAll(db, sql: """
            SELECT day, maxCapacity, cycles, secondsOnBattery FROM battery_day WHERE day >= ? ORDER BY day
            """, arguments: [cutoff]).map { row in
                BatteryDay(
                    day: Date(timeIntervalSince1970: Double(row["day"] as Int64)),
                    maxCapacityPercent: row["maxCapacity"],
                    cycleCount: row["cycles"],
                    minutesOnBattery: (row["secondsOnBattery"] as Double) / 60
                )
            }
        }
    }
}
