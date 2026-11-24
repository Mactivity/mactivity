import Core
import CryptoKit
import Foundation
import GRDB
@testable import History
import Testing

/// Migrations as a customer's Mac runs them: on a file an older version left, with rows in it.
/// Every other history test starts from an empty database, where only the create-from-nothing
/// path runs.
@Suite("History migrations on an older Mac's file")
struct HistoryMigrationTests {
    private static let base = Int64(Build.base.timeIntervalSince1970)

    /// A history file as an older Mactivity left it: migrated up to `version`, filled, closed.
    private func oldFile(upTo version: String, _ fill: (Database) throws -> Void) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("history.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try HistorySchema.migrator.migrate(queue, upTo: version)
        try queue.write(fill)
        try queue.close()
        return url
    }

    /// A tier row with the columns every version has. The table name is the test's own.
    private static func insert(
        _ tier: String, t: Int64, app: String = "*", samples: Int, cpu: Double = 0, peak: Double = 0, _ db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO \(tier)
                (t, app, samples, cpuAvg, cpuMax, memoryAvg, memoryMax, diskReadAvg, diskReadMax, diskWriteAvg, diskWriteMax)
            VALUES (?, ?, ?, ?, ?, 0, 0, 0, 0, 0, 0)
            """,
            arguments: [t, app, samples, cpu, peak]
        )
    }

    // MARK: - From the first version

    @Test("A file from the first version opens with its figures, apps and alerts, and goes on recording")
    func oldestFileMigrates() async throws {
        let base = Self.base
        let threeDaysAgo = base - 3 * 86400
        let alertID = UUID()
        let url = try oldFile(upTo: "v1: tiers, apps, alerts") { db in
            try db.execute(sql: """
            INSERT INTO app (id, name, bundleID, iconKey, kind) VALUES ('a', 'App a', 'com.example.a', '/Applications/a.app', 'app')
            """)
            try Self.insert("minute", t: base - 600, samples: 12, cpu: 40, peak: 80, db)
            try Self.insert("minute", t: base - 600, app: "a", samples: 12, cpu: 30, peak: 60, db)
            try Self.insert("quarter", t: threeDaysAgo, samples: 180, cpu: 20, peak: 90, db)
            try Self.insert("quarter", t: threeDaysAgo, app: "a", samples: 180, cpu: 10, peak: 50, db)
            try db.execute(
                sql: "INSERT INTO alert_state (appID, rule, lastFired) VALUES ('a', 'highCPU', ?)",
                arguments: [Double(base - 3600)]
            )
            try db.execute(
                sql: """
                INSERT INTO alert_log (id, rule, appID, appName, appBundleID, appIconKey, appKind, firedAt, title, body)
                VALUES (?, 'highCPU', 'a', 'App a', 'com.example.a', '/Applications/a.app', 'app', ?, 'App a is busy', 'For ten minutes')
                """,
                arguments: [alertID.uuidString, Double(base - 3600)]
            )
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let clock = TestClock()
        let store = try SQLiteHistoryStore(url: url, now: { clock.now })
        let tenMinutesAgo = SeriesPoint(at: Build.date(-600), average: 40, maximum: 80)
        let quarterThreeDaysAgo = SeriesPoint(at: Build.date(-3 * day), average: 20, maximum: 90)

        // What was there reads back through the same queries the charts use.
        #expect(try await store.series(metric: .cpu, app: nil, range: .h12) == [tenMinutesAgo])
        #expect(try await store.series(metric: .cpu, app: "a", range: .d7) == [
            SeriesPoint(at: Build.date(-3 * day), average: 10, maximum: 50),
        ])
        #expect(try await store.topApps(metric: .cpu, range: .h12, limit: 5) == [AppTotal(app: Build.identity("a"), value: 30)])
        // The quarter got its covered minutes (v10): 15 of them, so 20% for 900 s.
        #expect(try await store.total(metric: .cpu, range: .d7) == 18000)
        // Figures that didn't exist yet are missing, not zero.
        #expect(try await store.series(metric: .powerDraw, app: nil, range: .h12).isEmpty)
        #expect(try await store.series(metric: .batteryTempInUse, app: nil, range: .d7).isEmpty)

        let key = AlertKey(appID: "a", rule: .highCPU)
        #expect(try await store.loadAlertState() == AlertState(lastFired: [key: Build.date(-3600)]))
        let alerts = try await store.recentAlerts(limit: 5)
        #expect(alerts.map(\.id) == [alertID])
        #expect(alerts.first?.title == "App a is busy")

        // And it goes on: a new minute is written, and the old minute rolls up into a quarter
        // and an hour beside the rows that were already there.
        try await store.record(Build.snapshot(at: 0, cpu: 50, apps: [Build.app("a", cpu: 5)]))
        try await store.record(Build.snapshot(at: minute, cpu: 50))
        clock.set(offset: 2 * minute)
        #expect(try await store.series(metric: .cpu, app: nil, range: .h12) == [
            tenMinutesAgo, SeriesPoint(at: Build.base, average: 50, maximum: 50),
        ])
        #expect(try await store.series(metric: .cpu, app: nil, range: .d7) == [
            quarterThreeDaysAgo, SeriesPoint(at: Build.date(-900), average: 40, maximum: 80),
        ])
        #expect(try await store.series(metric: .cpu, app: nil, range: .d90) == [
            quarterThreeDaysAgo, SeriesPoint(at: Build.date(-hour), average: 40, maximum: 80),
        ])
    }

    // MARK: - The two migrations that rewrite figures

    @Test("v10 counts a quarter's minutes where it still has them and bounds the rest by samples (D-108)")
    func coveredMinutesBackfill() throws {
        let queue = try DatabaseQueue()
        let migrator = HistorySchema.migrator
        try migrator.migrate(queue, upTo: "v9: on battery")
        try queue.write { db in
            // A quarter still inside the minute tier: three of the Mac's minutes, one of an app's.
            try Self.insert("quarter", t: 9000, samples: 36, db)
            for t: Int64 in [9000, 9060, 9120] {
                try Self.insert("minute", t: t, samples: 12, db)
            }
            try Self.insert("minute", t: 9180, app: "a", samples: 12, db)
            // Quarters older than their minutes: 30 samples can't cover more than 10 minutes,
            // 180 are capped at the quarter's 15, and one sample is one minute.
            try Self.insert("quarter", t: 9900, samples: 30, db)
            try Self.insert("quarter", t: 36000, samples: 180, db)
            try Self.insert("quarter", t: 36900, samples: 1, db)
            // Hours: one with no quarters left, one of those capped at 60, one over the first two quarters.
            try db.execute(sql: "INSERT INTO hour (t, app, samples) VALUES (0, '*', 100), (3600, '*', 600), (7200, '*', 66)")
        }
        try migrator.migrate(queue)
        let (quarters, hours) = try queue.read { db in
            try (
                Int.fetchAll(db, sql: "SELECT minutes FROM quarter WHERE app = '*' ORDER BY t"),
                Int.fetchAll(db, sql: "SELECT minutes FROM hour WHERE app = '*' ORDER BY t")
            )
        }
        #expect(quarters == [3, 10, 15, 1])
        #expect(hours == [34, 60, 13])
    }

    @Test("v12 caps a finished day's time on battery at the minutes sampled, and leaves today's alone (D-133)")
    func batteryDaysBounded() throws {
        let queue = try DatabaseQueue()
        let migrator = HistorySchema.migrator
        try migrator.migrate(queue, upTo: "v11: alert levels")
        // The migration reads the real clock for "today", so the day still being recorded is one
        // that hasn't come: the first of January 2100.
        let notYet: Int64 = 4_102_444_800
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO battery_day (day, secondsOnBattery) VALUES (0, 86400), (86400, 3000), (172800, 7200), (?, 86400)",
                arguments: [notYet]
            )
            try db.execute(
                sql: """
                INSERT INTO hour (t, app, samples, minutes)
                VALUES (0, '*', 600, 60), (3600, '*', 280, 47), (86400, '*', 600, 60), (?, '*', 600, 60)
                """,
                arguments: [notYet]
            )
        }
        try migrator.migrate(queue)
        let seconds = try queue.read { db in
            try Double.fetchAll(db, sql: "SELECT secondsOnBattery FROM battery_day ORDER BY day")
        }
        // Capped to 107 minutes; already within its 60; no hours to go by; not a finished day.
        #expect(seconds == [6420, 3000, 7200, 86400])
    }

    // MARK: - Every version

    /// The tables a version has, without SQLite's and the migrator's own.
    private static func tables(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
        SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name
        """)
    }

    /// One row in every table, each column filled by its declared type, and what was written.
    private static func fillEveryTable(_ db: Database) throws -> [String: [Row]] {
        var written: [String: [Row]] = [:]
        for table in try tables(db) {
            let columns = try Row.fetchAll(db, sql: "SELECT name, type FROM pragma_table_info(?) ORDER BY cid", arguments: [table])
            let names = columns.map { "\"\($0["name"] as String)\"" }.joined(separator: ", ")
            let values = columns.map { column -> String in
                switch column["type"] as String {
                case "INTEGER": "7"
                case "REAL": "7.5"
                default: "'x'"
                }
            }
            try db.execute(sql: "INSERT INTO \(table) (\(names)) VALUES (\(values.joined(separator: ", ")))")
            written[table] = try Row.fetchAll(db, sql: "SELECT \(names) FROM \(table)")
        }
        return written
    }

    @Test("From every version, a file with a row in each table migrates to the newest and keeps every value")
    func everyStepFromEveryVersion() throws {
        let migrator = HistorySchema.migrator
        for version in migrator.migrations {
            let queue = try DatabaseQueue()
            try migrator.migrate(queue, upTo: version)
            let written = try queue.write { try Self.fillEveryTable($0) }
            #expect(!written.isEmpty)
            try migrator.migrate(queue)
            try queue.read { db in
                for (table, rows) in written {
                    let names = rows[0].columnNames.map { "\"\($0)\"" }.joined(separator: ", ")
                    let kept = try Row.fetchAll(db, sql: "SELECT \(names) FROM \(table)")
                    #expect(kept == rows, "\(table), from \(version)")
                }
            }
        }
    }

    // MARK: - Frozen

    /// A short hash of the tables, columns and indexes as they are after a migration. Read from
    /// SQLite's own description rather than the stored CREATE text, so spacing doesn't matter.
    private static func layoutHash(_ db: Database) throws -> String {
        var lines: [String] = []
        for table in try tables(db) {
            let withoutRowID = try Bool.fetchOne(
                db, sql: "SELECT wr FROM pragma_table_list WHERE schema = 'main' AND name = ?", arguments: [table]
            ) ?? false
            lines.append("table \(table) withoutRowID=\(withoutRowID)")
            let columns = try Row.fetchAll(
                db, sql: "SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info(?) ORDER BY cid", arguments: [table]
            )
            for column in columns {
                lines.append("  " + column.databaseValues.map(\.description).joined(separator: " "))
            }
            for index in try Row.fetchAll(db, sql: "SELECT name, \"unique\" FROM pragma_index_list(?) ORDER BY name", arguments: [table]) {
                let name: String = index["name"]
                let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_index_info(?) ORDER BY seqno", arguments: [name])
                lines.append("  index \(name) unique=\(index["unique"] as Bool) on \(columns.joined(separator: ", "))")
            }
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Every migration in order, with the layout it leaves. Add a line for a new migration; a
    /// line that is already here changes only if a migration was edited, which a released one
    /// never may be: Macs that already ran it would be left with a different file from new ones.
    /// v12 changes figures, not the layout, so its hash is v11's; `batteryDaysBounded` and
    /// `coveredMinutesBackfill` cover what the two figure-rewriting migrations do.
    /// On 2026-11-17 the last four (v21 to v25) are built but not released.
    private static let frozen: [String] = [
        "v1: tiers, apps, alerts → 378c680b78ec",
        "v2: energy impact, sensors, battery days → 1280bc4e1a50",
        "v3: app series indexes → 4803b2ac7cc1",
        "v4: hour tier → 6df34f4bad0e",
        "v5: device batteries → 4b491dd08d8f",
        "v6: battery, pressure, swap, free space → 9035df4fa482",
        "v7: sleep and wake → d6b4bbba8f27",
        "v8: time in front → f0c2590eb1c6",
        "v9: on battery → 5301dc2fd382",
        "v10: covered minutes → 8f8522725116",
        "v11: alert levels → e67171578f41",
        "v12: time on battery within sampled time → e67171578f41",
        "v13: agent usage → 0ae2038d9835",
        "v14: build runs → e7fd37fb8ec3",
        "v15: app launches → dacf52e10ea9",
        "v16: network changes and Wi-Fi → bc11ac43ab8d",
        "v17: desk → 334a7c7b5af6",
        "v18: notes → 484e7ee5b7c8",
        "v19: power draw → 66c02c1eadf8",
        "v20: sensor changes → 21a27d51273f",
        "v21: battery temperature → 9d1e58d85a3d",
        "v22: charger use → 515efbc57746",
        "v23: test runs → 8058459a101b",
        "v25: notification events → 8194358aa402",
    ]

    @Test("No migration was edited, removed or reordered: each leaves the tables it always did")
    func migrationsAreFrozen() throws {
        let migrator = HistorySchema.migrator
        let queue = try DatabaseQueue()
        var actual: [String] = []
        for version in migrator.migrations {
            try migrator.migrate(queue, upTo: version)
            try actual.append("\(version) → \(queue.read { try Self.layoutHash($0) })")
        }
        #expect(actual == Self.frozen, "If this is a new migration, add its line:\n\(actual.map { "\"\($0)\"," }.joined(separator: "\n"))")
    }
}
