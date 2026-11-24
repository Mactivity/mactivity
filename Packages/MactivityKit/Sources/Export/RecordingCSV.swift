import Core
import Foundation

/// A recording's rows (D-151): every snapshot while recording, one row for the whole Mac ("All
/// apps") and one per app that did something. Long format, one figure per column, so a
/// spreadsheet's pivot table or pandas reads it as is.
public enum RecordingCSV {
    /// Apps per snapshot beyond those with disk or network activity: the busiest by CPU.
    public static let appsByCPU = 20

    static let metrics = Metric.allCases

    public static var header: String {
        (["Time", "App", "Bundle ID"] + metrics.map(columnName)).map(CSV.field).joined(separator: ",")
    }

    /// History's names, except that here "on battery" is one reading, not a share of an hour.
    static func columnName(_ metric: Metric) -> String {
        metric == .onBattery ? "On battery (1 or 0)" : metric.csvName
    }

    /// The snapshot's rows: the Mac first, then apps, busiest first.
    public static func rows(_ snapshot: Snapshot, dates: ISO8601DateFormatter) -> [String] {
        let time = dates.string(from: snapshot.at)
        var lines = [line(time, "All apps", "", metrics.map { snapshot.systemValue(for: $0) })]
        let busiest = Set(snapshot.topApps(by: .cpu, limit: appsByCPU).map(\.app.id))
        let apps = AppAggregate.ranked(snapshot.apps) { $0.cpuPercent }.filter { app in
            busiest.contains(app.app.id) || app.diskReadBPS + app.diskWriteBPS > 0 || (app.netInBPS ?? 0) + (app.netOutBPS ?? 0) > 0
        }
        for app in apps {
            lines.append(line(time, app.app.name, app.app.bundleID ?? "", metrics.map { app.value(for: $0) }))
        }
        return lines
    }

    private static func line(_ time: String, _ app: String, _ bundleID: String, _ values: [Double?]) -> String {
        ([time, app, bundleID].map(CSV.field) + values.map(CSV.number)).joined(separator: ",")
    }

    /// "Mactivity Recording 2026-10-11 at 14.32.csv".
    public static func suggestedName(at date: Date) -> String {
        let day = Formatters.localDay(date)
        // 24-hour whatever the Mac's clock, so 2:32 PM isn't "02.32" and the names sort by time (D-221).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "HH.mm"
        let time = formatter.string(from: date)
        return "Mactivity Recording \(day) at \(time).csv"
    }
}
