@testable import Core
import Foundation
import Testing

/// Two days or two weeks side by side (D-207).
struct DayComparisonTests {
    private func app(_ name: String, kind: AppIdentity.Kind = .app) -> AppIdentity {
        AppIdentity(id: name.lowercased(), name: name, bundleID: nil, iconKey: "x", kind: kind)
    }

    @Test("The apps that moved most, either way, an app missing counting as nothing; not macOS, not small moves")
    func shifts() {
        let first = [AppTotal(app: app("Xcode"), value: 30), AppTotal(app: app("Safari"), value: 4), AppTotal(app: app("Notes"), value: 1)]
        let second = [
            AppTotal(app: app("Xcode"), value: 6), AppTotal(app: app("Docker"), value: 12), AppTotal(app: app("Notes"), value: 1.5),
            AppTotal(app: app("macOS", kind: .system), value: 40),
        ]
        let shifts = DayComparison.shifts(metric: .cpu, first: first, second: second)
        #expect(shifts.map(\.app.name) == ["Xcode", "Docker", "Safari"])
        #expect(shifts.first?.first == 30 && shifts.first?.second == 6)
        #expect(shifts[1].first == 0)
    }

    @Test("Slowdowns and alerts counted from a day's timeline")
    func counts() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let result = DayStoryResult(events: [
            DayEvent(start: now, end: now + 600, kind: .slowdown([.memory])),
            DayEvent(start: now + 900, kind: .alert(title: "High CPU", app: app("Xcode"), count: 3)),
            DayEvent(start: now + 1200, end: now + 1800, kind: .slowdown([.cpu])),
            DayEvent(start: now + 2000, kind: .alert(title: "Heavy disk", app: app("Photos"), count: 1)),
        ], apps: [:], activeSeconds: 3600)
        #expect(DayComparison.slowdowns(result) == 2)
        #expect(DayComparison.alerts(result) == 4)
    }

    @Test("A week is the seven days ending on the day, never past now")
    func interval() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15)) ?? Date()
        let week = DayComparison.interval(ending: day, days: 7, now: day + 86400 * 3, calendar: calendar)
        #expect(week.start == calendar.date(from: DateComponents(year: 2026, month: 10, day: 8)))
        #expect(week.duration == 7 * 86400)
        #expect(DayComparison.interval(ending: day, days: 1, now: day, calendar: calendar).end == day)
    }
}
