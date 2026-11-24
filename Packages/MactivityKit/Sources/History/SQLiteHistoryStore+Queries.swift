import Core
import Foundation
import GRDB

extension SQLiteHistoryStore {
    /// Rows with `t ≥ now − range`, oldest first. Buckets where the metric was unavailable are
    /// skipped, not reported as zero. Reads what has been written: the minute in progress
    /// shows up once it finishes (or on `flush()`).
    public func series(metric: Metric, app: AppIdentity.ID?, range: HistoryRange) throws -> [SeriesPoint] {
        let tier = HistoryTier(range: range)
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: Self.seriesSQL(metric: metric, tier: tier),
                arguments: [app ?? HistorySchema.systemAppID, cutoff(for: range)]
            ).map { row in
                let t: Int64 = row["t"]
                let average: Double = row["average"]
                let maximum: Double? = row["maximum"]
                return SeriesPoint(at: Date(timeIntervalSince1970: TimeInterval(t)), average: average, maximum: maximum ?? average)
            }
        }
    }

    /// One app's series: a range of the `(app, t)` index, already in time order (D-086).
    static func seriesSQL(metric: Metric, tier: HistoryTier) -> String {
        let avg = metric.averageColumn
        return """
        SELECT t, \(avg) AS average, \(metric.maximumColumn) AS maximum FROM \(tier.table)
        WHERE app = ? AND t >= ? AND \(avg) IS NOT NULL
        ORDER BY t
        """
    }

    /// Apps ranked by the average of their bucket averages over the range (buckets the app
    /// appears in), highest first. The system-wide row is never included.
    public func topApps(metric: Metric, range: HistoryRange, limit: Int) throws -> [AppTotal] {
        try topApps(metric: metric, range: range, limit: limit, from: cutoff(for: range), to: Int64.max)
    }

    /// The period before the range. It can reach past what the range's own tier keeps (30 to 60
    /// days ago for 30 d), so it reads the finest tier that still covers its start.
    public func topAppsInPreviousPeriod(metric: Metric, range: HistoryRange, limit: Int) throws -> [AppTotal] {
        let end = cutoff(for: range)
        let start = end - Int64(range.duration.components.seconds)
        let seconds = Int64(now().timeIntervalSince1970)
        var tier = HistoryTier(range: range)
        // A bucket of slack: retention runs hourly, so a tier often reaches a little further.
        while let coarser = tier.coarser, start < seconds - keptSeconds(tier) - tier.bucketSeconds {
            tier = coarser
        }
        // Past what any tier keeps: an hour of leftovers at the retention edge isn't a period to
        // compare with, so say there isn't enough history (D-141).
        guard start >= seconds - keptSeconds(.hour) - HistoryTier.hour.bucketSeconds else {
            return []
        }
        return try topApps(metric: metric, tier: tier, limit: limit, from: start, to: end)
    }

    private func topApps(metric: Metric, range: HistoryRange, limit: Int, from start: Int64, to end: Int64) throws -> [AppTotal] {
        try topApps(metric: metric, tier: HistoryTier(range: range), limit: limit, from: start, to: end)
    }

    func topApps(metric: Metric, tier: HistoryTier, limit: Int, from start: Int64, to end: Int64) throws -> [AppTotal] {
        guard limit > 0 else {
            return []
        }
        let avg = metric.averageColumn
        return try database.read { db in
            try Row.fetchAll(
                db,
                // Each app over the whole range, not just the moments it ran: its average weighted by
                // its samples, over every sample the Mac recorded. A helper that ran for five
                // seconds at 10% no longer outranks an app at 2% all day (D-103).
                sql: """
                SELECT app.id, app.name, app.bundleID, app.iconKey, app.kind,
                       SUM(tier.\(avg) * tier.samples) / MAX(1, (
                           SELECT TOTAL(samples) FROM \(tier.table) WHERE app = ? AND t >= ? AND t < ?
                       )) AS value
                FROM \(tier.table) AS tier JOIN app ON app.id = tier.app
                WHERE tier.t >= ? AND tier.t < ? AND tier.app != ? AND tier.\(avg) IS NOT NULL
                GROUP BY tier.app
                ORDER BY value DESC, app.id
                LIMIT ?
                """,
                arguments: [HistorySchema.systemAppID, start, end, start, end, HistorySchema.systemAppID, limit]
            ).map { row in
                let kind: String = row["kind"]
                let identity = AppIdentity(
                    id: row["id"],
                    name: row["name"],
                    bundleID: row["bundleID"],
                    iconKey: row["iconKey"],
                    kind: AppIdentity.Kind(rawValue: kind) ?? .other
                )
                return AppTotal(app: identity, value: row["value"])
            }
        }
    }

    /// Σ average × seconds covered over the system-wide series (D-108): bytes for the disk and network
    /// rates, millijoules for energy, percent-seconds for CPU and GPU.
    public func total(metric: Metric, range: HistoryRange) throws -> Double {
        let tier = HistoryTier(range: range)
        let sum = try database.read { db in
            try Double.fetchOne(
                db,
                sql: """
                SELECT TOTAL(\(metric.averageColumn) * \(tier.coveredSeconds(tier.table))) FROM \(tier.table)
                WHERE app = ? AND t >= ?
                """,
                arguments: [HistorySchema.systemAppID, cutoff(for: range)]
            )
        }
        return sum ?? 0
    }

    /// First bucket start inside the range, relative to the store's clock.
    private func cutoff(for range: HistoryRange) -> Int64 {
        let seconds = now().timeIntervalSince1970 - TimeInterval(range.duration.components.seconds)
        return Int64(seconds.rounded(.up))
    }
}
