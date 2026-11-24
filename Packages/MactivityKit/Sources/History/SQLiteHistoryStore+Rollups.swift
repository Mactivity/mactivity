import Core
import Foundation
import GRDB

// Rollups: quarter-hours from minutes, hours from quarter-hours (spec 6.7, D-089). Each runs in
// the transaction that writes a finished minute.
extension SQLiteHistoryStore {
    static let quarterRollupSQL: String = {
        let columns = Metric.allCases.flatMap { [$0.averageColumn, $0.maximumColumn] }
        let aggregates = Metric.allCases.flatMap { ["AVG(\($0.averageColumn))", "MAX(\($0.maximumColumn))"] }
        return """
        INSERT OR REPLACE INTO quarter (t, app, samples, minutes, \(columns.joined(separator: ", ")))
        SELECT (t / 900) * 900 AS q, app, SUM(samples), COUNT(*), \(aggregates.joined(separator: ", "))
        FROM minute WHERE t >= ? AND t < ? GROUP BY q, app
        """
    }()

    /// Average of the minute averages, max of the maxes, and the minutes present, for every quarter-hour after the
    /// newest one already rolled up and before `end`. Idempotent; also catches up quarters
    /// completed while the app wasn't running.
    static func rollUpQuarters(before end: Int64, _ db: Database) throws {
        // Before `end` only: a row stamped in the future (the clock set ahead, then back) would
        // otherwise stop every rollup until real time caught up with it (D-141).
        let newest = try Int64.fetchOne(db, sql: "SELECT MAX(t) FROM quarter WHERE t < ?", arguments: [end])
        let start = newest.map { $0 + HistoryTier.quarter.bucketSeconds } ?? Int64.min
        guard start < end else {
            return
        }
        try db.cachedStatement(sql: quarterRollupSQL).execute(arguments: [start, end])
    }

    /// Before retention deletes: rolls up what's about to go. After a long shutdown the last
    /// quarter-hour before it was never rolled up, and retention would delete its minutes (D-141).
    /// Only buckets reaching the minute (or quarter) cutoff: recent ones may still gain a minute
    /// after a relaunch, and the normal rollup handles them.
    static func rollUpExpiring(minuteCutoff: Int64, quarterCutoff: Int64, _ db: Database) throws {
        try rollUpQuarters(before: HistoryTier.quarter.bucketStart(minuteCutoff) + HistoryTier.quarter.bucketSeconds, db)
        try rollUpHours(before: HistoryTier.hour.bucketStart(quarterCutoff) + HistoryTier.hour.bucketSeconds, db)
    }

    /// An hour's averages weight each quarter by the minutes it covers (D-108), so a quarter the
    /// Mac was awake for two minutes of doesn't count as much as a full one.
    static let hourRollupSQL: String = {
        let columns = Metric.allCases.flatMap { [$0.averageColumn, $0.maximumColumn] }
        let covered = "COALESCE(minutes, 15)"
        let aggregates = Metric.allCases.flatMap { metric in
            let avg = metric.averageColumn
            return [
                "SUM(\(avg) * \(covered)) * 1.0 / SUM(CASE WHEN \(avg) IS NOT NULL THEN \(covered) END)",
                "MAX(\(metric.maximumColumn))",
            ]
        }
        return """
        INSERT OR REPLACE INTO hour (t, app, samples, minutes, \(columns.joined(separator: ", ")))
        SELECT (t / 3600) * 3600 AS h, app, SUM(samples), SUM(\(covered)), \(aggregates.joined(separator: ", "))
        FROM quarter WHERE t >= ? AND t < ? GROUP BY h, app
        """
    }()

    /// Hours from quarter-hours, like `rollUpQuarters`. An hour is complete once `end` (the
    /// start of the latest minute's hour) is past it, and by then its four quarters are rolled
    /// up. The first write after the v4 migration fills hours from every quarter already kept.
    static func rollUpHours(before end: Int64, _ db: Database) throws {
        let newest = try Int64.fetchOne(db, sql: "SELECT MAX(t) FROM hour WHERE t < ?", arguments: [end])
        let start = newest.map { $0 + HistoryTier.hour.bucketSeconds } ?? Int64.min
        guard start < end else {
            return
        }
        try db.cachedStatement(sql: hourRollupSQL).execute(arguments: [start, end])
    }

    /// How far back `tier` keeps rows: minutes 48 h, quarter-hours up to 30 days, hours the
    /// retention setting (D-089).
    func keptSeconds(_ tier: HistoryTier) -> Int64 {
        switch tier {
        case .minute: HistorySchema.minuteRetention
        case .quarter: Int64(min(retentionDays, HistorySchema.quarterRetentionDays)) * 86400
        case .hour: Int64(retentionDays) * 86400
        }
    }
}
