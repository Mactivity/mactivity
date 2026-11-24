@testable import Core
import Foundation
import Testing

@Suite("Insights (D-095)")
struct InsightTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func days(_ values: [Double]) -> [DayValue] {
        values.enumerated().map { DayValue(day: start + Double($0.offset) * 86400, average: $0.element, maximum: $0.element) }
    }

    @Test("Losing 2 GB a day with 20 GB left: full in about 10 days")
    func forecast() throws {
        let free = (0 ..< 14).map { 46e9 - Double($0) * 2e9 }
        let left = try #require(DiskForecast.daysUntilFull(days(free)))
        #expect(abs(left - 10) < 0.01)
    }

    @Test("Steady, growing, or under a week of days: no forecast")
    func noForecast() {
        #expect(DiskForecast.daysUntilFull(days(Array(repeating: 50e9, count: 14))) == nil)
        #expect(DiskForecast.daysUntilFull(days((0 ..< 14).map { 40e9 + Double($0) * 1e9 })) == nil)
        #expect(DiskForecast.daysUntilFull(days([50e9, 48e9, 46e9])) == nil)
        #expect(DiskForecast.daysUntilFull(days((0 ..< 14).map { 50e9 - Double($0) * 50e6 })) == nil)
    }

    private func series(_ levels: [Double]) -> [SeriesPoint] {
        levels.enumerated().map { SeriesPoint(at: start + Double($0.offset) * 900, average: $0.element, maximum: $0.element) }
    }

    @Test("Charges are rises of 10 points or more; wobbles don't split one")
    func charges() {
        #expect(ChargeSessions.count(series([80, 60, 40, 60, 80, 100, 90, 70, 75, 90])) == 2)
        #expect(ChargeSessions.count(series([40, 60, 59.5, 80, 100])) == 1)
        #expect(ChargeSessions.count(series([90, 85, 88, 80, 84])) == 0)
        #expect(ChargeSessions.count(series([])) == 0)
    }
}

@Suite("Battery health forecast (D-100)")
struct BatteryHealthForecastTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func days(_ capacities: [Double], every step: Double = 1) -> [BatteryDay] {
        capacities.enumerated().map {
            BatteryDay(day: start + Double($0.offset) * step * 86400, maxCapacityPercent: $0.element, cycleCount: nil, minutesOnBattery: 0)
        }
    }

    @Test("Losing a point a month from 90: about 10 months to 80")
    func forecast() throws {
        // 1 point per 30.44 days, readings every 10 days for 120 days.
        let readings = (0 ... 12).map { 94 - Double($0) * 10 / 30.44 }
        let months = try #require(BatteryHealthForecast.monthsUntil(80, days: days(readings, every: 10)))
        let expected = try (#require(readings.last) - 80)
        #expect(abs(months - expected) < 0.2)
    }

    @Test("Under 30 days, steady, or already at 80")
    func edges() {
        #expect(BatteryHealthForecast.monthsUntil(80, days: days([95, 94.5, 94], every: 5)) == nil)
        #expect(BatteryHealthForecast.monthsUntil(80, days: days(Array(repeating: 92, count: 10), every: 5)) == nil)
        #expect(BatteryHealthForecast.monthsUntil(80, days: days([81, 79])) == 0)
    }
}

@Suite("Battery used and charged (D-105)")
struct BatteryFlowTests {
    private func levels(_ values: [Double]) -> [SeriesPoint] {
        values.enumerated().map { SeriesPoint(
            at: Date(timeIntervalSince1970: Double($0.offset) * 60),
            average: $0.element,
            maximum: $0.element
        ) }
    }

    @Test("80 → 40 → 100 → 50 and charging again: 90 used, 60 charged, plus the charge under way")
    func realDay() {
        let day = Array(stride(from: 80.0, through: 40, by: -2)) + Array(stride(from: 42.0, through: 100, by: 2))
            + Array(stride(from: 98.0, through: 50, by: -2)) + [52, 55]
        let flow = BatteryFlow.totals(levels(day))
        #expect(flow.used == 90)
        #expect(flow.charged == 65)
    }

    @Test("Wobbles under a point add up to nothing")
    func wobble() {
        let flow = BatteryFlow.totals(levels([80, 79.6, 80.2, 79.7, 80.1, 79.8]))
        #expect(flow.used == 0)
        #expect(flow.charged == 0)
    }
}

@Suite("Battery health month by month (D-205)")
struct BatteryMonthsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private func day(_ month: Int, _ day: Int, capacity: Double?, cycles: Int?) -> BatteryDay {
        let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day)) ?? Date()
        return BatteryDay(day: date, maxCapacityPercent: capacity, cycleCount: cycles, minutesOnBattery: 0)
    }

    @Test("Each month's last capacity and the cycles added in it")
    func months() {
        let days = [
            day(8, 20, capacity: 93, cycles: 300), day(8, 31, capacity: 92, cycles: 310),
            day(9, 15, capacity: 92, cycles: 322), day(9, 30, capacity: 91, cycles: 335),
            day(10, 14, capacity: nil, cycles: 345),
        ]
        let months = BatteryHealthForecast.months(days, calendar: calendar)
        #expect(months.map(\.capacityPercent) == [92, 91, nil])
        #expect(months.map(\.cycles) == [10, 25, 10])
    }

    @Test("Wear per cycle forecasts before capacity moves; it needs 50 cycles and two weeks")
    func byCycles() throws {
        // 8 points lost over 400 cycles: 0.02 a cycle. 30 cycles in 30 days.
        let days = [day(9, 1, capacity: 92, cycles: 400), day(10, 1, capacity: 92, cycles: 430)]
        let months = try #require(BatteryHealthForecast.monthsUntilByCycles(80, days: days))
        // 12 points at 0.0186 a cycle (8 over 430) is 645 cycles, at 30.44 a month.
        #expect(abs(months - 12 / (8.0 / 430) / (30.0 / 30 * 30.44)) < 0.5)
        #expect(BatteryHealthForecast.monthsUntil(80, days: days) == nil, "capacity hasn't moved")
        #expect(BatteryHealthForecast.estimate(80, days: days) == months)
        #expect(BatteryHealthForecast.monthsUntilByCycles(
            80,
            days: [day(9, 1, capacity: 99, cycles: 20), day(10, 1, capacity: 99, cycles: 40)]
        ) == nil)
        #expect(BatteryHealthForecast.monthsUntilByCycles(
            80,
            days: [day(9, 1, capacity: 92, cycles: 400), day(9, 5, capacity: 92, cycles: 404)]
        ) == nil)
    }
}
