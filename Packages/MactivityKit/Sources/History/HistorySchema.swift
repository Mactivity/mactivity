import Core
import Foundation
import GRDB
import os

let historyLog = Logger(subsystem: "app.mactivity.history", category: "store")

/// Table layout and migrations for the history file (spec 6.7).
///
/// Tiers hold one row per (bucket start, app) with every metric as an `Avg` and a `Max` column.
/// `t` is the bucket start in integer seconds since 1970. `samples` is how many snapshots fed the
/// row; it lets two writes of the same minute (a flush on quit, then a relaunch inside the same
/// minute) merge as a weighted average instead of one overwriting the other.
enum HistorySchema {
    /// App ID of the system-wide rows.
    static let systemAppID = "*"

    /// Minute rows are kept this long, whatever the retention setting is.
    static let minuteRetention: Int64 = 48 * 3600
    /// Quarter-hour rows are kept at most this long; the hour tier holds the rest (D-089).
    static let quarterRetentionDays = 30
    /// Wi-Fi's minute readings (D-234).
    static let wifiRetentionDays = 30

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Frozen: never edit a shipped migration, add a new one.
        migrator.registerMigration("v1: tiers, apps, alerts") { db in
            try db.execute(sql: """
            CREATE TABLE app (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                bundleID TEXT,
                iconKey TEXT NOT NULL,
                kind TEXT NOT NULL
            );
            """)
            for tier in ["minute", "quarter"] {
                try db.execute(sql: """
                CREATE TABLE \(tier) (
                    t INTEGER NOT NULL,
                    app TEXT NOT NULL,
                    samples INTEGER NOT NULL,
                    cpuAvg REAL NOT NULL, cpuMax REAL NOT NULL,
                    memoryAvg REAL NOT NULL, memoryMax REAL NOT NULL,
                    energyAvg REAL, energyMax REAL,
                    diskReadAvg REAL NOT NULL, diskReadMax REAL NOT NULL,
                    diskWriteAvg REAL NOT NULL, diskWriteMax REAL NOT NULL,
                    netInAvg REAL, netInMax REAL,
                    netOutAvg REAL, netOutMax REAL,
                    gpuAvg REAL, gpuMax REAL,
                    PRIMARY KEY (t, app)
                ) WITHOUT ROWID;
                """)
            }
            try db.execute(sql: """
            CREATE TABLE alert_state (
                appID TEXT NOT NULL,
                rule TEXT NOT NULL,
                lastFired REAL NOT NULL,
                PRIMARY KEY (appID, rule)
            ) WITHOUT ROWID;
            CREATE TABLE alert_log (
                id TEXT NOT NULL UNIQUE,
                rule TEXT NOT NULL,
                appID TEXT NOT NULL,
                appName TEXT NOT NULL,
                appBundleID TEXT,
                appIconKey TEXT NOT NULL,
                appKind TEXT NOT NULL,
                firedAt REAL NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL
            );
            CREATE INDEX alert_log_firedAt ON alert_log (firedAt);
            """)
        }
        // Expansions E8, E13, E14: Energy Impact, sensor and thermal history, battery health by day.
        migrator.registerMigration("v2: energy impact, sensors, battery days") { db in
            for tier in ["minute", "quarter"] {
                for stem in ["energyImpact", "cpuTemperature", "gpuTemperature", "fanSpeed", "thermalPressure"] {
                    try db.execute(sql: "ALTER TABLE \(tier) ADD COLUMN \(stem)Avg REAL")
                    try db.execute(sql: "ALTER TABLE \(tier) ADD COLUMN \(stem)Max REAL")
                }
            }
            try db.execute(sql: """
            CREATE TABLE battery_day (
                day INTEGER PRIMARY KEY NOT NULL,
                maxCapacity REAL,
                cycles INTEGER,
                secondsOnBattery REAL NOT NULL DEFAULT 0
            );
            """)
        }
        // One app's series (`series`, `total`) is a key range on (app, t). The primary key leads
        // with t, so without these a 24 h strip scanned every app's rows in the range (D-086).
        migrator.registerMigration("v3: app series indexes") { db in
            for tier in ["minute", "quarter"] {
                try db.execute(sql: "CREATE INDEX \(tier)_app_t ON \(tier) (app, t)")
            }
        }
        // A year of history (D-089): hourly rows, rolled up from quarter-hours and kept for the
        // retention setting, while quarter-hours stop at 30 days. The columns are spelled out, not
        // taken from `Metric.allCases`, so this migration stays frozen when a metric is added.
        migrator.registerMigration("v4: hour tier") { db in
            let stems = [
                "cpu", "memory", "energy", "diskRead", "diskWrite", "netIn", "netOut", "gpu",
                "energyImpact", "cpuTemperature", "gpuTemperature", "fanSpeed", "thermalPressure",
            ]
            let columns = stems.map { "\($0)Avg REAL, \($0)Max REAL" }.joined(separator: ",\n    ")
            try db.execute(sql: """
            CREATE TABLE hour (
                t INTEGER NOT NULL,
                app TEXT NOT NULL,
                samples INTEGER NOT NULL,
                \(columns),
                PRIMARY KEY (t, app)
            ) WITHOUT ROWID;
            CREATE INDEX hour_app_t ON hour (app, t);
            """)
        }
        // Accessory batteries over time (D-094): a row when a level moves, or hourly. Keyed by
        // device first, since every read is one device's range.
        migrator.registerMigration("v5: device batteries") { db in
            try db.execute(sql: """
            CREATE TABLE device_battery (
                device TEXT NOT NULL,
                t INTEGER NOT NULL,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                percent REAL NOT NULL,
                PRIMARY KEY (device, t)
            ) WITHOUT ROWID;
            CREATE INDEX device_battery_t ON device_battery (t);
            """)
        }
        // Battery level, memory pressure, swap and free space (D-095): system rows only, but a
        // column in every tier like the sensors. Spelled out: frozen.
        migrator.registerMigration("v6: battery, pressure, swap, free space") { db in
            for tier in ["minute", "quarter", "hour"] {
                for stem in ["batteryLevel", "memoryPressure", "swapUsed", "diskFree"] {
                    try db.execute(sql: "ALTER TABLE \(tier) ADD COLUMN \(stem)Avg REAL")
                    try db.execute(sql: "ALTER TABLE \(tier) ADD COLUMN \(stem)Max REAL")
                }
            }
        }
        // Sleep and wake (D-096): one row per event, recorded as it happens.
        migrator.registerMigration("v7: sleep and wake") { db in
            try db.execute(sql: """
            CREATE TABLE power_event (
                t REAL NOT NULL,
                kind TEXT NOT NULL,
                reason TEXT,
                PRIMARY KEY (t, kind)
            ) WITHOUT ROWID;
            """)
        }
        // Time in front (D-098): one row per stretch an app was frontmost while in use.
        migrator.registerMigration("v8: time in front") { db in
            try db.execute(sql: """
            CREATE TABLE focus (
                start REAL PRIMARY KEY NOT NULL,
                end REAL NOT NULL,
                app TEXT NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX focus_end ON focus (end);
            """)
        }
        // On battery (D-100): which buckets ran on battery, for battery use by app.
        migrator.registerMigration("v9: on battery") { db in
            for tier in ["minute", "quarter", "hour"] {
                try db.execute(sql: "ALTER TABLE \(tier) ADD COLUMN onBatteryAvg REAL")
                try db.execute(sql: "ALTER TABLE \(tier) ADD COLUMN onBatteryMax REAL")
            }
        }
        // Covered minutes (D-108): how many minutes a rolled-up row was rolled up from. A total
        // is each row's average rate × the time it covers; taking the whole bucket overcounted
        // every hour the Mac slept through part of. Quarters still inside the minute tier count
        // their minutes. Older rows can only be bounded: sampling never runs slower than once
        // every 20 s (Low Power Mode, idle), so a row can't cover more than samples ÷ 3 minutes.
        migrator.registerMigration("v10: covered minutes") { db in
            try db.execute(sql: """
            ALTER TABLE quarter ADD COLUMN minutes INTEGER;
            ALTER TABLE hour ADD COLUMN minutes INTEGER;
            UPDATE quarter SET minutes = (
                SELECT COUNT(*) FROM minute AS m WHERE m.app = quarter.app AND m.t >= quarter.t AND m.t < quarter.t + 900
            );
            UPDATE quarter SET minutes = MIN(15, (samples + 2) / 3) WHERE minutes = 0;
            UPDATE hour SET minutes = (
                SELECT SUM(q.minutes) FROM quarter AS q WHERE q.app = hour.app AND q.t >= hour.t AND q.t < hour.t + 3600
            );
            UPDATE hour SET minutes = MIN(60, (samples + 2) / 3) WHERE minutes IS NULL OR minutes = 0;
            """)
        }
        // The figure an alert last fired at, for growing memory's "grown again since" (D-111).
        migrator.registerMigration("v11: alert levels") { db in
            try db.execute(sql: "ALTER TABLE alert_state ADD COLUMN level REAL")
        }
        // Days asleep counted as on battery (D-133); today is still being recorded.
        migrator.registerMigration("v12: time on battery within sampled time") { db in
            try boundBatteryDays(db, before: Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970))
        }
        // Agent history (D-192): each agent's quarter-hours per project, kept as long as hours.
        migrator.registerMigration("v13: agent usage") { db in
            try db.execute(sql: """
            CREATE TABLE agent_usage (
                t INTEGER NOT NULL,
                agent TEXT NOT NULL,
                project TEXT NOT NULL,
                minutes INTEGER NOT NULL,
                cpu REAL NOT NULL,
                memory INTEGER NOT NULL,
                PRIMARY KEY (t, agent, project)
            ) WITHOUT ROWID;
            """)
        }
        // Build times (D-209): one row per build, its start to the last compiler seen.
        migrator.registerMigration("v14: build runs") { db in
            try db.execute(sql: """
            CREATE TABLE build_run (
                t REAL NOT NULL,
                project TEXT NOT NULL,
                endT REAL NOT NULL,
                tool TEXT NOT NULL,
                cpu REAL NOT NULL,
                memory INTEGER NOT NULL,
                PRIMARY KEY (t, project)
            ) WITHOUT ROWID;
            """)
        }
        // App launch times (D-215).
        migrator.registerMigration("v15: app launches") { db in
            try db.execute(sql: """
            CREATE TABLE app_launch (
                t REAL NOT NULL,
                app TEXT NOT NULL,
                name TEXT NOT NULL,
                seconds REAL NOT NULL,
                PRIMARY KEY (t, app)
            ) WITHOUT ROWID;
            """)
        }
        // Network changes and Wi-Fi over time (D-233, D-234).
        migrator.registerMigration("v16: network changes and Wi-Fi") { db in
            try db.execute(sql: """
            CREATE TABLE network_change (
                t REAL PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                interface TEXT
            ) WITHOUT ROWID;
            CREATE TABLE wifi_minute (
                t INTEGER PRIMARY KEY NOT NULL,
                rssi INTEGER NOT NULL,
                noise INTEGER NOT NULL,
                rate REAL NOT NULL,
                channel INTEGER
            ) WITHOUT ROWID;
            """)
        }
        // The desk every 10 minutes: displays and the lid (D-237).
        migrator.registerMigration("v17: desk") { db in
            try db.execute(sql: """
            CREATE TABLE desk_sample (
                t INTEGER PRIMARY KEY NOT NULL,
                displays INTEGER NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                lid INTEGER
            ) WITHOUT ROWID;
            """)
        }
        // Notes on history (1.7, D-253): the person's own, kept until deleted.
        migrator.registerMigration("v18: notes") { db in
            try db.execute(sql: """
            CREATE TABLE note (
                id TEXT PRIMARY KEY NOT NULL,
                t INTEGER NOT NULL,
                text TEXT NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX note_t ON note (t);
            """)
        }
        // The whole Mac's power draw (D-258): watts over the Battery tab's range, from now on.
        migrator.registerMigration("v19: power draw") { db in
            for tier in ["minute", "quarter", "hour"] {
                try db.execute(sql: "ALTER TABLE \(tier) ADD COLUMN powerDrawAvg REAL")
                try db.execute(sql: "ALTER TABLE \(tier) ADD COLUMN powerDrawMax REAL")
            }
        }
        // Camera and microphone history (1.8, D-259): each change in what the privacy
        // indicators show, as "cam:us.zoom.xos,mic:us.zoom.xos".
        migrator.registerMigration("v20: sensor changes") { db in
            try db.execute(sql: """
            CREATE TABLE sensor_change (
                t REAL PRIMARY KEY NOT NULL,
                active TEXT NOT NULL
            ) WITHOUT ROWID;
            """)
        }
        registerLaterMigrations(&migrator)
        return migrator
    }

    /// Caps each finished day's time on battery at the minutes Mactivity sampled that day, from
    /// the whole Mac's hour rows (D-133). It only ever lowers a figure, and leaves days without
    /// hour rows alone: before D-133, sleep with Power Nap counted in full, up to 24 hours a day.
    static func boundBatteryDays(_ db: Database, before day: Int64) throws {
        try db.execute(sql: """
        UPDATE battery_day SET secondsOnBattery = MIN(secondsOnBattery, 60 * (
            SELECT SUM(h.minutes) FROM hour AS h WHERE h.app = '*' AND h.t >= battery_day.day AND h.t < battery_day.day + 86400
        ))
        WHERE day < ? AND EXISTS (
            SELECT 1 FROM hour AS h WHERE h.app = '*' AND h.minutes IS NOT NULL AND h.t >= battery_day.day AND h.t < battery_day.day + 86400
        )
        """, arguments: [day])
    }
}

/// A stored resolution. Ranges up to 24 h read minutes; 7 d and 30 d read quarter-hours;
/// 90 d and a year read hours.
enum HistoryTier: String, CaseIterable {
    case minute
    case quarter
    case hour

    init(range: HistoryRange) {
        switch range {
        case .h12, .h24: self = .minute
        case .d7, .d30: self = .quarter
        case .d90, .y1: self = .hour
        }
    }

    /// The next coarser tier, which keeps rows for longer. Nil for the coarsest.
    var coarser: HistoryTier? {
        switch self {
        case .minute: .quarter
        case .quarter: .hour
        case .hour: nil
        }
    }

    var table: String {
        rawValue
    }

    /// SQL for the seconds a row of this tier covers, `alias` being the row's table alias
    /// (D-108): a minute row its minute; a rolled-up row the minutes it was rolled up from, less
    /// than its bucket when the Mac slept or Mactivity wasn't running for part of it.
    func coveredSeconds(_ alias: String) -> String {
        switch self {
        case .minute: "60"
        case .quarter, .hour: "(COALESCE(\(alias).minutes, \(bucketSeconds / 60)) * 60)"
        }
    }

    var bucketSeconds: Int64 {
        switch self {
        case .minute: 60
        case .quarter: 900
        case .hour: 3600
        }
    }

    /// Start of the bucket containing `seconds` (seconds since 1970).
    func bucketStart(_ seconds: Int64) -> Int64 {
        seconds - ((seconds % bucketSeconds) + bucketSeconds) % bucketSeconds
    }

    func bucketStart(_ date: Date) -> Int64 {
        bucketStart(Int64(date.timeIntervalSince1970.rounded(.down)))
    }
}

extension Metric {
    /// Column name stem; the tables have `<stem>Avg` and `<stem>Max`. Spelled out so a new
    /// `Metric` case fails to compile here instead of silently missing a column.
    var columnStem: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memory"
        case .energy: "energy"
        case .diskRead: "diskRead"
        case .diskWrite: "diskWrite"
        case .netIn: "netIn"
        case .netOut: "netOut"
        case .gpu: "gpu"
        case .energyImpact: "energyImpact"
        case .cpuTemperature: "cpuTemperature"
        case .gpuTemperature: "gpuTemperature"
        case .fanSpeed: "fanSpeed"
        case .thermalPressure: "thermalPressure"
        case .batteryLevel: "batteryLevel"
        case .memoryPressure: "memoryPressure"
        case .swapUsed: "swapUsed"
        case .diskFree: "diskFree"
        case .onBattery: "onBattery"
        case .powerDraw: "powerDraw"
        case .batteryTempCharging: "batteryTempCharging"
        case .batteryTempInUse: "batteryTempInUse"
        }
    }

    var averageColumn: String {
        "\(columnStem)Avg"
    }

    var maximumColumn: String {
        "\(columnStem)Max"
    }
}
