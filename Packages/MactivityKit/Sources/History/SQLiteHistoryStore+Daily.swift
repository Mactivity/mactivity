import Core
import Foundation
import GRDB

/// History's year calendar and the day it opens (D-093).
extension SQLiteHistoryStore: DailyHistoryStore {
    /// From the hour tier's system-wide rows, grouped by local day here rather than in SQL, so a
    /// day follows the Mac's time zone and its daylight-saving changes.
    public func dailyValues(metric: Metric, days: Int) throws -> [DayValue] {
        let start = Int64(now().timeIntervalSince1970) - Int64(max(1, days)) * 86400
        let avg = metric.averageColumn
        let rows = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT t, \(avg) AS average, \(metric.maximumColumn) AS maximum, COALESCE(minutes, 60) AS minutes FROM hour
                WHERE app = ? AND t >= ? AND \(avg) IS NOT NULL ORDER BY t
                """,
                arguments: [HistorySchema.systemAppID, start]
            )
        }
        // Each hour weighted by the minutes it covers, as the hour rollup weights quarters
        // (D-108): an hour with one Power Nap minute isn't a full hour of the day (D-141).
        var byDay: [Date: (sum: Double, minutes: Double, peak: Double)] = [:]
        for row in rows {
            let t: Int64 = row["t"]
            let average: Double = row["average"]
            let maximum: Double = (row["maximum"] as Double?) ?? average
            let minutes = max(1, Double(row["minutes"] as Int64))
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(t)))
            var entry = byDay[day] ?? (0, 0, -Double.infinity)
            entry.sum += average * minutes
            entry.minutes += minutes
            entry.peak = max(entry.peak, maximum)
            byDay[day] = entry
        }
        return byDay
            .map { DayValue(day: $0.key, average: $0.value.sum / $0.value.minutes, maximum: $0.value.peak) }
            .sorted { $0.day < $1.day }
    }

    public func series(metric: Metric, app: AppIdentity.ID?, from: Date, to: Date) throws -> [SeriesPoint] {
        let (start, end) = (Self.seconds(from), Self.seconds(to))
        let tier = tier(covering: start, to: end)
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: Self.rangeSeriesSQL(metric: metric, tier: tier),
                arguments: [app ?? HistorySchema.systemAppID, start, end]
            ).map { row in
                let t: Int64 = row["t"]
                let average: Double = row["average"]
                let maximum: Double? = row["maximum"]
                return SeriesPoint(at: Date(timeIntervalSince1970: TimeInterval(t)), average: average, maximum: maximum ?? average)
            }
        }
    }

    public func topApps(metric: Metric, from: Date, to: Date, limit: Int) throws -> [AppTotal] {
        let (start, end) = (Self.seconds(from), Self.seconds(to))
        return try topApps(metric: metric, tier: tier(covering: start, to: end), limit: limit, from: start, to: end)
    }

    /// Spans up to this long, inside minute retention, read minutes.
    static let minuteSpan: Int64 = 3 * 3600

    /// A short, recent span (a slowdown, D-169; the minutes after login, D-171) reads minutes: a
    /// quarter-hour row would start before it, and the quarter it's in may not be rolled up yet.
    /// Longer spans read quarter-hours or hours, as `tier(covering:)` picks.
    func tier(covering start: Int64, to end: Int64) -> HistoryTier {
        let fine = end - start <= Self.minuteSpan && start >= Int64(now().timeIntervalSince1970) - keptSeconds(.minute)
        return fine ? .minute : tier(covering: start)
    }

    public func totals(metrics: [Metric], from: Date, to: Date, limit: Int) throws -> [AppTotal] {
        let (start, end) = (Self.seconds(from), Self.seconds(to))
        // Minutes for a short, recent span, so a 9-minute hotspot stretch isn't read from the
        // quarter-hour that began before it (D-236).
        let tier = tier(covering: start, to: end)
        return try database.read { db in
            try Row.fetchAll(db, sql: """
            SELECT app.id, app.name, app.bundleID, app.iconKey, app.kind,
                   SUM((\(Self.sumExpression(metrics, tier: "tier"))) * tier.samples * 1.0 / MAX(1, s.samples)
                       * \(tier.coveredSeconds("s"))) AS value
            FROM \(tier.table) AS tier
            JOIN \(tier.table) AS s ON s.t = tier.t AND s.app = ?
            JOIN app ON app.id = tier.app
            WHERE tier.t >= ? AND tier.t < ? AND tier.app != ?
            GROUP BY tier.app
            HAVING value > 0
            ORDER BY value DESC, app.id
            LIMIT ?
            """, arguments: [
                HistorySchema.systemAppID, start, end, HistorySchema.systemAppID, max(0, limit),
            ]).map { row in
                let kind: String = row["kind"]
                let identity = AppIdentity(
                    id: row["id"], name: row["name"], bundleID: row["bundleID"], iconKey: row["iconKey"],
                    kind: AppIdentity.Kind(rawValue: kind) ?? .other
                )
                return AppTotal(app: identity, value: row["value"])
            }
        }
    }

    public func systemTotal(metrics: [Metric], from: Date, to: Date) throws -> Double {
        let (start, end) = (Self.seconds(from), Self.seconds(to))
        let tier = tier(covering: start, to: end)
        let sum = try database.read { db in
            try Double.fetchOne(db, sql: """
            SELECT TOTAL((\(Self.sumExpression(metrics, tier: tier.table))) * \(tier.coveredSeconds(tier.table)))
            FROM \(tier.table) WHERE app = ? AND t >= ? AND t < ?
            """, arguments: [HistorySchema.systemAppID, start, end])
        }
        return sum ?? 0
    }

    /// The oldest system-wide row in any tier: hours reach back furthest, but a fresh install
    /// has only minutes.
    public func firstRecorded() throws -> Date? {
        try database.read { db in
            let oldest = try HistoryTier.allCases.compactMap { tier in
                try Int64.fetchOne(db, sql: "SELECT MIN(t) FROM \(tier.table) WHERE app = ?", arguments: [HistorySchema.systemAppID])
            }.min()
            return oldest.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
    }

    /// "COALESCE(tier.netInAvg, 0) + COALESCE(tier.netOutAvg, 0)".
    private static func sumExpression(_ metrics: [Metric], tier: String) -> String {
        metrics.map { "COALESCE(\(tier).\($0.averageColumn), 0)" }.joined(separator: " + ")
    }

    /// Quarter-hours while they're kept (a day in 96 points), hours before that.
    func tier(covering start: Int64) -> HistoryTier {
        start >= Int64(now().timeIntervalSince1970) - keptSeconds(.quarter) ? .quarter : .hour
    }

    /// One app's series between two times: a range of the `(app, t)` index (D-086).
    static func rangeSeriesSQL(metric: Metric, tier: HistoryTier) -> String {
        let avg = metric.averageColumn
        return """
        SELECT t, \(avg) AS average, \(metric.maximumColumn) AS maximum FROM \(tier.table)
        WHERE app = ? AND t >= ? AND t < ? AND \(avg) IS NOT NULL
        ORDER BY t
        """
    }

    private static func seconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }
}
