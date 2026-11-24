@testable import Core
import Foundation
import Testing

/// Looking back (D-254): spans, apps that came and went, busiest days, agents.
struct LookingBackTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    private func app(_ name: String, _ hours: Double) -> AppTotal {
        AppTotal(app: AppIdentity(id: name, name: name, bundleID: nil, iconKey: "other", kind: .app), value: hours * 3600)
    }

    @Test("A month or a year, to now when it's the current one; the one before in full")
    func spans() {
        let now = date(2026, 10, 30)
        let month = LookingBack.interval(.month, containing: now, now: now, calendar: calendar)
        #expect(month.start == date(2026, 10, 1))
        #expect(month.end == now)
        let september = LookingBack.interval(.month, containing: date(2026, 9, 12), now: now, calendar: calendar)
        #expect(september.end == date(2026, 10, 1))
        #expect(LookingBack.previous(.month, before: month, calendar: calendar).start == date(2026, 9, 1))
        let year = LookingBack.interval(.year, containing: now, now: now, calendar: calendar)
        #expect(year.start == date(2026, 1, 1))
        #expect(LookingBack.previous(.year, before: year, calendar: calendar) == DateInterval(
            start: date(2025, 1, 1),
            end: date(2026, 1, 1)
        ))
    }

    @Test("Came: half an hour or more, and not used before. Went: an hour or more before, and not now")
    func cameAndWent() {
        let now = [app("Xcode", 40), app("Figma", 2), app("Zoom", 0.2)]
        let before = [app("Xcode", 30), app("Slack", 12), app("Notes", 0.5)]
        let change = LookingBack.cameAndWent(current: now, previous: before)
        #expect(change.came.map(\.app.name) == ["Figma"])
        #expect(change.went.map(\.app.name) == ["Slack"])
    }

    @Test("The busiest days, most first, empty days left out")
    func busiest() {
        let days = [
            DayTotal(day: date(2026, 10, 1), seconds: 3600),
            DayTotal(day: date(2026, 10, 2), seconds: 0),
            DayTotal(day: date(2026, 10, 3), seconds: 7200),
        ]
        #expect(LookingBack.busiest(days).map(\.day) == [date(2026, 10, 3), date(2026, 10, 1)])
    }

    @Test("Agents: two at once count once; the project worked in most")
    func agents() {
        let start = date(2026, 10, 5)
        let rows = [
            AgentUsage(start: start, agent: "Claude Code", project: "mactivity", minutes: 15, cpuTotal: 0, peakMemory: 0),
            AgentUsage(start: start, agent: "Codex", project: "site", minutes: 10, cpuTotal: 0, peakMemory: 0),
            AgentUsage(
                start: start.addingTimeInterval(900),
                agent: "Claude Code",
                project: "mactivity",
                minutes: 15,
                cpuTotal: 0,
                peakMemory: 0
            ),
        ]
        let total = LookingBack.agents(rows)
        #expect(total.seconds == 30 * 60)
        #expect(total.project == "mactivity")
    }

    @Test("Up or down against the span before, only with enough to compare")
    func change() {
        func recap(_ active: Double, _ previous: Double?, since: Date? = nil) -> PeriodRecap {
            PeriodRecap(
                span: .month, interval: DateInterval(start: date(2026, 10, 1), duration: 86400), activeSeconds: active,
                previousActiveSeconds: previous, busiestDays: [], busiestMonth: nil, topApps: [], came: [], went: [],
                agentSeconds: 0, topAgentProject: nil, slowdowns: 0, crashes: nil, dataBytes: 0, writtenBytes: 0, notes: 0,
                recordingSince: since
            )
        }
        #expect(recap(150 * 3600, 100 * 3600).activeChange == 0.5)
        #expect(recap(150 * 3600, 600).activeChange == nil)
        #expect(recap(150 * 3600, 100 * 3600, since: date(2026, 10, 3)).activeChange == nil)
        #expect(recap(0, nil).isEmpty)
    }
}
