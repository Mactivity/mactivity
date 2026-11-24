import Foundation

// Plain-language readings of history (D-095). Pure, so they're tested with made-up series.

public enum DiskForecast {
    /// Shrinking slower than this a day reads as steady, not "full in 40 years".
    static let minimumDailyDrop = 100e6
    static let minimumDays = 7

    /// Days until the startup disk is full at the trend of `days` (daily free space, oldest
    /// first): a least-squares line through them. Nil with under a week of days, or when free
    /// space isn't shrinking by at least 100 MB a day.
    public static func daysUntilFull(_ days: [DayValue]) -> Double? {
        guard days.count >= minimumDays, let first = days.first, let last = days.last else {
            return nil
        }
        let xs = days.map { $0.day.timeIntervalSince(first.day) / 86400 }
        let ys = days.map(\.average)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let covariance = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let variance = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard variance > 0 else {
            return nil
        }
        let perDay = covariance / variance
        guard perDay <= -minimumDailyDrop else {
            return nil
        }
        return max(0, last.average) / -perDay
    }
}

public enum ChargeSessions {
    /// A rise this big is a charge, not noise or a reading's rounding.
    static let minimumRise = 10.0
    /// Dips smaller than this inside a rise don't end it (the level wobbles while charging).
    static let wobble = 1.0

    /// How many times the battery charged in `points` (battery level, oldest first).
    public static func count(_ points: [SeriesPoint]) -> Int {
        var count = 0
        var low: Double?
        var high: Double?
        for point in points.map(\.average) {
            guard let top = high, let bottom = low else {
                low = point
                high = point
                continue
            }
            if point >= top {
                high = point
            } else if point < top - wobble {
                // The rise, if any, ended at `top`.
                if top - bottom >= minimumRise {
                    count += 1
                }
                low = point
                high = point
            }
        }
        if let top = high, let bottom = low, top - bottom >= minimumRise {
            count += 1
        }
        return count
    }
}

public enum BatteryHealthForecast {
    static let minimumSpanDays = 30.0

    /// Months until maximum capacity reaches `target` percent at the trend of `days` (daily
    /// readings, any order): a least-squares line. 0 once it's there; nil with under 30 days of
    /// readings or when capacity isn't falling.
    public static func monthsUntil(_ target: Double, days: [BatteryDay]) -> Double? {
        let readings = days.compactMap { day in day.maxCapacityPercent.map { (day.day, $0) } }.sorted { $0.0 < $1.0 }
        guard let first = readings.first, let last = readings.last else {
            return nil
        }
        if last.1 <= target {
            return 0
        }
        guard last.0.timeIntervalSince(first.0) / 86400 >= minimumSpanDays else {
            return nil
        }
        let xs = readings.map { $0.0.timeIntervalSince(first.0) / 86400 }
        let ys = readings.map(\.1)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let covariance = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let variance = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard variance > 0 else {
            return nil
        }
        let perDay = covariance / variance
        guard perDay < 0 else {
            return nil
        }
        return (last.1 - target) / -perDay / 30.44
    }
}

/// How much of the battery was used and put back over a stretch of levels (D-105): 80 → 40 →
/// 100 → 50 is 90 used and 60 charged. A level has to move a whole point from the last counted
/// one before it counts, so the fractions minute averages wobble by don't add up to anything.
public enum BatteryFlow {
    public static func totals(_ points: [SeriesPoint]) -> (used: Double, charged: Double) {
        var used = 0.0
        var charged = 0.0
        var anchor: Double?
        for level in points.map(\.average) {
            guard let last = anchor else {
                anchor = level
                continue
            }
            if last - level >= 1 {
                used += last - level
                anchor = level
            } else if level - last >= 1 {
                charged += level - last
                anchor = level
            }
        }
        return (used, charged)
    }
}
