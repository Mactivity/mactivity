import Foundation

/// An app's part in the Mac's warmest hours (1.7, D-255).
public struct AppHeat: Hashable, Sendable, Identifiable {
    public let app: AppIdentity
    /// Its share of the processor in the warmest buckets, 0…1.
    public let warmShare: Double
    /// Its share the rest of the time, 0…1.
    public let usualShare: Double

    public var id: AppIdentity.ID {
        app.id
    }

    public init(app: AppIdentity, warmShare: Double, usualShare: Double) {
        self.app = app
        self.warmShare = warmShare
        self.usualShare = usualShare
    }
}

/// Heat by app (D-255): which apps keep the Mac warm, from weeks of History. The Mac's warmest
/// tenth of quarter-hours by processor temperature, and each app's share of the processor then,
/// beside its share the rest of the time. Pure.
public enum HeatByApp {
    /// The warmest tenth of the buckets.
    public static let warmFraction = 0.1
    /// Fewer buckets than three days of quarter-hours isn't enough to say.
    public static let minimumBuckets = 288
    /// Under this share of the warm hours' processor, an app isn't named.
    public static let minimumShare = 0.05
    /// A quarter-hour averaging under this isn't warm, whatever the Mac's usual: on a Mac that
    /// stays cool, its "warmest tenth" can start at 39 °C (seen 2026-10-30).
    public static let warmFloor = 50.0
    /// Named only when busier warm than usual by at least this much: macOS's own processes are
    /// most of the processor all the time, and don't make a Mac warm.
    public static let minimumLift = 1.25

    /// Pure: the temperature a bucket counts as warm from, for these readings.
    public static func warmFrom(_ temperatures: [Double]) -> Double {
        let sorted = temperatures.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else {
            return .infinity
        }
        return max(warmFloor, sorted[min(sorted.count - 1, Int(Double(sorted.count) * (1 - warmFraction)))])
    }

    public struct Result: Sendable, Equatable {
        public let apps: [AppHeat]
        /// The lowest temperature counted as warm, in °C.
        public let warmFrom: Double
        /// The warmest quarter-hour's average, in °C.
        public let warmest: Double

        /// Never warm enough to say which apps warm it.
        public var staysCool: Bool {
            warmest < HeatByApp.warmFloor
        }
    }

    /// Nil without enough history or without a temperature.
    public static func rank(temperature: [SeriesPoint], apps: [AppIdentity: [SeriesPoint]]) -> Result? {
        let readings = temperature.filter { $0.average > 0 }
        guard readings.count >= minimumBuckets else {
            return nil
        }
        let warmFrom = warmFrom(readings.map(\.average))
        let warmest = readings.map(\.average).max() ?? 0
        let warm = Set(readings.filter { $0.average >= warmFrom }.map(\.at))
        var warmTotals: [AppIdentity: Double] = [:]
        var usualTotals: [AppIdentity: Double] = [:]
        for (app, points) in apps {
            for point in points {
                if warm.contains(point.at) {
                    warmTotals[app, default: 0] += point.average
                } else {
                    usualTotals[app, default: 0] += point.average
                }
            }
        }
        let warmSum = warmTotals.values.reduce(0, +)
        let usualSum = usualTotals.values.reduce(0, +)
        guard warmSum > 0 else {
            return Result(apps: [], warmFrom: warmFrom, warmest: warmest)
        }
        let ranked = warmTotals.map { app, total in
            AppHeat(app: app, warmShare: total / warmSum, usualShare: usualSum > 0 ? (usualTotals[app] ?? 0) / usualSum : 0)
        }
        .filter { $0.warmShare >= minimumShare && $0.warmShare >= $0.usualShare * minimumLift }
        .sorted { ($0.warmShare, $1.app.name) > ($1.warmShare, $0.app.name) }
        return Result(apps: Array(ranked.prefix(5)), warmFrom: warmFrom, warmest: warmest)
    }
}

/// How the battery is charged (1.7, D-255), from weeks of History: time plugged in at full,
/// charging while the Mac ran warm, and how often it ran low. Advice only: Mactivity never sets
/// charging limits.
public struct ChargingHabits: Sendable, Equatable {
    /// Hours a day, on average, plugged in at 95% or more.
    public let fullHoursPerDay: Double
    /// Of the time spent charging, the share while the Mac was in its warmest tenth.
    public let warmChargingShare: Double
    /// Times it ran down under 10%.
    public let lowRuns: Int
    public let days: Double

    public init(fullHoursPerDay: Double, warmChargingShare: Double, lowRuns: Int, days: Double) {
        self.fullHoursPerDay = fullHoursPerDay
        self.warmChargingShare = warmChargingShare
        self.lowRuns = lowRuns
        self.days = days
    }

    public enum Advice: Hashable, Sendable {
        /// Plugged in at full for hours a day: Optimized Battery Charging helps.
        case sitsAtFull(hours: Double)
        /// A good share of charging happened while warm.
        case chargesWarm(share: Double)
        /// It ran low often.
        case runsLow(times: Int)
        /// Nothing to change.
        case fine
    }

    /// Pure: what's worth saying, most telling first.
    public var advice: [Advice] {
        var advice: [Advice] = []
        if fullHoursPerDay >= 8 {
            advice.append(.sitsAtFull(hours: fullHoursPerDay))
        }
        if warmChargingShare >= 0.25 {
            advice.append(.chargesWarm(share: warmChargingShare))
        }
        if lowRuns >= 4 {
            advice.append(.runsLow(times: lowRuns))
        }
        return advice.isEmpty ? [.fine] : advice
    }

    /// Fewer than three days of quarter-hours isn't enough to say.
    public static let minimumBuckets = 288
    static let full = 95.0
    static let low = 10.0

    /// Pure: from the battery level, time on battery (1 on battery, 0 plugged in) and the
    /// processor temperature, bucket by bucket. Nil without enough history.
    public static func read(level: [SeriesPoint], onBattery: [SeriesPoint], temperature: [SeriesPoint], bucket: TimeInterval)
        -> ChargingHabits? {
        guard level.count >= minimumBuckets else {
            return nil
        }
        let battery = Dictionary(onBattery.map { ($0.at, $0.average) }, uniquingKeysWith: { first, _ in first })
        let warmFrom = HeatByApp.warmFrom(temperature.map(\.average))
        let heat = Dictionary(temperature.map { ($0.at, $0.average) }, uniquingKeysWith: { first, _ in first })
        var fullBuckets = 0
        var charging = 0
        var warmCharging = 0
        var lowRuns = 0
        var wasLow = false
        var previous: SeriesPoint?
        for point in level {
            let plugged = (battery[point.at] ?? 1) < 0.1
            if plugged, point.average >= full {
                fullBuckets += 1
            }
            if plugged, let previous, point.average - previous.average >= 0.5, point.average < full {
                charging += 1
                if (heat[point.at] ?? 0) >= warmFrom {
                    warmCharging += 1
                }
            }
            let isLow = point.average > 0 && point.average < low
            if isLow, !wasLow {
                lowRuns += 1
            }
            wasLow = isLow
            previous = point
        }
        let span = (level.last?.at.timeIntervalSince(level.first?.at ?? .distantPast) ?? 0) + bucket
        let days = max(1, span / 86400)
        return ChargingHabits(
            fullHoursPerDay: Double(fullBuckets) * bucket / 3600 / days,
            warmChargingShare: charging > 0 ? Double(warmCharging) / Double(charging) : 0,
            lowRuns: lowRuns, days: days
        )
    }
}
