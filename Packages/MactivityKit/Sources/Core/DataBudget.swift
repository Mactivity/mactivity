import Foundation

/// A monthly data budget (1.5, D-235): an allowance and the day it resets, for a capped plan or
/// a hotspot. Counted from the whole Mac's download and upload, as History records them.
public struct DataBudget: Sendable, Hashable, Codable {
    /// Bytes a period.
    public var allowance: Double
    /// The day of the month it starts again, 1–31; a shorter month resets on its last day.
    public var resetDay: Int

    public init(allowance: Double, resetDay: Int) {
        self.allowance = allowance
        self.resetDay = min(31, max(1, resetDay))
    }

    /// The period `now` is in: local midnight on the reset day, to the next one.
    public func period(containing now: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval {
        func reset(inMonthOf date: Date) -> Date {
            let month = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
            let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 28
            return calendar.date(byAdding: .day, value: min(resetDay, days) - 1, to: month) ?? month
        }
        let thisMonth = reset(inMonthOf: now)
        let start = thisMonth <= now ? thisMonth : reset(inMonthOf: calendar.date(byAdding: .month, value: -1, to: now) ?? now)
        let end = reset(inMonthOf: calendar.date(byAdding: .month, value: 1, to: start) ?? now)
        return DateInterval(start: start, end: max(end, start))
    }
}

/// Where the budget stands (D-235).
public struct DataBudgetStatus: Sendable, Hashable {
    public let budget: DataBudget
    public let period: DateInterval
    public let used: Double
    public let now: Date

    public init(budget: DataBudget, period: DateInterval, used: Double, now: Date) {
        self.budget = budget
        self.period = period
        self.used = used
        self.now = now
    }

    public var fraction: Double {
        budget.allowance > 0 ? used / budget.allowance : 0
    }

    /// At this pace, the period's total; nil in its first day, too soon to say.
    public var projected: Double? {
        let elapsed = now.timeIntervalSince(period.start)
        guard elapsed >= 86400, period.duration > 0 else {
            return nil
        }
        return used / elapsed * period.duration
    }

    /// The alert's key for this period: once at the warning, once at the allowance.
    public var periodKey: String {
        "budget:\(Int(period.start.timeIntervalSince1970))"
    }
}
