import Foundation

/// One calendar month of battery health (D-205): its last maximum-capacity reading, and the
/// charge cycles added during it.
public struct BatteryMonth: Hashable, Sendable, Identifiable {
    /// The month's first day, local midnight.
    public let month: Date
    public let capacityPercent: Double?
    /// Cycles added in the month: its last count less the month before's, or less its own first
    /// count for the first month recorded. Nil without two counts to compare.
    public let cycles: Int?

    public init(month: Date, capacityPercent: Double?, cycles: Int?) {
        self.month = month
        self.capacityPercent = capacityPercent
        self.cycles = cycles
    }

    public var id: Date {
        month
    }
}

/// Battery health month by month, and a forecast that doesn't wait for capacity to move (D-205).
extension BatteryHealthForecast {
    /// Cycles reaching this many before wear per cycle says anything: a new battery's first
    /// cycles barely show in its capacity.
    static let minimumCycles = 50
    /// Days of cycle counts before a monthly rate is worked out.
    static let minimumCycleDays = 14.0

    /// Each month with a reading, oldest first.
    public static func months(_ days: [BatteryDay], calendar: Calendar = .current) -> [BatteryMonth] {
        let sorted = days.sorted { $0.day < $1.day }
        var order: [Date] = []
        var byMonth: [Date: [BatteryDay]] = [:]
        for day in sorted {
            guard let month = calendar.dateInterval(of: .month, for: day.day)?.start else {
                continue
            }
            if byMonth[month] == nil {
                order.append(month)
            }
            byMonth[month, default: []].append(day)
        }
        var previousCycles: Int?
        return order.compactMap { month in
            let readings = byMonth[month] ?? []
            let capacity = readings.last { $0.maxCapacityPercent != nil }?.maxCapacityPercent
            let counts = readings.compactMap(\.cycleCount)
            let start = previousCycles ?? counts.first
            let cycles = counts.last.flatMap { last in start.map { max(0, last - $0) } }
            previousCycles = counts.last ?? previousCycles
            guard capacity != nil || cycles != nil else {
                return nil
            }
            return BatteryMonth(month: month, capacityPercent: capacity, cycles: cycles)
        }
    }

    /// Charge cycles a month at the rate of `days`; nil with under two weeks of counts.
    public static func cyclesPerMonth(_ days: [BatteryDay]) -> Double? {
        let counts = days.compactMap { day in day.cycleCount.map { (day.day, $0) } }.sorted { $0.0 < $1.0 }
        guard let first = counts.first, let last = counts.last else {
            return nil
        }
        let span = last.0.timeIntervalSince(first.0) / 86400
        guard span >= minimumCycleDays else {
            return nil
        }
        return Double(last.1 - first.1) / span * 30.44
    }

    /// Months until `target` from wear per cycle so far (capacity lost over cycles used) and the
    /// cycles used a month: an answer before capacity has visibly moved, which macOS reports in
    /// whole percents and so can sit still for weeks. Nil under `minimumCycles` or with no wear.
    public static func monthsUntilByCycles(_ target: Double, days: [BatteryDay]) -> Double? {
        guard let capacity = days.last(where: { $0.maxCapacityPercent != nil })?.maxCapacityPercent,
              let cycles = days.last(where: { $0.cycleCount != nil })?.cycleCount else {
            return nil
        }
        if capacity <= target {
            return 0
        }
        guard cycles >= minimumCycles, let perMonth = cyclesPerMonth(days), perMonth > 0 else {
            return nil
        }
        let wearPerCycle = (100 - capacity) / Double(cycles)
        guard wearPerCycle > 0 else {
            return nil
        }
        return (capacity - target) / wearPerCycle / perMonth
    }

    /// The capacity trend when there is one, else wear per cycle.
    public static func estimate(_ target: Double, days: [BatteryDay]) -> Double? {
        monthsUntil(target, days: days) ?? monthsUntilByCycles(target, days: days)
    }
}
