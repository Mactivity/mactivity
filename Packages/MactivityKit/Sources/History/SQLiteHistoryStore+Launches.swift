import Core
import Foundation
import GRDB

/// App launch times (D-215): a row per launch.
extension SQLiteHistoryStore: AppLaunchStore {
    public func recordLaunch(_ launch: AppLaunch) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO app_launch (t, app, name, seconds) VALUES (?, ?, ?, ?)",
                arguments: [launch.at.timeIntervalSince1970, launch.appID, launch.name, launch.seconds]
            )
        }
    }

    public func launches(from: Date, to: Date) throws -> [AppLaunch] {
        try database.read { db in
            try Row.fetchAll(
                db, sql: "SELECT t, app, name, seconds FROM app_launch WHERE t >= ? AND t < ? ORDER BY t",
                arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]
            ).map { row in
                AppLaunch(at: Date(timeIntervalSince1970: row["t"]), appID: row["app"], name: row["name"], seconds: row["seconds"])
            }
        }
    }
}
