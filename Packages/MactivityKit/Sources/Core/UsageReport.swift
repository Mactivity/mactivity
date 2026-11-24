import Foundation

/// A report on a week or a month of the Mac's use (D-159): the figures, the busiest hour and the
/// apps behind it, the busiest apps by each measure, and what went wrong. Saved as a PDF from
/// the View menu or History's Your week card. Built from History, on the Mac, like everything else.
public struct UsageReport: Hashable, Sendable {
    public enum Period: String, CaseIterable, Hashable, Sendable {
        case week, month

        public var days: Int {
            switch self {
            case .week: 7
            case .month: 30
            }
        }
    }

    /// One hour that stood out: when, how busy, and who was busy.
    public struct Peak: Hashable, Sendable {
        public let start: Date
        public let cpuPercent: Double
        public let apps: [AppTotal]

        public init(start: Date, cpuPercent: Double, apps: [AppTotal]) {
            self.start = start
            self.cpuPercent = cpuPercent
            self.apps = apps
        }
    }

    public struct Count: Hashable, Sendable, Identifiable {
        public var id: String {
            name
        }

        public let name: String
        public let count: Int

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public let period: Period
    public let start: Date
    public let end: Date
    /// "MacBook Pro (14-inch, M5 Pro), macOS 27.0", when the app knows it.
    public let mac: String?
    public var activeSeconds: Double = 0
    public var previousActiveSeconds: Double?
    public var averageCPU: Double?
    public var peakCPU: Double?
    public var averageMemoryPressure: Double?
    public var peakSwapBytes: Double?
    public var writtenBytes: Double = 0
    public var networkBytes: Double = 0
    public var averageSleepSeconds: Double?
    public var batteryHealthPercent: Double?
    public var onBatterySeconds: Double?
    /// The whole Mac's average CPU each day, oldest first.
    public var dailyCPU: [DayValue] = []
    public var peak: Peak?
    /// Highest first, each list at most `listLength`.
    public var inFront: [AppTotal] = []
    public var byCPU: [AppTotal] = []
    public var byMemory: [AppTotal] = []
    /// Each app's share of all energy, percent.
    public var byEnergy: [AppTotal] = []
    public var alerts: [Count] = []
    public var crashes: [Count] = []

    public static let listLength = 6

    public init(period: Period, start: Date, end: Date, mac: String?) {
        self.period = period
        self.start = start
        self.end = end
        self.mac = mac
    }

    /// Change in time in use against the period before, as a fraction.
    public var activeChange: Double? {
        guard let previous = previousActiveSeconds, previous >= 3600 else {
            return nil
        }
        return (activeSeconds - previous) / previous
    }

    /// Pure: the hour whose average CPU was highest, from an hourly (or finer) series. Finer
    /// points are grouped into the hour they start in, so a one-minute spike doesn't win.
    public static func busiestHour(_ series: [SeriesPoint], calendar: Calendar = .current) -> (start: Date, average: Double)? {
        var hours: [Date: (sum: Double, count: Int)] = [:]
        for point in series {
            guard let hour = calendar.dateInterval(of: .hour, for: point.at)?.start else {
                continue
            }
            hours[hour, default: (0, 0)].sum += point.average
            hours[hour, default: (0, 0)].count += 1
        }
        return hours
            .map { (start: $0.key, average: $0.value.sum / Double(max(1, $0.value.count))) }
            .max { ($0.average, $1.start) < ($1.average, $0.start) }
    }

    /// Pure: how many of each, most first, then by name.
    public static func counts(_ names: [String]) -> [Count] {
        Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
            .map { Count(name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }
}
