import Core
import Foundation
@testable import Readouts
import Testing

/// Siri's summaries of History (1.6), in English.
struct HistorySummariesTests {
    let locale = Locale(identifier: "en_US")
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Your day: time in use, what happened, the agents")
    func day() {
        let app = AppIdentity(id: "a", name: "Xcode", bundleID: nil, iconKey: "other", kind: .app)
        let busy = DayStoryResult(events: [
            DayEvent(start: start, kind: .slowdown([])),
            DayEvent(start: start, kind: .alert(title: "Xcode is busy", app: app, count: 2)),
        ], apps: [:], activeSeconds: 5 * 3600 + 12 * 60, agentSeconds: 2 * 3600)
        let text = HistorySummaries.day(busy, isToday: true, locale: locale)
        #expect(text.hasPrefix("Today: 5h 12m in use."))
        #expect(text.contains("alerts"))
        #expect(text.hasSuffix("Agents worked 2h."))
        let quiet = HistorySummaries.day(DayStoryResult(events: [], apps: [:], activeSeconds: 3600), isToday: false, locale: locale)
        #expect(quiet == "Yesterday: 1h in use. A quiet day: no slowdowns, alerts or crashes.")
    }

    @Test("Out of the ordinary: learning first, then nothing, then the apps")
    func unusual() {
        #expect(HistorySummaries.unusual([], daysLeftToLearn: 2, locale: locale).hasPrefix("Still learning"))
        #expect(HistorySummaries.unusual([], daysLeftToLearn: 0, locale: locale).hasPrefix("Nothing out of the ordinary"))
    }

    @Test("Agents: overlapping time counted once, the busiest project named")
    func agents() {
        let rows = [
            AgentUsage(start: start, agent: "Claude Code", project: "mactivity", minutes: 15, cpuTotal: 0, peakMemory: 0),
            AgentUsage(start: start, agent: "Codex", project: "api", minutes: 10, cpuTotal: 0, peakMemory: 0),
            AgentUsage(
                start: start.addingTimeInterval(900),
                agent: "Claude Code",
                project: "mactivity",
                minutes: 15,
                cpuTotal: 0,
                peakMemory: 0
            ),
        ]
        let text = HistorySummaries.agents(rows, locale: locale)
        #expect(text == "This week your agents worked 30m, most in mactivity (30m, Claude Code).")
        #expect(HistorySummaries.agents([], locale: locale) == "No agent sessions this week.")
    }

    @Test("Builds: none this week")
    func builds() {
        #expect(HistorySummaries.builds([], builds: 0, locale: locale) == "No builds this week.")
    }
}
