import Core
import Foundation

/// A developer's agents over any span, by the calendar (D-192): Claude Code in mactivity on
/// weekday mornings and afternoons, Codex in api after lunch, Claude Code in docs-site on a
/// Saturday morning. For previews, renders and demo mode.
public enum SimulatedAgentHistory {
    private struct Shift {
        let agent: String
        let project: String
        let hours: Range<Double>
        let weekdays: Set<Int>
        let cpu: Double
        let memory: UInt64
    }

    private static let workdays: Set<Int> = [2, 3, 4, 5, 6]
    private static let shifts = [
        Shift(agent: "Claude Code", project: "mactivity", hours: 9 ..< 12, weekdays: workdays, cpu: 6, memory: 1_400_000_000),
        Shift(agent: "Claude Code", project: "mactivity", hours: 14 ..< 17.5, weekdays: workdays, cpu: 8, memory: 1_900_000_000),
        Shift(agent: "Codex", project: "api", hours: 13 ..< 15, weekdays: [3, 5], cpu: 3, memory: 600_000_000),
        Shift(agent: "Claude Code", project: "docs-site", hours: 10 ..< 11.25, weekdays: [7], cpu: 4, memory: 900_000_000),
    ]

    public static func rows(from: Date, to: Date, calendar: Calendar = .current) -> [AgentUsage] {
        var rows: [AgentUsage] = []
        var quarter = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / 900).rounded(.up) * 900)
        while quarter < to {
            let weekday = calendar.component(.weekday, from: quarter)
            let hour = Double(calendar.component(.hour, from: quarter)) + Double(calendar.component(.minute, from: quarter)) / 60
            for shift in shifts where shift.weekdays.contains(weekday) && shift.hours.contains(hour) {
                let wobble = Double(Int(quarter.timeIntervalSince1970 / 900) % 5) - 2
                rows.append(AgentUsage(
                    start: quarter, agent: shift.agent, project: shift.project, minutes: 15,
                    cpuTotal: max(0.5, shift.cpu + wobble) * 15, peakMemory: shift.memory
                ))
            }
            quarter = quarter.addingTimeInterval(900)
        }
        return rows
    }
}

extension SimulatedThirtyDayHistory: AgentHistoryStore {
    public func recordAgentUsage(_: [AgentUsage]) async throws {}

    public func agentUsage(from: Date, to: Date) async throws -> [AgentUsage] {
        SimulatedAgentHistory.rows(from: from, to: to)
    }
}

extension SimulatedHistoryStore: AgentHistoryStore {
    public func recordAgentUsage(_: [AgentUsage]) async throws {}

    public func agentUsage(from: Date, to: Date) async throws -> [AgentUsage] {
        SimulatedAgentHistory.rows(from: from, to: to)
    }
}
