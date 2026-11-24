import Core
import Foundation
import GRDB

/// Settings → History → Export History… (D-093).
extension SQLiteHistoryStore: HistoryExporting {
    /// Every hourly row, oldest first, system-wide ("All apps") and per app. Streamed through a
    /// cursor into the file, so a year never sits in memory. Nonisolated: it reads on the caller's
    /// thread, not the sampling one, and the read holds off the next minute's write until it ends.
    public nonisolated func exportCSV(to url: URL) throws -> Int {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let metrics = Metric.allCases
        let dates = ISO8601DateFormatter()
        dates.timeZone = .current
        dates.formatOptions = [.withInternetDateTime]

        var buffer = Self.csvHeader(metrics) + "\n"
        var count = 0
        try database.read { db in
            let columns = metrics.flatMap { [$0.averageColumn, $0.maximumColumn] }.map { "hour.\($0)" }
            let cursor = try Row.fetchCursor(db, sql: """
            SELECT hour.t, hour.app, app.name, app.bundleID, \(columns.joined(separator: ", "))
            FROM hour LEFT JOIN app ON app.id = hour.app
            ORDER BY hour.t, hour.app = ? DESC, app.name
            """, arguments: [HistorySchema.systemAppID])
            while let row = try cursor.next() {
                let t: Int64 = row[0]
                let id: String = row[1]
                let isSystem = id == HistorySchema.systemAppID
                var fields = [
                    dates.string(from: Date(timeIntervalSince1970: TimeInterval(t))),
                    isSystem ? "All apps" : ((row[2] as String?) ?? id),
                    isSystem ? "" : ((row[3] as String?) ?? ""),
                ]
                for index in 0 ..< columns.count {
                    fields.append(Self.csvNumber(row[4 + index]))
                }
                buffer += fields.map(Self.csvField).joined(separator: ",") + "\n"
                count += 1
                if buffer.utf8.count > 1 << 16 {
                    try handle.write(contentsOf: Data(buffer.utf8))
                    buffer = ""
                }
            }
        }
        try handle.write(contentsOf: Data(buffer.utf8))
        return count
    }

    /// English column names with units: the file is data for a spreadsheet or a script.
    static func csvHeader(_ metrics: [Metric]) -> String {
        (["Hour starting", "App", "Bundle ID"] + metrics.flatMap { ["\($0.csvName) average", "\($0.csvName) peak"] })
            .map(csvField)
            .joined(separator: ",")
    }

    /// Empty for no figure; whole numbers without a fraction; the rest to three decimals.
    static func csvNumber(_ value: Double?) -> String {
        CSV.number(value)
    }

    /// Quoted when it holds a comma, a quote or a line break (RFC 4180).
    static func csvField(_ text: String) -> String {
        CSV.field(text)
    }
}
