import Core
import Foundation
import Testing

/// A monthly data budget (D-235).
struct DataBudgetTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver") ?? .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? Date()
    }

    @Test("The period runs from the reset day's local midnight to the next")
    func period() {
        let budget = DataBudget(allowance: 100e9, resetDay: 15)
        let mid = budget.period(containing: date(2026, 10, 20), calendar: calendar)
        #expect(mid.start == date(2026, 10, 15, 0))
        #expect(mid.end == date(2026, 11, 15, 0))
        let before = budget.period(containing: date(2026, 10, 10), calendar: calendar)
        #expect(before.start == date(2026, 9, 15, 0))
    }

    @Test("A reset on the 31st falls on a short month's last day")
    func shortMonth() {
        let budget = DataBudget(allowance: 100e9, resetDay: 31)
        let february = budget.period(containing: date(2027, 3, 5), calendar: calendar)
        #expect(february.start == date(2027, 2, 28, 0))
        #expect(february.end == date(2027, 3, 31, 0))
    }

    @Test("Used, the fraction, and the pace after a day")
    func status() {
        let budget = DataBudget(allowance: 100e9, resetDay: 1)
        let period = budget.period(containing: date(2026, 11, 11, 0), calendar: calendar)
        let status = DataBudgetStatus(budget: budget, period: period, used: 40e9, now: date(2026, 11, 11, 0))
        #expect(abs(status.fraction - 0.4) < 0.0001)
        #expect(abs((status.projected ?? 0) - 120e9) < 1e9)
        #expect(DataBudgetStatus(budget: budget, period: period, used: 1e9, now: period.start + 3600).projected == nil)
    }
}
