import Core
import Foundation
@testable import History
import Testing

/// Build times in SQLite (D-209).
struct BuildRunStoreTests {
    @Test("Builds are read back by span, oldest first; deleting history deletes them")
    func recordAndRead() async throws {
        let store = try SQLiteHistoryStore(url: nil)
        let start = Date(timeIntervalSince1970: 1_790_000_000.5)
        let first = BuildRun(start: start, end: start + 95.5, project: "Mactivity", tool: "Swift", averageCPU: 62.5, peakMemory: 3 << 30)
        let second = BuildRun(start: start + 600, end: start + 640, project: "engine", tool: "Rust", averageCPU: 80, peakMemory: 1 << 30)
        try await store.recordBuildRun(second)
        try await store.recordBuildRun(first)
        let runs = try await store.buildRuns(from: start - 1, to: start + 3600)
        #expect(runs == [first, second])
        #expect(try await store.buildRuns(from: start + 1, to: start + 3600) == [second])
        try await store.deleteAll()
        #expect(try await store.buildRuns(from: start - 1, to: start + 3600).isEmpty)
    }
}
