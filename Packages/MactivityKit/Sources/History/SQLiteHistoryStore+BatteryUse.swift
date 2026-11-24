import Core
import Foundation
import GRDB

/// Battery use by app (D-100).
extension SQLiteHistoryStore: BatteryUseStore {
    /// Each app's Energy Impact weighted by how much of each bucket the Mac was on battery,
    /// as a share of all apps'. macOS itself counts like an app, as on iOS.
    public func batteryUse(from: Date, to: Date, limit: Int) throws -> BatteryUse {
        let start = Int64(from.timeIntervalSince1970)
        let end = Int64(to.timeIntervalSince1970)
        let tier = tier(covering: start)
        let table = tier.table
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT app.id, app.name, app.bundleID, app.iconKey, app.kind,
                   SUM(a.energyImpactAvg * s.onBatteryAvg * a.samples * 1.0 / MAX(1, s.samples)) AS value
            FROM \(table) AS a
            JOIN \(table) AS s ON s.t = a.t AND s.app = ?
            JOIN app ON app.id = a.app
            WHERE a.t >= ? AND a.t < ? AND a.app != ? AND s.onBatteryAvg > 0 AND a.energyImpactAvg IS NOT NULL
            GROUP BY a.app
            HAVING value > 0
            ORDER BY value DESC, app.id
            """, arguments: [HistorySchema.systemAppID, start, end, HistorySchema.systemAppID])
            let total = rows.reduce(0.0) { $0 + ($1["value"] as Double) }
            let apps = rows.prefix(max(0, limit)).map { row in
                let kind: String = row["kind"]
                let identity = AppIdentity(
                    id: row["id"], name: row["name"], bundleID: row["bundleID"], iconKey: row["iconKey"],
                    kind: AppIdentity.Kind(rawValue: kind) ?? .other
                )
                return AppTotal(app: identity, value: total > 0 ? (row["value"] as Double) / total : 0)
            }
            // The level, bucket by bucket, while on battery: every fall adds to what was used.
            let levels = try Row.fetchAll(db, sql: """
            SELECT onBatteryAvg AS onBattery, batteryLevelAvg AS level, \(tier.coveredSeconds(table)) AS covered FROM \(table)
            WHERE app = ? AND t >= ? AND t < ? AND onBatteryAvg IS NOT NULL ORDER BY t
            """, arguments: [HistorySchema.systemAppID, start, end])
            var onBattery = 0.0
            var drained = 0.0
            var previous: Double?
            for row in levels {
                let share: Double = row["onBattery"]
                onBattery += share * (row["covered"] as Double)
                let level: Double? = row["level"]
                if share > 0.5, let level, let before = previous, level < before {
                    drained += before - level
                }
                previous = level ?? previous
            }
            return BatteryUse(apps: Array(apps), onBatterySeconds: onBattery, drainedPercent: drained)
        }
    }

    /// The minute rows' two days first (D-150); on battery longer than that, the quarter-hours
    /// before them, so a long stretch on battery still starts where it did. A sleep on battery
    /// doesn't end the stretch; only time recorded plugged in does.
    public func unpluggedAt(now: Date) throws -> Date? {
        let end = Int64(now.timeIntervalSince1970)
        let minuteStart = end - HistorySchema.minuteRetention
        let minute = HistoryTier.minute.table
        let quarter = HistoryTier.quarter.table
        let system = HistorySchema.systemAppID
        return try database.read { db in
            var lastPlugged = try Int64.fetchOne(db, sql: """
            SELECT MAX(t) + 60 FROM \(minute) WHERE app = ? AND t >= ? AND t < ? AND onBatteryAvg < 0.5
            """, arguments: [system, minuteStart, end])
            if lastPlugged == nil {
                lastPlugged = try Int64.fetchOne(db, sql: """
                SELECT MAX(t) + 900 FROM \(quarter) WHERE app = ? AND t < ? AND onBatteryAvg < 0.5
                """, arguments: [system, minuteStart])
            }
            // The first time on battery after that; with no time plugged in on record, the first ever.
            let after = lastPlugged ?? Int64.min
            let first = try Int64.fetchOne(db, sql: """
            SELECT MIN(t) FROM (
                SELECT t FROM \(minute) WHERE app = ? AND t >= ? AND t < ? AND onBatteryAvg >= 0.5
                UNION ALL
                SELECT t FROM \(quarter) WHERE app = ? AND t >= ? AND t < ? AND onBatteryAvg >= 0.5
            )
            """, arguments: [system, max(after, minuteStart), end, system, after, minuteStart])
            return first.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
    }

}
