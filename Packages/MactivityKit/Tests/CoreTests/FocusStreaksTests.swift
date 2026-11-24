import Core
import Foundation
import Testing

@Suite("Focus streaks (D-271)")
struct FocusStreaksTests {
    private let xcode = AppIdentity(id: "xcode", name: "Xcode", bundleID: nil, iconKey: "x", kind: .app)
    private let mail = AppIdentity(id: "mail", name: "Mail", bundleID: nil, iconKey: "m", kind: .app)
    private let finder = AppIdentity(id: "finder", name: "Finder", bundleID: nil, iconKey: "f", kind: .app)
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(_ app: AppIdentity, _ from: TimeInterval, _ to: TimeInterval) -> FocusStretch {
        FocusStretch(app: app, start: base + from, end: base + to)
    }

    @Test("A glance at another app stays inside the streak, and doesn't count toward it")
    func glance() throws {
        let found = FocusStreaks.streaks([row(xcode, 0, 600), row(mail, 601, 611), row(xcode, 612, 1200)])
        let streak = try #require(found.first)
        #expect(found.count == 1)
        #expect(streak.app == xcode)
        #expect(streak.seconds == 600 + 588)
        #expect(streak.end == base + 1200)
    }

    @Test("Longer than a glance away ends it, and that app broke it")
    func broken() {
        let found = FocusStreaks.streaks([row(xcode, 0, 600), row(mail, 601, 700), row(xcode, 701, 900)])
        #expect(found.map(\.app) == [xcode, mail, xcode])
        #expect(found[0].brokenBy == mail)
        #expect(found[0].seconds == 600)
    }

    @Test("Several short looks in a row add up: what counts is the time away")
    func manyGlances() {
        let found = FocusStreaks.streaks([
            row(xcode, 0, 300), row(mail, 301, 316), row(finder, 317, 332), row(mail, 333, 348), row(xcode, 349, 600),
        ])
        // 49 s away is more than a glance, even though no one app had that long.
        #expect(found.first?.seconds == 300)
    }

    @Test("A look on the way doesn't take the blame: the app that stayed broke it")
    func breakerIsTheOneThatStayed() {
        let found = FocusStreaks.streaks([row(xcode, 0, 600), row(finder, 601, 610), row(mail, 611, 900)])
        #expect(found.first?.brokenBy == mail)
    }

    @Test("Stepping away ends a streak with no app to blame, even back in the same app")
    func steppedAway() {
        let found = FocusStreaks.streaks([row(xcode, 0, 600), row(xcode, 1000, 1500)])
        #expect(found.count == 2)
        #expect(found[0].brokenBy == nil)
    }

    @Test("Rows out of order, or overlapping by a moment, don't double count")
    func overlap() {
        let found = FocusStreaks.streaks([row(xcode, 590, 700), row(xcode, 0, 600)])
        #expect(found.count == 1)
        #expect(found.first?.seconds == 700)
    }

    @Test("Each day's longest, newest day first; a streak over midnight belongs to the day it began")
    func days() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let midnight = calendar.startOfDay(for: base)
        let late = midnight.addingTimeInterval(86400 - 300)
        let rows = [
            FocusStretch(app: xcode, start: midnight + 3600, end: midnight + 3900),
            FocusStretch(app: mail, start: midnight + 7200, end: midnight + 8000),
            FocusStretch(app: xcode, start: late, end: late + 1200),
            FocusStretch(app: mail, start: late + 90000, end: late + 90300),
        ]
        let report = FocusStreaks.report(rows, calendar: calendar)
        #expect(report.days.count == 2)
        #expect(report.days[0].day > report.days[1].day)
        #expect(report.days[1].longest.map(\.seconds) == [1200, 800, 300])
    }

    @Test("Only streaks worth breaking count: a minute in one app isn't broken by the next")
    func breakers() {
        let rows = [
            row(xcode, 0, 600), row(mail, 601, 700), // Mail breaks a 10-minute streak.
            row(finder, 701, 800), // Finder only follows 99 s of Mail.
            row(xcode, 801, 1500), row(mail, 1501, 1600),
        ]
        let report = FocusStreaks.report(rows)
        #expect(report.breakers.map(\.app) == [mail])
        #expect(report.breakers.first?.count == 2)
    }

    @Test("No rows, no report")
    func empty() {
        let report = FocusStreaks.report([])
        #expect(report.days.isEmpty)
        #expect(report.breakers.isEmpty)
    }
}
