import Core
import Foundation
import GRDB

/// Build times (D-209) and test run times (D-278): a row per run, in one table.
extension SQLiteHistoryStore: BuildHistoryStore {
    public func recordBuildRun(_ run: BuildRun) throws {
        try database.write { db in
            try db.execute(sql: """
            INSERT OR REPLACE INTO build_run (t, project, endT, tool, cpu, memory, kind, outcome, partial)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                run.start.timeIntervalSince1970, run.project, run.end.timeIntervalSince1970, run.tool, run.averageCPU,
                Int64(clamping: run.peakMemory), run.kind.rawValue, run.outcome?.rawValue, run.isPartial,
            ])
        }
    }

    public func buildRuns(from: Date, to: Date) throws -> [BuildRun] {
        try runs(kind: .build, from: from, to: to)
    }

    public func testRuns(from: Date, to: Date) throws -> [BuildRun] {
        try runs(kind: .test, from: from, to: to)
    }

    private func runs(kind: BuildRun.Kind, from: Date, to: Date) throws -> [BuildRun] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
            SELECT t, project, endT, tool, cpu, memory, outcome, partial FROM build_run WHERE kind = ? AND t >= ? AND t < ? ORDER BY t
            """, arguments: [kind.rawValue, from.timeIntervalSince1970, to.timeIntervalSince1970]).map { row in
                let memory: Int64 = row["memory"]
                let outcome: String? = row["outcome"]
                return BuildRun(
                    kind: kind, start: Date(timeIntervalSince1970: row["t"]), end: Date(timeIntervalSince1970: row["endT"]),
                    project: row["project"], tool: row["tool"], averageCPU: row["cpu"], peakMemory: UInt64(max(0, memory)),
                    outcome: outcome.flatMap(TestOutcome.init(rawValue:)), isPartial: row["partial"]
                )
            }
        }
    }
}
