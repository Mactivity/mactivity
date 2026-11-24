@testable import Core
import Foundation
import Testing

/// Test run times (D-278). The argument fixtures marked "seen" are what `ps` showed on this Mac
/// during real `swift test` and `npm test` runs.
struct TestRunsTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Which processes

    @Test("swift test, as seen, and what isn't a run")
    func swiftTest() throws {
        // Seen: the path is argv[0], the rest its options.
        let path = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-test"
        // Seen: its name in the process table is the file the link points to.
        #expect(TestRunRules.command(name: "swift-package", arguments: [path])?.tool == "swift test")
        #expect(TestRunRules
            .command(name: "swift-package", arguments: [path.replacingOccurrences(of: "swift-test", with: "swift-build")]) == nil)
        #expect(TestRunRules.command(
            name: "swift-package",
            arguments: [path.replacingOccurrences(of: "swift-test", with: "swift-package"), "init"]
        ) == nil)
        #expect(TestRunRules.command(name: "swift-package", arguments: []) == nil)
        let plain = try #require(TestRunRules.command(name: "swift-test", arguments: [path]))
        #expect(plain.tool == "swift test" && !plain.isPartial && !plain.isWatching)
        #expect(try #require(TestRunRules.command(name: "swift-test", arguments: [path, "--disable-xctest"])).isPartial == false)
        #expect(try #require(TestRunRules.command(name: "swift-test", arguments: [path, "--filter", "SSH"])).isPartial)
        #expect(try #require(TestRunRules.command(name: "swift-test", arguments: [path, "--filter=SSH"])).isPartial)
        #expect(try #require(TestRunRules.command(name: "swift-test", arguments: [path, "--skip", "RenderTests"])).isPartial)
        for words in [["list"], ["--help"], ["--version"], ["--list-tests"]] {
            #expect(TestRunRules.command(name: "swift-test", arguments: [path] + words) == nil)
        }
    }

    @Test("swift test --package-path names the project's folder")
    func packagePath() {
        #expect(TestRunRules.command(name: "swift-test", arguments: ["swift-test", "--package-path", "Packages/Kit"])?
            .directory == "Packages/Kit")
        #expect(TestRunRules.command(name: "swift-test", arguments: ["swift-test", "--package-path=/a/b"])?.directory == "/a/b")
        #expect(TestRunRules.command(name: "swift-test", arguments: ["swift-test"])?.directory == nil)
    }

    @Test("npm test, seen before and after npm rewrites its own title")
    func npmTest() throws {
        let before = try #require(TestRunRules.command(name: "node", arguments: ["node", "/opt/homebrew/bin/npm", "test"]))
        #expect(before.tool == "npm test" && !before.isPartial)
        let after = try #require(TestRunRules.command(name: "node", arguments: ["npm test", "", ""]))
        #expect(after.tool == "npm test" && !after.isPartial)
        // Seen running beside it: not tests.
        #expect(TestRunRules.command(name: "node", arguments: ["npm run dev", "", ""]) == nil)
        #expect(TestRunRules.command(name: "node", arguments: ["npm exec vite dev", "", ""]) == nil)
        #expect(TestRunRules.command(name: "node", arguments: ["npm run lang", "", ""]) == nil)
        #expect(TestRunRules.command(name: "node", arguments: ["node", "t.js"]) == nil)
    }

    @Test("npm's other spellings")
    func npmSpellings() {
        let npm = ["node", "/opt/homebrew/bin/npm"]
        #expect(TestRunRules.command(name: "node", arguments: npm + ["t"])?.tool == "npm test")
        #expect(TestRunRules.command(name: "node", arguments: npm + ["run", "test"])?.isPartial == false)
        #expect(TestRunRules.command(name: "node", arguments: npm + ["run", "test:unit"])?.isPartial == true)
        #expect(TestRunRules.command(name: "node", arguments: npm + ["test", "--", "one.test.js"])?.isPartial == true)
        #expect(TestRunRules.command(name: "node", arguments: npm + ["test", "--silent"])?.isPartial == false)
        #expect(TestRunRules.command(name: "node", arguments: npm + ["run", "test:watch"])?.isWatching == true)
        #expect(TestRunRules.command(name: "node", arguments: npm + ["install"]) == nil)
        #expect(TestRunRules.command(name: "node", arguments: npm + ["run", "testing"]) == nil)
        #expect(TestRunRules.command(name: "node", arguments: npm) == nil)
        #expect(TestRunRules.command(name: "node", arguments: ["node", "/x/yarn.js", "test"])?.tool == "yarn test")
        #expect(TestRunRules.command(name: "node", arguments: ["node", "/x/pnpm.cjs", "test"])?.tool == "pnpm test")
        #expect(TestRunRules.command(name: "bun", arguments: ["bun", "test"])?.tool == "bun test")
        #expect(TestRunRules.command(name: "bun", arguments: ["bun", "run", "dev"]) == nil)
    }

    @Test("jest and vitest directly: a run, a watcher, or a worker")
    func jestAndVitest() {
        let jest = "node_modules/.bin/jest"
        #expect(TestRunRules.command(name: "node", arguments: ["node", jest])?.tool == "jest")
        #expect(TestRunRules.command(name: "node", arguments: ["node", jest, "--watch"])?.isWatching == true)
        #expect(TestRunRules.command(name: "node", arguments: ["node", jest, "one.test.js"])?.isPartial == true)
        #expect(TestRunRules.command(name: "node", arguments: ["node", jest, "-t", "adds"])?.isPartial == true)
        #expect(TestRunRules.command(name: "node", arguments: ["node", jest, "--ci"])?.isPartial == false)
        #expect(TestRunRules.command(name: "node", arguments: ["node", jest, "--listTests"]) == nil)
        // A worker is part of the run above it.
        #expect(TestRunRules.command(name: "node", arguments: ["node", "/x/node_modules/jest-worker/build/processChild.js"]) == nil)
        let vitest = "/x/node_modules/vitest/vitest.mjs"
        #expect(TestRunRules.command(name: "node", arguments: ["node", vitest])?.isWatching == true)
        #expect(TestRunRules.command(name: "node", arguments: ["node", vitest, "run"])?.isWatching == false)
        #expect(TestRunRules.command(name: "node", arguments: ["node", vitest, "run"])?.isPartial == false)
        #expect(TestRunRules.command(name: "node", arguments: ["node", vitest, "run", "one"])?.isPartial == true)
    }

    @Test("pytest, by its script, by -m, and under each of Python's names")
    func pytest() {
        #expect(TestRunRules.command(name: "python3.12", arguments: ["python3.12", "-m", "pytest"])?.tool == "pytest")
        #expect(TestRunRules.command(name: "Python", arguments: ["/usr/bin/python3", "/x/.venv/bin/pytest"])?.tool == "pytest")
        #expect(TestRunRules.command(name: "python3", arguments: ["python3", "-u", "-X", "dev", "-m", "pytest", "-q"])?.isPartial == false)
        #expect(TestRunRules.command(name: "python3", arguments: ["python3", "-m", "pytest", "tests/"])?.isPartial == false)
        #expect(TestRunRules.command(name: "python3", arguments: ["python3", "-m", "pytest", "tests/test_a.py"])?.isPartial == true)
        #expect(TestRunRules.command(name: "python3", arguments: ["python3", "-m", "pytest", "tests/a.py::test_b"])?.isPartial == true)
        #expect(TestRunRules.command(name: "python3", arguments: ["python3", "-m", "pytest", "-k", "adds"])?.isPartial == true)
        #expect(TestRunRules.command(name: "python3", arguments: ["python3", "-m", "pytest", "--lf"])?.isPartial == true)
        #expect(TestRunRules.command(name: "python3", arguments: ["python3", "-m", "pytest", "-n", "4"])?.isPartial == false)
        #expect(TestRunRules.command(name: "python3", arguments: ["python3", "-m", "pytest", "--collect-only"]) == nil)
        #expect(TestRunRules.command(name: "python3", arguments: ["python3", "-m", "http.server"]) == nil)
        #expect(TestRunRules.command(name: "python3", arguments: ["python3", "-c", "import pytest"]) == nil)
        #expect(TestRunRules.command(name: "python3", arguments: ["python3", "app.py", "pytest"]) == nil)
        #expect(TestRunRules.command(name: "pytest", arguments: ["pytest"])?.tool == "pytest")
    }

    @Test("cargo test and what else cargo does")
    func cargoTest() {
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "test"])?.tool == "cargo test")
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "t"])?.isPartial == false)
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "+nightly", "test"])?.tool == "cargo test")
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "nextest", "run"])?.tool == "cargo test")
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "test", "adds"])?.isPartial == true)
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "test", "-p", "core"])?.isPartial == true)
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "test", "--features", "x"])?.isPartial == false)
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "test", "--release"])?.isPartial == false)
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "test", "--", "adds"])?.isPartial == true)
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "test", "--no-run"]) == nil)
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "build"]) == nil)
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "run", "test"]) == nil)
        #expect(TestRunRules.command(name: "cargo", arguments: ["cargo", "nextest", "list"]) == nil)
        #expect(TestRunRules.command(name: "cargo", arguments: []) == nil)
    }

    @Test("A test run under another is part of it only inside its folder")
    func nesting() {
        #expect(TestRunRules.isInside("/p/web", "/p/web"))
        #expect(TestRunRules.isInside("/p/web/packages/a", "/p/web"))
        #expect(!TestRunRules.isInside("/p/web2", "/p/web"))
        #expect(!TestRunRules.isInside("/tmp/x", "/p/web"))
        #expect(TestRunRules.isInside(nil, "/p/web"))
        #expect(TestRunRules.isInside("/p/web", nil))
    }

    @Test("Only the names worth an argument read get one")
    func names() {
        for name in ["swift-package", "swift-test", "cargo", "node", "npm", "python3", "python3.12", "Python", "pytest", "bun"] {
            #expect(TestRunRules.needsArguments(name: name))
        }
        for name in ["swift-frontend", "Safari", "zsh", "rustc", "nodemon", ""] {
            #expect(!TestRunRules.needsArguments(name: name))
        }
    }

    // MARK: How it ended

    @Test("An exit status: passed, failed or cancelled")
    func outcomes() {
        #expect(TestOutcome(waitStatus: 0) == .passed)
        #expect(TestOutcome(waitStatus: 1 << 8) == .failed)
        // cargo test's failure code; pytest's.
        #expect(TestOutcome(waitStatus: 101 << 8) == .failed)
        #expect(TestOutcome(waitStatus: 2 << 8) == .failed)
        #expect(TestOutcome(waitStatus: 130 << 8) == .cancelled)
        #expect(TestOutcome(waitStatus: 143 << 8) == .cancelled)
        #expect(TestOutcome(waitStatus: SIGINT) == .cancelled)
        #expect(TestOutcome(waitStatus: SIGTERM) == .cancelled)
        #expect(TestOutcome(waitStatus: SIGKILL) == .cancelled)
        #expect(TestOutcome(waitStatus: SIGSEGV) == .failed)
        #expect(TestOutcome(waitStatus: SIGABRT) == .failed)
    }

    // MARK: The tracker

    private func process(
        _ pid: Int32 = 9,
        start: Date? = nil,
        tool: String = "swift test",
        partial: Bool = false,
        watching: Bool = false
    ) -> TestProcess {
        TestProcess(pid: pid, startedAt: start ?? t0, tool: tool, project: "Kit", isPartial: partial, isWatching: watching)
    }

    @Test("A run is the process's life: the kernel's start, its exit, and its status")
    func wholeRun() throws {
        var tracker = TestRunTracker()
        #expect(tracker.observe([process()], exits: [:], at: t0 + 10, interval: 10).isEmpty)
        #expect(tracker.observe([process()], exits: [:], at: t0 + 20, interval: 10).isEmpty)
        let done = tracker.observe([], exits: [9: ProcessExit(at: t0 + 24, waitStatus: 0)], at: t0 + 30, interval: 10)
        let run = try #require(done.first)
        #expect(done.count == 1)
        #expect(run.start == t0 && run.end == t0 + 24 && run.duration == 24)
        #expect(run.kind == .test && run.tool == "swift test" && run.project == "Kit")
        #expect(run.outcome == .passed && run.isTimed)
    }

    @Test("Seen once at a 10-second tick still counts, from its real start")
    func seenOnce() throws {
        var tracker = TestRunTracker()
        _ = tracker.observe([process()], exits: [:], at: t0 + 6, interval: 10)
        let run = try #require(tracker.observe([], exits: [9: ProcessExit(at: t0 + 8, waitStatus: 0)], at: t0 + 16, interval: 10).first)
        #expect(run.duration == 8)
    }

    @Test("Failed and cancelled runs are kept as such and don't count towards the time")
    func failedAndCancelled() {
        var tracker = TestRunTracker()
        _ = tracker.observe([process(1), process(2)], exits: [:], at: t0 + 2, interval: 1)
        let done = tracker.observe(
            [], exits: [1: ProcessExit(at: t0 + 3, waitStatus: 1 << 8), 2: ProcessExit(at: t0 + 3, waitStatus: SIGINT)], at: t0 + 4,
            interval: 1
        )
        #expect(Set(done.compactMap(\.outcome)) == [.failed, .cancelled])
        #expect(done.allSatisfy { !$0.isTimed })
    }

    @Test("With no exit event, it ends half a tick after it was last seen, outcome unknown")
    func noExitEvent() throws {
        var tracker = TestRunTracker()
        _ = tracker.observe([process()], exits: [:], at: t0 + 10, interval: 10)
        let run = try #require(tracker.observe([], exits: [:], at: t0 + 20, interval: 10).first)
        #expect(run.end == t0 + 15 && run.outcome == .unknown && run.isTimed)
    }

    @Test("A snapshot from before the exit doesn't start the run again")
    func staleSnapshot() {
        var tracker = TestRunTracker()
        _ = tracker.observe([process()], exits: [:], at: t0 + 5, interval: 1)
        // The exit arrived while the snapshot that still lists it was on its way.
        #expect(tracker.observe([process()], exits: [9: ProcessExit(at: t0 + 6, waitStatus: 0)], at: t0 + 6, interval: 1).count == 1)
        #expect(tracker.observe([process()], exits: [:], at: t0 + 7, interval: 1).isEmpty)
        #expect(tracker.observe([], exits: [:], at: t0 + 8, interval: 1).isEmpty)
    }

    @Test("A process reusing a PID is a new run")
    func reusedPID() {
        var tracker = TestRunTracker()
        _ = tracker.observe([process()], exits: [:], at: t0 + 5, interval: 1)
        let done = tracker.observe([process(start: t0 + 100)], exits: [:], at: t0 + 6, interval: 1)
        #expect(done.first?.start == t0)
        let next = tracker.observe([], exits: [9: ProcessExit(at: t0 + 110, waitStatus: 0)], at: t0 + 7, interval: 1)
        #expect(next.first?.start == t0 + 100)
    }

    @Test("A sleep or a clock jump mid-run keeps no run: it wouldn't be the run's length")
    func sleepMidRun() {
        var tracker = TestRunTracker()
        _ = tracker.observe([process()], exits: [:], at: t0 + 5, interval: 10)
        #expect(tracker.observe([process()], exits: [:], at: t0 + 8 * 3600, interval: 10).isEmpty)
        #expect(tracker.observe([], exits: [9: ProcessExit(at: t0 + 8 * 3600 + 5, waitStatus: 0)], at: t0 + 8 * 3600 + 10, interval: 10)
            .isEmpty)
        var back = TestRunTracker()
        _ = back.observe([process()], exits: [:], at: t0 + 5, interval: 1)
        #expect(back.observe([], exits: [:], at: t0 - 3600, interval: 1).isEmpty)
    }

    @Test("A watcher, a run past two hours, and a blink aren't kept")
    func dropped() {
        var watcher = TestRunTracker()
        _ = watcher.observe([process(watching: true)], exits: [:], at: t0 + 60, interval: 1)
        #expect(watcher.observe([], exits: [9: ProcessExit(at: t0 + 61, waitStatus: 0)], at: t0 + 62, interval: 1).isEmpty)
        var long = TestRunTracker()
        _ = long.observe([process()], exits: [:], at: t0 + 3 * 3600, interval: 1)
        _ = long.observe([process()], exits: [:], at: t0 + 3 * 3600 + 1, interval: 1)
        #expect(long.observe([], exits: [9: ProcessExit(at: t0 + 3 * 3600 + 2, waitStatus: 0)], at: t0 + 3 * 3600 + 2, interval: 1).isEmpty)
        var blink = TestRunTracker()
        _ = blink.observe([process()], exits: [:], at: t0 + 0.2, interval: 1)
        #expect(blink.observe([], exits: [9: ProcessExit(at: t0 + 0.5, waitStatus: 0)], at: t0 + 1, interval: 1).isEmpty)
    }

    @Test("A partial run is marked, and an exit for something never seen is ignored")
    func partialAndStrangers() throws {
        var tracker = TestRunTracker()
        _ = tracker.observe([process(partial: true)], exits: [77: ProcessExit(at: t0, waitStatus: 0)], at: t0 + 5, interval: 1)
        let run = try #require(tracker.observe([], exits: [9: ProcessExit(at: t0 + 6, waitStatus: 0)], at: t0 + 6, interval: 1).first)
        #expect(run.isPartial && !run.isTimed)
    }

    // MARK: The figures

    private func run(
        daysAgo: Double, seconds: TimeInterval, tool: String = "swift test", outcome: TestOutcome = .passed, partial: Bool = false,
        now: Date
    ) -> BuildRun {
        let start = now.addingTimeInterval(-daysAgo * 86400)
        return BuildRun(
            kind: .test, start: start, end: start + seconds, project: "Kit", tool: tool, averageCPU: 0, peakMemory: 0, outcome: outcome,
            isPartial: partial
        )
    }

    @Test("Slower by the same rule as builds; failures and filters can't fake a fast week or a slow one")
    func slower() throws {
        let now = t0
        var runs = [10.0, 11, 12].map { run(daysAgo: $0, seconds: 100, now: now) }
        runs += [1.0, 2, 3].map { run(daysAgo: $0, seconds: 140, now: now) }
        // Quick failures, cancels and `--filter` runs this week, which the median must not see.
        runs += (0 ..< 9).map { run(daysAgo: 0.5 + Double($0) * 0.1, seconds: 2, outcome: .failed, now: now) }
        runs += (0 ..< 9).map { run(daysAgo: 0.5 + Double($0) * 0.1, seconds: 3, outcome: .cancelled, now: now) }
        runs += (0 ..< 9).map { run(daysAgo: 0.5 + Double($0) * 0.1, seconds: 1, partial: true, now: now) }
        let project = try #require(TestStats.byProject(runs, now: now).first)
        #expect(project.recentMedian == 140 && project.earlierMedian == 100)
        #expect(project.isSlower)
        #expect(project.count == 6)
    }

    @Test("A run of failures isn't read as getting faster")
    func notFaster() throws {
        let now = t0
        var runs = [10.0, 11, 12].map { run(daysAgo: $0, seconds: 100, now: now) }
        runs += [1.0, 2, 3].map { run(daysAgo: $0, seconds: 5, outcome: .failed, now: now) }
        let project = try #require(TestStats.byProject(runs, now: now).first)
        #expect(!project.isFaster && project.recentMedian == nil)
        // The last run shown is still the failure, marked as one.
        #expect(project.last.outcome == .failed)
    }

    @Test("Only filtered runs so far: shown, as that, and with no median")
    func onlyPartial() throws {
        let now = t0
        let runs = [1.0, 2, 3].map { run(daysAgo: $0, seconds: 9, partial: true, now: now) }
        let project = try #require(TestStats.byProject(runs, now: now).first)
        #expect(project.last.isPartial && project.count < 1 && project.recentMedian == nil)
    }

    @Test("The last run shown is the last whole one, not a later --filter")
    func lastWhole() throws {
        let now = t0
        let runs = [run(daysAgo: 2, seconds: 100, now: now), run(daysAgo: 1, seconds: 2, partial: true, now: now)]
        #expect(try #require(TestStats.byProject(runs, now: now).first).last.duration == 100)
    }

    @Test("A project's two test commands are two rows, never one median")
    func twoTools() {
        let now = t0
        let runs = [
            run(daysAgo: 1, seconds: 100, tool: "swift test", now: now), run(daysAgo: 2, seconds: 5, tool: "npm test", now: now),
        ]
        let projects = TestStats.byProject(runs, now: now)
        #expect(projects.map(\.tool) == ["swift test", "npm test"])
        #expect(Set(projects.map(\.id)).count == 2)
    }
}
