import Core
import Foundation
import Testing

/// Your week, day by day (D-184): the seven days and the one with the most use.
struct WeekDaysTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return calendar
    }()

    @Test("Seven calendar days, oldest first, today running only to now")
    func days() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15, minute: 30)) ?? Date()
        let days = WeeklyReport.days(ending: now, calendar: calendar)
        #expect(days.count == 7)
        #expect(days.first?.start == calendar.date(from: DateComponents(year: 2026, month: 10, day: 8)))
        #expect(days.last?.start == calendar.startOfDay(for: now))
        #expect(days.last?.end == now)
        #expect(days.dropLast().allSatisfy { $0.duration == 86400 })
    }

    @Test("Monday's summary, ending at midnight: Monday to Sunday, seven whole days")
    func endingAtMidnight() {
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12)) ?? Date()
        let days = WeeklyReport.days(ending: monday, calendar: calendar)
        #expect(days.first?.start == calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)))
        #expect(days.last?.end == monday)
        #expect(days.allSatisfy { $0.duration == 86400 })
    }

    @Test("A day that's 23 hours long (clocks go forward) still ends at the next midnight")
    func daylightSaving() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9)) ?? Date()
        let days = WeeklyReport.days(ending: now, calendar: calendar)
        let springForward = days.first { calendar.component(.day, from: $0.start) == 8 }
        #expect(springForward?.duration == 23.0 * 3600)
    }

    @Test("The day with the most use, and none when nothing was recorded")
    func mostInUse() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8)) ?? Date()
        let byDay = [3.0, 7, 5, 0, 0, 0, 1].enumerated().map { index, hours in
            DayTotal(day: start.addingTimeInterval(Double(index) * 86400), seconds: hours * 3600)
        }
        #expect(report(byDay).mostInUse?.seconds == 7.0 * 3600)
        #expect(report(byDay.map { DayTotal(day: $0.day, seconds: 0) }).mostInUse == nil)
    }

    private func report(_ byDay: [DayTotal]) -> WeeklyReport {
        WeeklyReport(
            start: Date(), end: Date(), activeSeconds: 0, previousActiveSeconds: nil, topApps: [], averageSleepSeconds: nil,
            dataBytes: 0, writtenBytes: 0, crashes: 0, busiestDay: nil, charges: nil, activeByDay: byDay
        )
    }
}
