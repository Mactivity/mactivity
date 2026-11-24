@testable import Core
import Foundation
import Testing

/// Agent history (D-192): minutes into quarter-hours, and the week's summaries.
struct AgentHistoryTests {
    private let quarter = Date(timeIntervalSince1970: 1_790_000_100).quarterStart

    private func session(_ agent: String, _ project: String?, cpu: Double, memory: UInt64, pid: Int32 = 1) -> AgentSession {
        AgentSession(
            pid: pid, agent: agent, project: project, directory: nil, host: "Terminal", startedAt: quarter, processCount: 3,
            cpuPercent: cpu, memoryBytes: memory, busiestChildren: [], stopTargets: []
        )
    }

    @Test("A minute counts once; two sessions in one project are one row, their figures added")
    func accumulates() {
        var accumulator = AgentUsageAccumulator()
        let both = [session("Claude Code", "api", cpu: 10, memory: 100, pid: 1), session("Claude Code", "api", cpu: 5, memory: 50, pid: 2)]
        _ = accumulator.add(both, at: quarter.addingTimeInterval(10))
        #expect(accumulator.add(both, at: quarter.addingTimeInterval(40)).isEmpty, "same minute again")
        let rows = accumulator.add([session("Claude Code", "api", cpu: 20, memory: 400)], at: quarter.addingTimeInterval(70))
        #expect(rows.count == 1)
        #expect(rows.first?.minutes == 2)
        #expect(rows.first?.cpuTotal == 35)
        #expect(rows.first?.peakMemory == 400)
        #expect(rows.first?.start == quarter)
    }

    @Test("A new quarter-hour starts its rows afresh; a minute with no agent writes nothing")
    func newQuarter() {
        var accumulator = AgentUsageAccumulator()
        _ = accumulator.add([session("Codex", "web", cpu: 10, memory: 10)], at: quarter)
        #expect(accumulator.add([], at: quarter.addingTimeInterval(60)).isEmpty)
        let next = accumulator.add([session("Codex", "web", cpu: 30, memory: 10)], at: quarter.addingTimeInterval(900))
        #expect(next.first?.start == quarter.addingTimeInterval(900))
        #expect(next.first?.minutes == 1)
        #expect(next.first?.cpuTotal == 30)
    }

    @Test("The week by agent and project, most time first, with the days each ran")
    func totals() {
        let rows = [
            AgentUsage(start: quarter, agent: "Claude Code", project: "api", minutes: 15, cpuTotal: 150, peakMemory: 900),
            AgentUsage(start: quarter + 900, agent: "Claude Code", project: "api", minutes: 10, cpuTotal: 50, peakMemory: 1200),
            AgentUsage(start: quarter + 86400, agent: "Claude Code", project: "api", minutes: 5, cpuTotal: 5, peakMemory: 100),
            AgentUsage(start: quarter, agent: "Codex", project: "web", minutes: 8, cpuTotal: 80, peakMemory: 300),
        ]
        let totals = AgentWeek.totals(rows)
        #expect(totals.map(\.agent) == ["Claude Code", "Codex"])
        #expect(totals.first?.minutes == 30)
        #expect(totals.first?.peakMemory == 1200)
        #expect(totals.first?.days == 2)
        #expect(totals.first.map { abs($0.averageCPU - 205.0 / 30) < 0.001 } == true)
    }

    @Test("Back-to-back quarter-hours are one stretch; a gap starts another")
    func stretches() {
        let rows = [0.0, 900, 1800, 5400].map {
            AgentUsage(start: quarter + $0, agent: "Claude Code", project: "api", minutes: 15, cpuTotal: 0, peakMemory: 0)
        }
        let stretches = AgentWeek.stretches(rows)
        #expect(stretches.count == 2)
        #expect(stretches.first?.start == quarter)
        #expect(stretches.first?.end == quarter + 2700)
        #expect(stretches.first?.minutes == 45)
        #expect(stretches.last?.start == quarter + 5400)
    }

    @Test("A day's agent time counts a quarter-hour once, however many agents ran in it")
    func byDay() {
        let day = DateInterval(start: quarter, duration: 86400)
        let rows = [
            AgentUsage(start: quarter, agent: "Claude Code", project: "api", minutes: 15, cpuTotal: 0, peakMemory: 0),
            AgentUsage(start: quarter, agent: "Codex", project: "web", minutes: 12, cpuTotal: 0, peakMemory: 0),
            AgentUsage(start: quarter + 900, agent: "Codex", project: "web", minutes: 6, cpuTotal: 0, peakMemory: 0),
        ]
        #expect(AgentWeek.byDay(rows, days: [day]).first?.seconds == 21.0 * 60)
    }

    @Test("After a relaunch, the quarter-hour's stored minutes carry on rather than starting from zero (D-219)")
    func seed() {
        var accumulator = AgentUsageAccumulator()
        accumulator.seed(
            [AgentUsage(start: quarter, agent: "Claude Code", project: "api", minutes: 7, cpuTotal: 70, peakMemory: 5)],
            at: quarter + 420
        )
        let rows = accumulator.add([session("Claude Code", "api", cpu: 10, memory: 9)], at: quarter + 480)
        #expect(rows.first?.minutes == 8)
        #expect(rows.first?.cpuTotal == 80)
        #expect(rows.first?.peakMemory == 9)
    }
}

private extension Date {
    var quarterStart: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 / 900).rounded(.down) * 900)
    }

}
