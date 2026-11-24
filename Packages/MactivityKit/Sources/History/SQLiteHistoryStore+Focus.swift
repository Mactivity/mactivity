import Core
import Foundation
import GRDB

/// Time in front (D-098).
extension SQLiteHistoryStore: FocusStore {
    public func recordFocus(_ app: AppIdentity, from start: Date, to end: Date) throws {
        guard end > start else {
            return
        }
        try database.write { db in
            try db.execute(sql: """
            INSERT INTO app (id, name, bundleID, iconKey, kind) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (id) DO NOTHING
            """, arguments: [app.id, app.name, app.bundleID, app.iconKey, app.kind.rawValue])
            try db.execute(
                sql: "INSERT OR REPLACE INTO focus (start, end, app) VALUES (?, ?, ?)",
                arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970, app.id]
            )
        }
    }

    /// Each stretch clipped to the span, so a morning that began yesterday counts only its part.
    public func focusTotals(from: Date, to: Date, limit: Int) throws -> [AppTotal] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
            SELECT app.id, app.name, app.bundleID, app.iconKey, app.kind,
                   SUM(MIN(focus.end, ?) - MAX(focus.start, ?)) AS value
            FROM focus JOIN app ON app.id = focus.app
            WHERE focus.end > ? AND focus.start < ?
            GROUP BY focus.app
            ORDER BY value DESC, app.id
            LIMIT ?
            """, arguments: [
                to.timeIntervalSince1970, from.timeIntervalSince1970,
                from.timeIntervalSince1970, to.timeIntervalSince1970, max(0, limit),
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

    public func focusStretches(from: Date, to: Date) throws -> [FocusStretch] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
            SELECT app.id, app.name, app.bundleID, app.iconKey, app.kind, focus.start, focus.end
            FROM focus JOIN app ON app.id = focus.app
            WHERE focus.start >= ? AND focus.start < ?
            ORDER BY focus.start
            """, arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]).map { row in
                let kind: String = row["kind"]
                return FocusStretch(
                    app: AppIdentity(
                        id: row["id"], name: row["name"], bundleID: row["bundleID"], iconKey: row["iconKey"],
                        kind: AppIdentity.Kind(rawValue: kind) ?? .other
                    ),
                    start: Date(timeIntervalSince1970: row["start"]),
                    end: Date(timeIntervalSince1970: row["end"])
                )
            }
        }
    }

    public func firstFocus() throws -> Date? {
        try database.read { db in
            try Double.fetchOne(db, sql: "SELECT MIN(start) FROM focus").map(Date.init(timeIntervalSince1970:))
        }
    }

    public func lastFocus() throws -> [AppIdentity.ID: Date] {
        try database.read { db in
            var last: [AppIdentity.ID: Date] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT app, MAX(end) AS last FROM focus GROUP BY app") {
                last[row["app"]] = Date(timeIntervalSince1970: row["last"])
            }
            return last
        }
    }

    public func activeSeconds(from: Date, to: Date) throws -> Double {
        try database.read { db in
            try Double.fetchOne(db, sql: """
            SELECT TOTAL(MIN(end, ?) - MAX(start, ?)) FROM focus WHERE end > ? AND start < ?
            """, arguments: [
                to.timeIntervalSince1970, from.timeIntervalSince1970, from.timeIntervalSince1970, to.timeIntervalSince1970,
            ]) ?? 0
        }
    }
}
