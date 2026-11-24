import Core
import Foundation
import GRDB
@testable import History
import Testing

/// Test run times in SQLite (D-278): beside the builds, in one table, never mixed with them.
struct TestRunStoreTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000.5)

    private func test(_ offset: TimeInterval, outcome: TestOutcome, partial: Bool = false) -> BuildRun {
        BuildRun(
            kind: .test, start: start + offset, end: start + offset + 30, project: "Kit", tool: "swift test", averageCPU: 0, peakMemory: 0,
            outcome: outcome, isPartial: partial
        )
    }

    @Test("Test runs come back with how they ended; builds and test runs don't mix")
    func kept() async throws {
        let store = try SQLiteHistoryStore(url: nil)
        let build = BuildRun(start: start, end: start + 95, project: "Kit", tool: "Swift", averageCPU: 62, peakMemory: 1 << 30)
        let runs = [
            test(1, outcome: .passed),
            test(2, outcome: .failed),
            test(3, outcome: .cancelled),
            test(4, outcome: .unknown, partial: true),
        ]
        try await store.recordBuildRun(build)
        for run in runs {
            try await store.recordBuildRun(run)
        }
        #expect(try await store.testRuns(from: start - 1, to: start + 3600) == runs)
        // What the CLI, Shortcuts and Checkup read stays builds alone.
        let builds = try await store.buildRuns(from: start - 1, to: start + 3600)
        #expect(builds == [build])
        #expect(builds.first?.kind == .build && builds.first?.outcome == nil && builds.first?.isPartial == false)
        #expect(try await store.testRuns(from: start + 2, to: start + 3600).count == 3)
        try await store.deleteAll()
        #expect(try await store.testRuns(from: start - 1, to: start + 3600).isEmpty)
    }

    @Test("The migration keeps every build a Mac already recorded, as builds")
    func migration() throws {
        let queue = try DatabaseQueue()
        let migrator = HistorySchema.migrator
        try migrator.migrate(queue, upTo: "v20: sensor changes")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO build_run (t, project, endT, tool, cpu, memory) VALUES (100, 'Kit', 160, 'Swift', 50, 1000)
            """)
        }
        try migrator.migrate(queue)
        let row = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT kind, outcome, partial, endT FROM build_run")
        }
        let kept = try #require(row)
        #expect(kept["kind"] as String == "build")
        #expect((kept["outcome"] as String?) == nil)
        #expect(kept["partial"] as Int == 0)
        #expect(kept["endT"] as Double == 160)
    }
}
