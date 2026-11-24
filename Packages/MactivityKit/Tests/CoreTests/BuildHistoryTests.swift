@testable import Core
import Foundation
import Testing

/// Build times (D-209).
struct BuildHistoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func swift(_ pid: Int32, _ project: String?, cpu: Double = 50, memory: UInt64 = 300_000_000) -> CompilerProcess {
        CompilerProcess(pid: pid, name: "swift-frontend", project: project, cpuPercent: cpu, memory: memory)
    }

    @Test("A lid closed mid-build ends the build where it was last seen, not after the night (D-221)")
    func sleepMidBuild() throws {
        var tracker = BuildTracker()
        var finished: [BuildRun] = []
        for step in 0 ..< 6 {
            finished += tracker.observe([swift(9, "Mactivity")], at: t0 + Double(step * 10), interval: 10)
        }
        // Asleep for eight hours; the compiler is still there on wake.
        finished += tracker.observe([swift(9, "Mactivity")], at: t0 + 8 * 3600, interval: 10)
        let run = try #require(finished.first)
        #expect(finished.count == 1)
        #expect(run.end == t0 + 55)
        // A clock set back ends it too.
        var back = BuildTracker()
        _ = back.observe([swift(9, "Mactivity")], at: t0, interval: 1)
        _ = back.observe([swift(9, "Mactivity")], at: t0 + 5, interval: 1)
        #expect(back.observe([swift(9, "Mactivity")], at: t0 - 3600, interval: 1).count == 1)
    }

    @Test("Compiles a second apart are one build; it ends after 20 seconds without a compiler")
    func oneBuild() throws {
        var tracker = BuildTracker()
        var finished: [BuildRun] = []
        for second in 0 ..< 30 {
            finished += tracker.observe(
                [swift(Int32(100 + second), "Mactivity"), swift(9, "Mactivity")],
                at: t0 + Double(second),
                interval: 1
            )
        }
        // A short gap inside the build, then the end.
        finished += tracker.observe([], at: t0 + 35, interval: 1)
        finished += tracker.observe([swift(500, "Mactivity")], at: t0 + 40, interval: 1)
        #expect(finished.isEmpty)
        finished += tracker.observe([], at: t0 + 61, interval: 1)
        let run = try #require(finished.first)
        #expect(finished.count == 1)
        #expect(run.project == "Mactivity" && run.tool == "Swift")
        #expect(run.start == t0 - 0.5 && run.end == t0 + 40.5)
        #expect(run.peakMemory == 600_000_000)
        #expect(abs(run.averageCPU - (50 * 2 * 30 + 50) / 31) < 0.01)
    }

    @Test("Two projects at once are two builds; a compiler with no folder joins the only one running")
    func projects() {
        var tracker = BuildTracker()
        for second in 0 ..< 10 {
            _ = tracker.observe([
                swift(1, "api"), CompilerProcess(pid: 2, name: "rustc", project: "engine", cpuPercent: 80, memory: 1),
            ], at: t0 + Double(second), interval: 1)
        }
        let runs = tracker.observe([], at: t0 + 40, interval: 1)
        #expect(runs.map(\.project).sorted() == ["api", "engine"])
        #expect(runs.first { $0.project == "engine" }?.tool == "Rust")
        var single = BuildTracker()
        for second in 0 ..< 10 {
            _ = single.observe([swift(1, "api"), swift(2, nil)], at: t0 + Double(second), interval: 1)
        }
        // A snapshot of only folderless compilers stays with the build already open.
        _ = single.observe([swift(3, nil)], at: t0 + 10, interval: 1)
        #expect(single.finishAll().map(\.project) == ["api"])
    }

    @Test("A blip under 3 seconds isn't a build; other processes aren't compilers")
    func blips() {
        var tracker = BuildTracker()
        _ = tracker.observe([swift(1, "api")], at: t0, interval: 1)
        _ = tracker.observe([swift(1, "api")], at: t0 + 1, interval: 1)
        #expect(tracker.observe([], at: t0 + 30, interval: 1).isEmpty, "two seconds")
        #expect(BuildTracker.family("node") == nil)
        #expect(BuildTracker.family("ld") == "C and C++")
        #expect(BuildTracker.family("compile") == "Go")
    }

    @Test("A project's median build this week beside the three weeks before: slower, faster, or not enough builds")
    func trend() {
        let now = t0 + 30 * 86400
        func run(daysAgo: Double, seconds: Double, project: String = "api") -> BuildRun {
            let start = now - daysAgo * 86400
            return BuildRun(start: start, end: start + seconds, project: project, tool: "Swift", averageCPU: 40, peakMemory: 1)
        }
        let slower = [
            run(daysAgo: 20, seconds: 60),
            run(daysAgo: 15, seconds: 62),
            run(daysAgo: 10, seconds: 58),
            run(daysAgo: 3, seconds: 95),
            run(daysAgo: 2, seconds: 100),
            run(daysAgo: 1, seconds: 90),
        ]
        let stats = BuildStats.byProject(slower, now: now)
        #expect(stats.count == 1)
        #expect(stats.first?.recentMedian == 95 && stats.first?.earlierMedian == 60)
        #expect(stats.first?.isSlower == true)
        let few = BuildStats.byProject([run(daysAgo: 1, seconds: 90, project: "web")], now: now)
        #expect(few.first?.recentMedian == nil && few.first?.isSlower == false)
        #expect(few.first?.last.duration == 90)
    }
}
