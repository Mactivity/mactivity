import Core
import Foundation
import Testing

@Suite("Notifications by app (D-289)")
struct NotificationStatsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver") ?? .gmt
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: hour, minute: minute)) ?? .distantPast
    }

    @Test("Apps by count, ties by name, with each app's hours on the Mac's clock")
    func apps() {
        let rows = NotificationStats.apps([
            NotificationEvent(at: at(9), app: "b"), NotificationEvent(at: at(9, 30), app: "b"), NotificationEvent(at: at(23), app: "b"),
            NotificationEvent(at: at(0), app: "c"), NotificationEvent(at: at(14), app: "a"), NotificationEvent(at: at(14), app: "c"),
            NotificationEvent(at: at(15), app: "a"),
        ], calendar: calendar)
        #expect(rows.map(\.app) == ["b", "a", "c"])
        #expect(rows[0].count == 3)
        #expect(rows[0].byHour[9] == 2)
        #expect(rows[0].byHour[23] == 1)
        #expect(rows[0].byHour.count == 24)
        #expect(rows[0].busiestHour == 9)
        // A tie: the earlier hour.
        #expect(rows[1].busiestHour == 14)
        #expect(rows[2].busiestHour == 0)
    }

    @Test("No events: no rows and an empty day")
    func empty() {
        #expect(NotificationStats.apps([], calendar: calendar).isEmpty)
        #expect(NotificationStats.byHour([], calendar: calendar) == Array(repeating: 0, count: 24))
    }
}
