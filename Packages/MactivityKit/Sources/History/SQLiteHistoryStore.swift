import Core
import Foundation
import GRDB

/// The history store: one SQLite file, minute, quarter-hour and hour tiers, rollups and
/// retention (spec 6.7, D-089). Also persists alert state and the alert log (spec 6.8).
///
/// `record(_:)` only touches memory until a minute finishes; then that minute is written in one
/// transaction, and any quarter-hour or hour it completes is rolled up in SQL. Every method is
/// synchronous inside the actor, so no two calls interleave.
public actor SQLiteHistoryStore: HistoryStore, AlertStateStore {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    nonisolated let database: DatabaseQueue
    let now: @Sendable () -> Date
    private let fileURL: URL?
    private(set) var retentionDays: Int
    /// The minute being sampled. Nil before the first snapshot and after a flush.
    private var current: MinuteAccumulator?
    private var lastRetentionRun: Date?
    /// Today's battery health, written with each minute (expansion E14).
    private var batteryToday: BatteryAccumulator?
    /// Time on each charger not yet written (D-274).
    var chargerTally = ChargerTally()
    /// Apps as the `app` table has them, so a minute upserts only apps that are new or changed
    /// rather than every app every minute (D-086). Empty after launch: the first minute writes all.
    private var writtenApps: [AppIdentity.ID: AppIdentity] = [:]
    let calendar: Calendar
    /// Each device's last kept reading this launch, so an unchanged level is kept only hourly (D-094).
    var lastDeviceReading: [String: (percent: Double, at: Int64)] = [:]

    /// Retention is checked on every record but runs at most this often.
    static let retentionInterval: TimeInterval = 3600
    /// The most one snapshot adds to time on battery. Sampling is every 10 s at most (20 s in
    /// Low Power Mode), so a longer gap is sleep, not use (D-133).
    static let longestCountedInterval: TimeInterval = 60

    /// `~/Library/Application Support/Mactivity/history.sqlite`; creates the directory.
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("Mactivity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlite")
    }

    /// Opens the history at `url`. If the file is damaged (not a database, or corrupt), it's moved
    /// aside as `history-damaged-<date>.sqlite`, never deleted, and a fresh database starts in its
    /// place. Without this, one damaged file kept history in memory only, on every launch (D-070).
    public static func openRecovering(url: URL, retentionDays: Int = HistoryRetention.defaultDays) throws -> SQLiteHistoryStore {
        do {
            return try SQLiteHistoryStore(url: url, retentionDays: retentionDays)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            historyLog.error("History is damaged (\(error.resultCode.rawValue)); moving it aside and starting fresh")
            try moveAside(url)
            return try SQLiteHistoryStore(url: url, retentionDays: retentionDays)
        }
    }

    /// For `openReadOnly` (SQLiteHistoryStore+Reading.swift): no migration, nothing written.
    init(reading database: DatabaseQueue, url: URL) {
        self.database = database
        fileURL = url
        retentionDays = HistoryRetention.defaultDays
        now = { Date() }
        calendar = .autoupdatingCurrent
    }

    /// `url == nil` → in-memory database (tests). WAL mode for file databases.
    public init(url: URL?, retentionDays: Int = HistoryRetention.defaultDays, now: @escaping @Sendable () -> Date = { Date() }) throws {
        var configuration = Configuration()
        configuration.label = "Mactivity.history"
        if let url {
            configuration.journalMode = .wal
            // NORMAL, not SQLite's FULL: in WAL mode that's still safe against corruption, but it
            // flushes to disk at checkpoints (hourly, `compactIfMostlyEmpty`) instead of on every
            // minute's commit. A power cut can lose the last minute or so of history (D-064).
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
            database = try DatabaseQueue(path: url.path, configuration: configuration)
        } else {
            database = try DatabaseQueue(configuration: configuration)
        }
        try HistorySchema.migrator.migrate(database)
        fileURL = url
        self.retentionDays = max(1, retentionDays)
        self.now = now
        // Autoupdating: days follow the Mac to a new time zone without a relaunch (D-141).
        calendar = .autoupdatingCurrent
    }

    // MARK: - Recording

    public func record(_ snapshot: Snapshot) throws {
        try accumulateBattery(snapshot)
        chargerTally.add(snapshot.system.battery, at: snapshot.at, calendar: calendar)
        let minute = HistoryTier.minute.bucketStart(snapshot.at)
        if current?.start == minute {
            current?.add(snapshot)
        } else {
            let finished = current
            var fresh = MinuteAccumulator(start: minute)
            fresh.add(snapshot)
            current = fresh
            if let finished {
                // Written after `current` moves on, so a failing write drops one minute
                // instead of retrying on every snapshot.
                try write(finished, latestMinute: max(finished.start, minute))
            }
        }
        try runRetentionIfDue()
    }

    public func flush() throws {
        guard let partial = current else {
            try writeBattery()
            try writeChargers()
            return
        }
        current = nil
        // Writes the battery too.
        try write(partial, latestMinute: partial.start)
    }

    // MARK: - Battery health by day

    struct BatteryAccumulator {
        let day: Int64
        var maxCapacity: Double?
        var cycles: Int?
        /// Seconds on battery not yet written; the table adds them, so a relaunch mid-day keeps
        /// the earlier part of the day.
        var unsavedSeconds: Double = 0
    }

    private func accumulateBattery(_ snapshot: Snapshot) throws {
        guard let battery = snapshot.system.battery else {
            return
        }
        let day = Int64(calendar.startOfDay(for: snapshot.at).timeIntervalSince1970)
        if let today = batteryToday, today.day != day {
            try writeBattery()
            batteryToday = nil
        }
        var today = batteryToday ?? BatteryAccumulator(day: day)
        today.maxCapacity = battery.maxCapacityPercent ?? today.maxCapacity
        today.cycles = battery.cycleCount ?? today.cycles
        if battery.source == .battery {
            // At most a minute per snapshot: a longer gap is the Mac asleep. Power Nap's brief
            // wakes sample about hourly, and each counted the hour since the last, so a day
            // asleep in a bag read as 24 hours on battery (D-133).
            today.unsavedSeconds += min(snapshot.interval.seconds, Self.longestCountedInterval)
        }
        // Written with each finished minute, in the same transaction (`write`): once a minute is
        // plenty for a daily figure.
        batteryToday = today
    }

    private func writeBattery() throws {
        guard batteryToday != nil else {
            return
        }
        try database.write { db in
            try self.writeBattery(db)
        }
    }

    /// Adds today's unsaved battery figures inside the caller's transaction. Nothing to do
    /// without a battery.
    private func writeBattery(_ db: Database) throws {
        guard var today = batteryToday else {
            return
        }
        try db.cachedStatement(sql: """
        INSERT INTO battery_day (day, maxCapacity, cycles, secondsOnBattery) VALUES (?, ?, ?, ?)
        ON CONFLICT(day) DO UPDATE SET
            maxCapacity = COALESCE(excluded.maxCapacity, maxCapacity),
            cycles = COALESCE(excluded.cycles, cycles),
            secondsOnBattery = secondsOnBattery + excluded.secondsOnBattery
        """).execute(arguments: [today.day, today.maxCapacity, today.cycles, today.unsavedSeconds])
        today.unsavedSeconds = 0
        batteryToday = today
    }

    /// Writes one minute's rows, today's battery health, and the apps that are new or changed,
    /// then rolls up every quarter-hour that is complete (before `latestMinute`'s quarter) and
    /// not yet in the quarter tier, then every complete hour from those. One transaction.
    private func write(_ minute: MinuteAccumulator, latestMinute: Int64) throws {
        let changed = Self.changedApps(minute.identities, written: writtenApps)
        let battery = batteryToday
        let chargers = chargerTally.drain()
        do {
            try database.write { db in
                try Self.upsertApps(changed, db)
                try Self.insertMinute(minute, db)
                try self.writeBattery(db)
                try Self.addChargerUse(chargers, db)
                try Self.rollUpQuarters(before: HistoryTier.quarter.bucketStart(latestMinute), db)
                try Self.rollUpHours(before: HistoryTier.hour.bucketStart(latestMinute), db)
            }
        } catch {
            // The transaction rolled back: the battery seconds weren't saved either.
            batteryToday = battery
            chargerTally.restore(chargers)
            historyLog.error("Writing minute \(minute.start) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        for app in changed {
            writtenApps[app.id] = app
        }
    }

    private static func upsertApps(_ apps: some Sequence<AppIdentity>, _ db: Database) throws {
        let statement = try db.cachedStatement(sql: """
        INSERT INTO app (id, name, bundleID, iconKey, kind) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET
            name = excluded.name, bundleID = excluded.bundleID,
            iconKey = excluded.iconKey, kind = excluded.kind
        """)
        for app in apps {
            try statement.execute(arguments: [app.id, app.name, app.bundleID, app.iconKey, app.kind.rawValue])
        }
    }

    private static let minuteInsertSQL: String = {
        let columns = Metric.allCases.flatMap { [$0.averageColumn, $0.maximumColumn] }
        let placeholders = Array(repeating: "?", count: columns.count + 3).joined(separator: ", ")
        let updates = Metric.allCases.flatMap { metric -> [String] in
            let avg = metric.averageColumn
            let max = metric.maximumColumn
            return [
                """
                \(avg) = CASE WHEN minute.\(avg) IS NULL THEN excluded.\(avg) \
                WHEN excluded.\(avg) IS NULL THEN minute.\(avg) \
                ELSE (minute.\(avg) * minute.samples + excluded.\(avg) * excluded.samples) \
                / (minute.samples + excluded.samples) END
                """,
                "\(max) = COALESCE(MAX(minute.\(max), excluded.\(max)), minute.\(max), excluded.\(max))",
            ]
        }
        return """
        INSERT INTO minute (t, app, samples, \(columns.joined(separator: ", "))) VALUES (\(placeholders))
        ON CONFLICT (t, app) DO UPDATE SET
            \(updates.joined(separator: ",\n    ")),
            samples = minute.samples + excluded.samples
        """
    }()

    /// Inserts the minute's rows. A row that already exists (flushed on quit, then the app
    /// relaunched inside the same minute) merges, weighted by sample count.
    private static func insertMinute(_ minute: MinuteAccumulator, _ db: Database) throws {
        let statement = try db.cachedStatement(sql: minuteInsertSQL)
        for (app, bucket) in minute.buckets {
            var arguments: [(any DatabaseValueConvertible)?] = [minute.start, app, bucket.samples]
            for metric in bucket.metrics {
                arguments.append(metric.average)
                arguments.append(metric.max)
            }
            try statement.execute(arguments: StatementArguments(arguments))
        }
    }

    // MARK: - Retention

    private func runRetentionIfDue() throws {
        let date = now()
        if let last = lastRetentionRun, date.timeIntervalSince(last) < Self.retentionInterval, date >= last {
            return
        }
        lastRetentionRun = date
        try applyRetention(at: date)
    }

    private func applyRetention(at date: Date) throws {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        try database.write { db in
            try Self.rollUpExpiring(minuteCutoff: seconds - keptSeconds(.minute), quarterCutoff: seconds - keptSeconds(.quarter), db)
            var removed: [String] = []
            for tier in HistoryTier.allCases {
                try db.execute(sql: "DELETE FROM \(tier.table) WHERE t < ?", arguments: [seconds - keptSeconds(tier)])
                removed.append("\(db.changesCount) \(tier.rawValue)")
                // Rows from a clock that was set ahead and back: never real, and in the way.
                try db.execute(sql: "DELETE FROM \(tier.table) WHERE t > ?", arguments: [seconds + tier.bucketSeconds])
            }
            try db.execute(sql: "DELETE FROM device_battery WHERE t < ?", arguments: [seconds - keptSeconds(.hour)])
            try db.execute(sql: "DELETE FROM power_event WHERE t < ?", arguments: [Double(seconds - keptSeconds(.hour))])
            try db.execute(sql: "DELETE FROM focus WHERE end < ?", arguments: [Double(seconds - keptSeconds(.hour))])
            try db.execute(sql: "DELETE FROM agent_usage WHERE t < ?", arguments: [seconds - keptSeconds(.hour)])
            try db.execute(sql: "DELETE FROM build_run WHERE t < ?", arguments: [seconds - keptSeconds(.hour)])
            try db.execute(sql: "DELETE FROM app_launch WHERE t < ?", arguments: [seconds - keptSeconds(.hour)])
            try db.execute(sql: "DELETE FROM charger_use WHERE day < ?", arguments: [seconds - keptSeconds(.hour)])
            removed.append("\(db.changesCount) device")
            try Self.pruneNetwork(db, now: seconds, keep: keptSeconds(.hour))
            historyLog.debug("Retention removed rows: \(removed.joined(separator: ", "), privacy: .public)")
        }
        try compactIfMostlyEmpty()
    }

    /// Deleted rows' pages are reused by new ones, so in steady state the file stays the size of
    /// its working set (~40–60 MB for a year, D-089). After a big drop (retention shortened, many apps
    /// gone) most pages sit free and the file never shrinks by itself: then rebuild it once, and
    /// trim the write-ahead log (install size budget, D-058).
    private func compactIfMostlyEmpty() throws {
        let (pages, free, pageSize) = try database.read { db in
            try (
                Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0,
                Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0,
                Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            )
        }
        if Self.shouldCompact(pages: pages, freePages: free, pageSize: pageSize) {
            try database.vacuum()
            historyLog.info("Compacted history: \(free) of \(pages) pages were free")
        }
        if fileURL != nil {
            _ = try database.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        }
    }

    /// Pure: compact when over half the file is free and that's worth at least 2 MB.
    static func shouldCompact(pages: Int, freePages: Int, pageSize: Int) -> Bool {
        pages > 0 && freePages * 2 > pages && freePages * pageSize >= 2 * 1024 * 1024
    }

    public func setRetention(days: Int) {
        retentionDays = max(1, days)
        // Applied on the next record.
        lastRetentionRun = nil
    }

    // MARK: - Storage

    public func storageSizeBytes() -> UInt64 {
        guard let fileURL else {
            return 0
        }
        return ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let path = fileURL.path + suffix
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
            return total + (size ?? 0)
        }
    }

    public func deleteAll() throws {
        current = nil
        lastRetentionRun = nil
        batteryToday = nil
        writtenApps = [:]
        lastDeviceReading = [:]
        try database.write { db in
            for table in [
                "minute",
                "quarter",
                "hour",
                "device_battery",
                "power_event",
                "focus",
                "app",
                "alert_state",
                "alert_log",
                "battery_day",
                "agent_usage",
                "build_run",
                "app_launch",
                "network_change",
                "wifi_minute",
                "desk_sample",
                "note",
                "sensor_change", "charger_use", "notification_event",
            ] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
        try database.vacuum()
        if fileURL != nil {
            _ = try database.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        }
    }
}

extension SQLiteHistoryStore {
    /// SQLite's `synchronous` level: 1 is NORMAL, 2 is FULL. For tests.
    func synchronousLevel() throws -> Int {
        try database.read { try Int.fetchOne($0, sql: "PRAGMA synchronous") ?? -1 }
    }

    /// Pure: the identities that the `app` table doesn't have, or has differently.
    static func changedApps(
        _ identities: [AppIdentity.ID: AppIdentity], written: [AppIdentity.ID: AppIdentity]
    ) -> [AppIdentity] {
        identities.values.filter { written[$0.id] != $0 }
    }
}
