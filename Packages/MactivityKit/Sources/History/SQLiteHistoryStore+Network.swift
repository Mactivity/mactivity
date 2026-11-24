import Core
import Foundation
import GRDB

/// Network changes and Wi-Fi over time (D-233, D-234).
extension SQLiteHistoryStore: NetworkHistoryStore {
    public func recordNetworkChange(_ change: NetworkChange) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO network_change (t, kind, interface) VALUES (?, ?, ?)",
                arguments: [change.at.timeIntervalSince1970, change.kind.rawValue, change.interface]
            )
        }
    }

    public func networkChanges(from: Date, to: Date) throws -> [NetworkChange] {
        try database.read { db in
            // The one before the span too: what it began on.
            let rows = try Row.fetchAll(db, sql: """
            SELECT t, kind, interface FROM network_change WHERE t < ? AND t >= (
                SELECT COALESCE(MAX(t), 0) FROM network_change WHERE t < ?
            ) ORDER BY t
            """, arguments: [to.timeIntervalSince1970, from.timeIntervalSince1970])
            return rows.map { row in
                NetworkChange(
                    at: Date(timeIntervalSince1970: row["t"]), kind: NetworkKind(rawValue: row["kind"]) ?? .other,
                    interface: row["interface"]
                )
            }
        }
    }

    /// Retention: changes as long as the hour rows; Wi-Fi's minute rows 30 days, about 43,000
    /// rows and under 2 MB (D-234). Also the desk's samples and the privacy indicators' changes.
    static func pruneNetwork(_ db: Database, now seconds: Int64, keep: Int64) throws {
        try db.execute(sql: "DELETE FROM network_change WHERE t < ?", arguments: [Double(seconds - keep)])
        try db.execute(sql: "DELETE FROM wifi_minute WHERE t < ?", arguments: [seconds - Int64(HistorySchema.wifiRetentionDays) * 86400])
        try db.execute(sql: "DELETE FROM desk_sample WHERE t < ?", arguments: [seconds - keep])
        // Camera and microphone history, as long as the hour rows (D-259).
        try db.execute(sql: "DELETE FROM sensor_change WHERE t < ?", arguments: [Double(seconds - keep)])
        // Notifications by app, the same (D-289).
        try db.execute(sql: "DELETE FROM notification_event WHERE t < ?", arguments: [Double(seconds - keep)])
    }

    public func recordWiFi(_ reading: WiFiReading) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO wifi_minute (t, rssi, noise, rate, channel) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    Int64(reading.at.timeIntervalSince1970 / 60) * 60, reading.rssi, reading.noise, reading.transmitRate, reading.channel,
                ]
            )
        }
    }

    public func wifiReadings(from: Date, to: Date) throws -> [WiFiReading] {
        try database.read { db in
            try Row.fetchAll(
                db, sql: "SELECT t, rssi, noise, rate, channel FROM wifi_minute WHERE t >= ? AND t < ? ORDER BY t",
                arguments: [Int64(from.timeIntervalSince1970), Int64(to.timeIntervalSince1970)]
            ).map { row in
                WiFiReading(
                    at: Date(timeIntervalSince1970: TimeInterval(row["t"] as Int64)), rssi: row["rssi"], noise: row["noise"],
                    transmitRate: row["rate"], channel: row["channel"]
                )
            }
        }
    }
}

/// The desk every 10 minutes (D-237): a small row each, a year of them about 52,000.
extension SQLiteHistoryStore: DeskHistoryStore {
    public func recordDesk(_ sample: DeskSample) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO desk_sample (t, displays, width, height, lid) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    Int64(sample.at.timeIntervalSince1970), sample.externalDisplays, sample.largestWidth, sample.largestHeight,
                    sample.lidClosed.map { $0 ? 1 : 0 },
                ]
            )
        }
    }

    public func deskSamples(from: Date, to: Date) throws -> [DeskSample] {
        try database.read { db in
            try Row.fetchAll(
                db, sql: "SELECT t, displays, width, height, lid FROM desk_sample WHERE t >= ? AND t < ? ORDER BY t",
                arguments: [Int64(from.timeIntervalSince1970), Int64(to.timeIntervalSince1970)]
            ).map { row in
                DeskSample(
                    at: Date(timeIntervalSince1970: TimeInterval(row["t"] as Int64)), externalDisplays: row["displays"],
                    largestWidth: row["width"], largestHeight: row["height"], lidClosed: (row["lid"] as Int64?).map { $0 != 0 }
                )
            }
        }
    }
}
