import Core
import Foundation
import GRDB

/// Accessory batteries over time (D-094).
extension SQLiteHistoryStore: DeviceBatteryStore {
    public func recordDevices(_ devices: [PeripheralBattery], at date: Date) throws {
        let t = Int64(date.timeIntervalSince1970.rounded(.down))
        let due = devices.filter { Self.shouldKeep(percent: $0.percent, at: t, last: lastDeviceReading[$0.id]) }
        guard !due.isEmpty else {
            return
        }
        try database.write { db in
            let statement = try db.cachedStatement(sql: """
            INSERT OR REPLACE INTO device_battery (device, t, name, kind, percent) VALUES (?, ?, ?, ?, ?)
            """)
            for device in due {
                try statement.execute(arguments: [device.id, t, device.name, device.kind.rawValue, device.percent])
            }
        }
        for device in due {
            lastDeviceReading[device.id] = (device.percent, t)
        }
    }

    /// Pure: a reading is kept when it's the first this launch, when the level moved a point or
    /// more, or when an hour has passed, so a chart has a point at least hourly while connected.
    static func shouldKeep(percent: Double, at t: Int64, last: (percent: Double, at: Int64)?) -> Bool {
        guard let last else {
            return true
        }
        return abs(percent - last.percent) >= 1 || t - last.at >= 3600
    }

    public func deviceHistory(days: Int) throws -> [DeviceBatteryHistory] {
        let start = Int64(now().timeIntervalSince1970) - Int64(max(1, days)) * 86400
        let rows = try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT device, t, name, kind, percent FROM device_battery WHERE t >= ? ORDER BY device, t",
                arguments: [start]
            )
        }
        // Rows come grouped by device, oldest first. The latest name wins: renaming AirPods
        // renames their history.
        var histories: [DeviceBatteryHistory] = []
        for row in rows {
            let id: String = row["device"]
            let point = DeviceBatteryPoint(at: Date(timeIntervalSince1970: TimeInterval(row["t"] as Int64)), percent: row["percent"])
            let kind = PeripheralBattery.Kind(rawValue: row["kind"]) ?? .other
            let points = histories.last?.id == id ? (histories.removeLast().points + [point]) : [point]
            histories.append(DeviceBatteryHistory(id: id, name: row["name"], kind: kind, points: points))
        }
        return histories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
