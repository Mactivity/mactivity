import Core
import Foundation
import Testing

@Suite("Busiest hours (D-272)")
struct BusiestHoursTests {
    private func calendar(_ zone: String = "America/New_York", firstWeekday: Int = 1) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    @Test("A day with no samples doesn't lower its weekday's hour: only what was recorded counts")
    func missingDaysAreNotIdle() throws {
        let calendar = try calendar()
        // Three Tuesdays, 3 PM: the middle one the Mac was off, so there's no row for it at all.
        let samples = try [
            HourSample(at: date(calendar, 2026, 10, 6, 15), cpu: 40, coveredMinutes: 60),
            HourSample(at: date(calendar, 2026, 10, 20, 15), cpu: 20, coveredMinutes: 60),
        ]
        let cell = try #require(BusiestHours.read(samples, calendar: calendar).cells.first)
        #expect(cell.weekday == 3)
        #expect(cell.hour == 15)
        #expect(cell.average == 30)
        #expect(cell.days == 2)
        // Asleep every Tuesday at 4 PM: no cell, rather than a cell at 0%.
        #expect(BusiestHours.read(samples, calendar: calendar).cells.count == 1)
    }

    @Test("An hour awake for ten minutes counts as ten minutes")
    func weightedByCoverage() throws {
        let calendar = try calendar()
        let samples = try [
            HourSample(at: date(calendar, 2026, 10, 6, 15), cpu: 90, coveredMinutes: 10),
            HourSample(at: date(calendar, 2026, 10, 13, 15), cpu: 10, coveredMinutes: 50),
        ]
        let cell = try #require(BusiestHours.read(samples, calendar: calendar).cells.first)
        #expect(abs(cell.average - (90 * 10 + 10 * 50) / 60.0) < 1e-9)
        #expect(cell.minutes == 60)
    }

    @Test("Rows land on the Mac's own clock, and a row with nothing covered is left out")
    func localClock() throws {
        let tokyo = try calendar("Asia/Tokyo")
        // 15:00 UTC on a Tuesday is midnight Wednesday in Tokyo.
        let at = Date(timeIntervalSince1970: 1_791_385_200)
        let cells = BusiestHours.read([
            HourSample(at: at, cpu: 10, coveredMinutes: 60),
            HourSample(at: at + 3600, cpu: 50, coveredMinutes: 0),
        ], calendar: tokyo).cells
        #expect(cells.count == 1)
        #expect(cells.first?.hour == tokyo.component(.hour, from: at))
        #expect(cells.first?.weekday == tokyo.component(.weekday, from: at))
    }

    @Test("The hardest and most idle are named only with enough behind them")
    func named() throws {
        let calendar = try calendar()
        var samples: [HourSample] = []
        // Two weeks of every day at 10 AM and 3 PM, and one 95% Saturday at midnight.
        for week in 0 ..< 2 {
            for day in 0 ..< 7 {
                let base = try date(calendar, 2026, 9, 7 + week * 7 + day, 10)
                samples.append(HourSample(at: base, cpu: 2, coveredMinutes: 60))
                samples.append(HourSample(at: base + 5 * 3600, cpu: day == 1 ? 45 : 20, coveredMinutes: 60))
            }
        }
        try samples.append(HourSample(at: date(calendar, 2026, 9, 12, 0), cpu: 95, coveredMinutes: 60))
        let hours = BusiestHours.read(samples, calendar: calendar)
        // Tuesday (weekday 3) at 3 PM, not the one Saturday at 95%.
        #expect(hours.hardest?.weekday == 3)
        #expect(hours.hardest?.hour == 15)
        #expect(hours.idlest?.hour == 10)
        #expect(hours.dayCount == 14)
        // Under a week of days: a grid, but nothing named.
        let short = BusiestHours.read(Array(samples.prefix(6)), calendar: calendar)
        #expect(short.hardest == nil)
        #expect(short.idlest == nil)
        #expect(!short.cells.isEmpty)
    }

    @Test("Weeks start on the Mac's first day")
    func firstDay() throws {
        #expect(try BusiestHours.weekdays(calendar: calendar(firstWeekday: 1)) == [1, 2, 3, 4, 5, 6, 7])
        #expect(try BusiestHours.weekdays(calendar: calendar(firstWeekday: 2)) == [2, 3, 4, 5, 6, 7, 1])
        #expect(try BusiestHours.weekdays(calendar: calendar(firstWeekday: 7)) == [7, 1, 2, 3, 4, 5, 6])
    }

    @Test("Nothing recorded, nothing to show")
    func empty() {
        let hours = BusiestHours.read([])
        #expect(hours.cells.isEmpty)
        #expect(hours.hardest == nil)
        #expect(hours.since == nil)
    }
}
