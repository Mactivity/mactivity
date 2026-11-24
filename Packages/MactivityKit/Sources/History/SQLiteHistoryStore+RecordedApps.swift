import Core
import Foundation
import GRDB

/// The apps history has seen, for Old Versions and Leftovers (D-282). The `app` table stays when
/// an app's rows age out, so this reaches back as far as Mactivity has been running.
extension SQLiteHistoryStore: RecordedAppsStore {
    public func recordedApps() throws -> [RecordedApp] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT name, bundleID, kind FROM app WHERE bundleID IS NOT NULL AND bundleID != ''").map { row in
                let kind: String = row["kind"]
                return RecordedApp(name: row["name"], bundleID: row["bundleID"], isApp: kind == AppIdentity.Kind.app.rawValue)
            }
        }
    }
}
