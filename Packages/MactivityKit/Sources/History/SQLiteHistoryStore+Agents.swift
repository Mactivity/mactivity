import Core
import Foundation
import GRDB

/// Agent history (D-192): a row per agent, project and quarter-hour.
extension SQLiteHistoryStore: AgentHistoryStore {
    public func recordAgentUsage(_ rows: [AgentUsage]) throws {
        guard !rows.isEmpty else {
            return
        }
        try database.write { db in
            for row in rows {
                try db.execute(sql: """
                INSERT OR REPLACE INTO agent_usage (t, agent, project, minutes, cpu, memory) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    Int64(row.start.timeIntervalSince1970), row.agent, row.project, row.minutes, row.cpuTotal,
                    Int64(clamping: row.peakMemory),
                ])
            }
        }
    }

    public func agentUsage(from: Date, to: Date) throws -> [AgentUsage] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
            SELECT t, agent, project, minutes, cpu, memory FROM agent_usage WHERE t >= ? AND t < ? ORDER BY t, agent, project
            """, arguments: [Int64(from.timeIntervalSince1970.rounded(.down)), Int64(to.timeIntervalSince1970.rounded(.up))]).map { row in
                let memory: Int64 = row["memory"]
                return AgentUsage(
                    start: Date(timeIntervalSince1970: TimeInterval(row["t"] as Int64)), agent: row["agent"], project: row["project"],
                    minutes: row["minutes"], cpuTotal: row["cpu"], peakMemory: UInt64(max(0, memory))
                )
            }
        }
    }
}
