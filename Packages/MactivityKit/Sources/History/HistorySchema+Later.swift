import Foundation
import GRDB

extension HistorySchema {
    /// The migrations after v20, in order. Frozen like the rest once shipped.
    static func registerLaterMigrations(_ migrator: inout DatabaseMigrator) {
        // The battery's temperature (1.x, D-275): while charging and otherwise, on each tier.
        migrator.registerMigration("v21: battery temperature") { db in
            for tier in ["minute", "quarter", "hour"] {
                for stem in ["batteryTempCharging", "batteryTempInUse"] {
                    try db.execute(sql: "ALTER TABLE \(tier) ADD COLUMN \(stem)Avg REAL")
                    try db.execute(sql: "ALTER TABLE \(tier) ADD COLUMN \(stem)Max REAL")
                }
            }
        }
        // Chargers compared (1.x, D-274): a day of a rating in a condition, a handful of rows a day.
        // `band` is ChargeBand's raw value, -1 while plugged in and not charging; `warm` -1 unknown.
        migrator.registerMigration("v22: charger use") { db in
            try db.execute(sql: """
            CREATE TABLE charger_use (
                day INTEGER NOT NULL,
                watts INTEGER NOT NULL,
                band INTEGER NOT NULL,
                warm INTEGER NOT NULL,
                busy INTEGER NOT NULL,
                seconds REAL NOT NULL,
                gained REAL NOT NULL,
                deliveredWattSeconds REAL NOT NULL,
                deliveredSeconds REAL NOT NULL,
                peakWatts REAL,
                PRIMARY KEY (day, watts, band, warm, busy)
            ) WITHOUT ROWID;
            """)
        }
        // Test run times (D-278): test commands' runs beside the builds, with how each ended.
        migrator.registerMigration("v23: test runs") { db in
            try db.execute(sql: """
            ALTER TABLE build_run ADD COLUMN kind TEXT NOT NULL DEFAULT 'build';
            ALTER TABLE build_run ADD COLUMN outcome TEXT;
            ALTER TABLE build_run ADD COLUMN partial INTEGER NOT NULL DEFAULT 0;
            """)
        }
        // Notifications by app (D-289): which app and when, never what it said.
        migrator.registerMigration("v25: notification events") { db in
            try db.execute(sql: """
            CREATE TABLE notification_event (
                t REAL NOT NULL,
                app TEXT NOT NULL,
                PRIMARY KEY (t, app)
            ) WITHOUT ROWID;
            """)
        }
    }
}
