@testable import Alerts
import Core
import Foundation
import Testing

@Suite("Your week (D-102)")
struct WeeklyDigestTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// Monday 2026-09-28 00:00 UTC.
    private let monday = Date(timeIntervalSince1970: 1_790_553_600)

    private func report(active: Double, previous: Double? = nil, sleep: Double? = nil, crashes: Int = 0) -> WeeklyReport {
        let xcode = AppIdentity(id: "x", name: "Xcode", bundleID: nil, iconKey: "other", kind: .app)
        return WeeklyReport(
            start: monday - 7 * 86400, end: monday, activeSeconds: active, previousActiveSeconds: previous,
            topApps: [AppTotal(app: xcode, value: active / 2)], averageSleepSeconds: sleep, dataBytes: 0, writtenBytes: 0,
            crashes: crashes, busiestDay: nil, charges: nil
        )
    }

    @Test("Mondays from 9, once a week")
    func due() {
        #expect(!Digest.isWeeklyDue(now: monday + 8 * 3600, lastSent: nil, calendar: calendar))
        #expect(Digest.isWeeklyDue(now: monday + 9 * 3600, lastSent: nil, calendar: calendar))
        #expect(!Digest.isWeeklyDue(now: monday + 10 * 3600, lastSent: monday + 9 * 3600, calendar: calendar))
        #expect(!Digest.isWeeklyDue(now: monday + 86400 + 10 * 3600, lastSent: nil, calendar: calendar))
        #expect(Digest.isWeeklyDue(now: monday + 9 * 3600, lastSent: monday - 7 * 86400 + 9 * 3600, calendar: calendar))
        // Missed Monday (off, or no wake): due later that week, once (D-139).
        let lastMonday = monday - 7 * 86400 + 9 * 3600
        #expect(Digest.isWeeklyDue(now: monday + 86400 + 14 * 3600, lastSent: lastMonday, calendar: calendar))
        #expect(!Digest.isWeeklyDue(now: monday + 2 * 86400, lastSent: monday + 86400 + 14 * 3600, calendar: calendar))
        #expect(Digest.weeklyDueTime(atOrBefore: monday + 3 * 86400, calendar: calendar) == monday + 9 * 3600)
    }

    @Test("The notification names the time in use, the top app, sleep and crashes; a quiet week says nothing")
    func text() throws {
        let content = try #require(Digest.weekly(report(active: 38 * 3600, sleep: 7 * 3600, crashes: 3)))
        #expect(content.body.contains("Xcode"))
        #expect(content.body.contains("3"))
        #expect(Digest.weekly(report(active: 600)) == nil)
    }

    @Test("Agent time gets a line once it's an hour, naming the busiest agent and project (D-192)")
    func agents() throws {
        let base = report(active: 30 * 3600)
        func with(_ seconds: Double, project: String) -> WeeklyReport {
            WeeklyReport(
                start: base.start, end: base.end, activeSeconds: base.activeSeconds, previousActiveSeconds: nil, topApps: base.topApps,
                averageSleepSeconds: nil, dataBytes: 0, writtenBytes: 0, crashes: 0, busiestDay: nil, charges: nil,
                agentSeconds: seconds,
                topAgent: AgentWeek.Total(agent: "Claude Code", project: project, minutes: 600, cpuTotal: 0, peakMemory: 0, days: 4)
            )
        }
        let body = try #require(Digest.weekly(with(12 * 3600, project: "mactivity"))).body
        #expect(body.contains("Claude Code in mactivity"))
        #expect(try #require(Digest.weekly(with(1800, project: "mactivity"))).body.contains("Claude Code") == false)
    }

    @Test("A week that began recording partway says so, and sends no notification (D-108)")
    func partialWeek() {
        let start = monday - 7 * 86400
        #expect(WeeklyReport.recordingSince(firstFocus: nil, weekStart: start) == nil)
        #expect(WeeklyReport.recordingSince(firstFocus: start - 86400, weekStart: start) == nil)
        #expect(WeeklyReport.recordingSince(firstFocus: start + 1800, weekStart: start) == nil)
        let since = monday - 6 * 3600
        #expect(WeeklyReport.recordingSince(firstFocus: since, weekStart: start) == since)
        let partial = WeeklyReport(
            start: start, end: monday, activeSeconds: 5 * 3600, previousActiveSeconds: nil, topApps: [],
            averageSleepSeconds: nil, dataBytes: 0, writtenBytes: 0, crashes: 0, busiestDay: nil, charges: nil,
            recordingSince: since
        )
        #expect(Digest.weekly(partial) == nil)
    }

    @Test("Change against the week before, only with a week before worth comparing")
    func change() {
        #expect(report(active: 12 * 3600, previous: 10 * 3600).activeChange == 0.2)
        #expect(report(active: 12 * 3600, previous: 600).activeChange == nil)
        #expect(report(active: 12 * 3600).activeChange == nil)
    }

    @Test("Sleep per night, noon to noon, leaving out nights without any")
    func sleep() {
        let events = [
            PowerEvent(at: monday - 6 * 86400 - 3600, kind: .sleep), PowerEvent(at: monday - 6 * 86400 + 7 * 3600, kind: .wake),
            PowerEvent(at: monday - 2 * 86400 - 3600, kind: .sleep), PowerEvent(at: monday - 2 * 86400 + 5 * 3600, kind: .wake),
        ]
        let average = WeeklyReport.averageSleep(events, from: monday - 7 * 86400, to: monday, calendar: calendar)
        #expect(abs((average ?? 0) - 25200) < 1)
    }
}
