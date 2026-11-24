import Core
import Foundation
import GRDB

/// Alert state and the alert log (spec 6.8). Dates are REAL seconds since 1970, so they
/// round-trip to well under a microsecond (exactly for whole and binary-fraction seconds).
extension SQLiteHistoryStore {
    /// How many alerts the log keeps; older ones are dropped on insert.
    static let alertLogLimit = 500

    public func loadAlertState() throws -> AlertState {
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT appID, rule, lastFired, level FROM alert_state")
        }
        var lastFired: [AlertKey: Date] = [:]
        var levels: [AlertKey: Double] = [:]
        for row in rows {
            let ruleName: String = row["rule"]
            guard let rule = AlertRule(rawValue: ruleName) else {
                historyLog.notice("Skipping alert state for unknown rule \(ruleName, privacy: .public)")
                continue
            }
            let seconds: Double = row["lastFired"]
            let key = AlertKey(appID: row["appID"], rule: rule)
            lastFired[key] = Date(timeIntervalSince1970: seconds)
            levels[key] = row["level"]
        }
        return AlertState(lastFired: lastFired, levelAtLastAlert: levels)
    }

    /// Replaces every stored row with `state`.
    public func saveAlertState(_ state: AlertState) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM alert_state")
            let statement = try db.cachedStatement(
                sql: "INSERT INTO alert_state (appID, rule, lastFired, level) VALUES (?, ?, ?, ?)"
            )
            for (key, date) in state.lastFired {
                try statement.execute(arguments: [key.appID, key.rule.rawValue, date.timeIntervalSince1970, state.levelAtLastAlert[key]])
            }
        }
    }

    public func recordAlert(_ alert: Alert) throws {
        try database.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO alert_log
                    (id, rule, appID, appName, appBundleID, appIconKey, appKind, firedAt, title, body)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    alert.id.uuidString, alert.rule.rawValue, alert.app.id, alert.app.name, alert.app.bundleID,
                    alert.app.iconKey, alert.app.kind.rawValue, alert.firedAt.timeIntervalSince1970,
                    alert.title, alert.body,
                ]
            )
            try db.execute(
                sql: """
                DELETE FROM alert_log WHERE rowid NOT IN
                    (SELECT rowid FROM alert_log ORDER BY firedAt DESC, rowid DESC LIMIT ?)
                """,
                arguments: [Self.alertLogLimit]
            )
        }
    }

    /// Newest first. Rows with an unknown rule or a malformed ID are skipped.
    public func recentAlerts(limit: Int) throws -> [Alert] {
        guard limit > 0 else {
            return []
        }
        let rows = try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM alert_log ORDER BY firedAt DESC, rowid DESC LIMIT ?",
                arguments: [limit]
            )
        }
        return rows.compactMap { row -> Alert? in
            let idString: String = row["id"]
            let ruleName: String = row["rule"]
            let kindName: String = row["appKind"]
            guard let id = UUID(uuidString: idString), let rule = AlertRule(rawValue: ruleName) else {
                historyLog.notice("Skipping alert log row \(idString, privacy: .public) with rule \(ruleName, privacy: .public)")
                return nil
            }
            let app = AppIdentity(
                id: row["appID"],
                name: row["appName"],
                bundleID: row["appBundleID"],
                iconKey: row["appIconKey"],
                kind: AppIdentity.Kind(rawValue: kindName) ?? .other
            )
            let firedAt: Double = row["firedAt"]
            return Alert(
                id: id,
                rule: rule,
                app: app,
                firedAt: Date(timeIntervalSince1970: firedAt),
                title: row["title"],
                body: row["body"]
            )
        }
    }
}
