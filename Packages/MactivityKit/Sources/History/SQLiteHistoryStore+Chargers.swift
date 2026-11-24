import Core
import Foundation
import GRDB

/// Chargers compared (D-274) and the Mac's hours (D-272).
extension SQLiteHistoryStore: ChargerHistoryStore, HourRhythmStore {
    public func chargerUse(days: Int) throws -> [ChargerUse] {
        let cutoff = Int64(now().addingTimeInterval(-Double(max(1, days)) * 86400).timeIntervalSince1970)
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM charger_use WHERE day >= ? ORDER BY day", arguments: [cutoff]).map { row in
                let band: Int = row["band"]
                let warm: Int = row["warm"]
                let busy: Int = row["busy"]
                return ChargerUse(
                    day: Date(timeIntervalSince1970: Double(row["day"] as Int64)),
                    ratingWatts: row["watts"],
                    condition: ChargeCondition(band: ChargeBand(rawValue: band), isWarm: warm < 0 ? nil : warm == 1, isBusy: busy == 1),
                    seconds: row["seconds"],
                    percentGained: row["gained"],
                    deliveredWattSeconds: row["deliveredWattSeconds"],
                    deliveredSeconds: row["deliveredSeconds"],
                    peakWatts: row["peakWatts"]
                )
            }
        }
    }

    /// Whole-Mac hour rows with what they covered. Rows from before v10 didn't record it: a whole hour.
    public func wholeMacHours(from: Date, to: Date) throws -> [HourSample] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
            SELECT t, cpuAvg, COALESCE(minutes, 60) AS covered FROM hour
            WHERE app = ? AND t >= ? AND t < ? AND cpuAvg IS NOT NULL
            ORDER BY t
            """, arguments: [HistorySchema.systemAppID, Int64(from.timeIntervalSince1970), Int64(to.timeIntervalSince1970)]).map { row in
                HourSample(at: Date(timeIntervalSince1970: Double(row["t"] as Int64)), cpu: row["cpuAvg"], coveredMinutes: row["covered"])
            }
        }
    }

    /// A quit with no minute in progress.
    func writeChargers() throws {
        guard chargerTally.hasUnsaved else {
            return
        }
        let uses = chargerTally.drain()
        do {
            try database.write { try Self.addChargerUse(uses, $0) }
        } catch {
            chargerTally.restore(uses)
            throw error
        }
    }

    /// Adds to the day's rows inside the caller's transaction, so a relaunch mid-day keeps the earlier part.
    static func addChargerUse(_ uses: [ChargerUse], _ db: Database) throws {
        guard !uses.isEmpty else {
            return
        }
        let statement = try db.cachedStatement(sql: """
        INSERT INTO charger_use (day, watts, band, warm, busy, seconds, gained, deliveredWattSeconds, deliveredSeconds, peakWatts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (day, watts, band, warm, busy) DO UPDATE SET
            seconds = seconds + excluded.seconds,
            gained = gained + excluded.gained,
            deliveredWattSeconds = deliveredWattSeconds + excluded.deliveredWattSeconds,
            deliveredSeconds = deliveredSeconds + excluded.deliveredSeconds,
            peakWatts = COALESCE(MAX(peakWatts, excluded.peakWatts), peakWatts, excluded.peakWatts)
        """)
        for use in uses {
            try statement.execute(arguments: [
                Int64(use.day.timeIntervalSince1970), use.ratingWatts, use.condition.band?.rawValue ?? -1,
                use.condition.isWarm.map { $0 ? 1 : 0 } ?? -1, use.condition.isBusy ? 1 : 0,
                use.seconds, use.percentGained, use.deliveredWattSeconds, use.deliveredSeconds, use.peakWatts,
            ])
        }
    }
}
