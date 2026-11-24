import Core
import Foundation
@testable import History
import Testing

/// Agent history in SQLite (D-192).
struct AgentUsageStoreTests {
    @Test("A quarter-hour written again as it fills replaces itself; reads are by span, oldest first")
    func recordAndRead() async throws {
        let store = try SQLiteHistoryStore(url: nil)
        let quarter = Date(timeIntervalSince1970: 1_790_000_100 / 900 * 900)
        try await store.recordAgentUsage([
            AgentUsage(start: quarter, agent: "Claude Code", project: "api", minutes: 3, cpuTotal: 30, peakMemory: 1 << 30),
        ])
        try await store.recordAgentUsage([
            AgentUsage(start: quarter, agent: "Claude Code", project: "api", minutes: 4, cpuTotal: 41, peakMemory: 2 << 30),
            AgentUsage(start: quarter + 900, agent: "Codex", project: "", minutes: 1, cpuTotal: 2, peakMemory: 10),
        ])
        let rows = try await store.agentUsage(from: quarter, to: quarter + 1800)
        #expect(rows.count == 2)
        #expect(rows.first?.minutes == 4)
        #expect(rows.first?.cpuTotal == 41)
        #expect(rows.first?.peakMemory == 2 << 30)
        #expect(rows.last?.agent == "Codex")
        #expect(try await store.agentUsage(from: quarter + 900, to: quarter + 1800).count == 1)
    }

    @Test("Deleting history deletes agent history too")
    func deleteAll() async throws {
        let store = try SQLiteHistoryStore(url: nil)
        let quarter = Date(timeIntervalSince1970: 1_790_000_100 / 900 * 900)
        try await store.recordAgentUsage([AgentUsage(
            start: quarter,
            agent: "Codex",
            project: "api",
            minutes: 1,
            cpuTotal: 1,
            peakMemory: 1
        )])
        try await store.deleteAll()
        #expect(try await store.agentUsage(from: quarter, to: quarter + 900).isEmpty)
    }
}
