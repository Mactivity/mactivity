import Core
import Foundation
import Testing

@Suite("An app's history page math (D-168)")
struct AppRhythmTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Monday 2027-01-04, 00:00 UTC.
    private var monday: Date {
        calendar.date(from: DateComponents(year: 2027, month: 1, day: 4)) ?? Date()
    }

    @Test("Quarter-hours average into hours and days, with each bucket's peak")
    func buckets() {
        let points = (0 ..< 8).map { i in
            SeriesPoint(at: monday.addingTimeInterval(Double(i) * 900), average: Double(i), maximum: Double(i) * 2)
        }
        let hours = AppRhythm.bucketed(points, by: .hour, calendar: calendar)
        #expect(hours.map(\.average) == [1.5, 5.5])
        #expect(hours.map(\.maximum) == [6, 14])
        let days = AppRhythm.bucketed(points, by: .day, calendar: calendar)
        #expect(days.count == 1)
        #expect(days.first?.average == 3.5)
    }

    @Test("Average and peak; nothing for no points")
    func summary() {
        let points = [SeriesPoint(at: monday, average: 10, maximum: 40), SeriesPoint(at: monday, average: 20, maximum: 25)]
        let summary = AppRhythm.summary(points)
        #expect(summary?.average == 15)
        #expect(summary?.peak == 40)
        #expect(AppRhythm.summary([]) == nil)
    }

    @Test("The week grid starts on the calendar's first weekday; empty cells are nil")
    func week() {
        let mondayNine = monday.addingTimeInterval(9 * 3600)
        let sundayTen = monday.addingTimeInterval(6 * 86400 + 10 * 3600)
        let grid = AppRhythm.week([
            SeriesPoint(at: mondayNine, average: 30, maximum: 30),
            SeriesPoint(at: mondayNine.addingTimeInterval(900), average: 10, maximum: 10),
            SeriesPoint(at: sundayTen, average: 5, maximum: 5),
        ], calendar: calendar)
        #expect(grid.count == 7)
        #expect(grid[0][9] == 20)
        #expect(grid[6][10] == 5)
        #expect(grid[3][3] == nil)
    }
}
