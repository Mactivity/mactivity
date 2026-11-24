import Foundation

// Build times (D-209): every compile, timed by project, from the compiler processes each snapshot
// sees. No hook in Xcode, cargo or go: just their processes, by name, and the folder they run in.

/// One build: compiler processes running in a project, with no gap longer than
/// `BuildTracker.gap` between them.
public struct BuildRun: Hashable, Sendable, Identifiable {
    /// A compile, or a test command's whole run (D-278).
    public enum Kind: String, Hashable, Sendable {
        case build, test
    }

    public let kind: Kind
    public let start: Date
    public let end: Date
    /// The project folder's name; empty when no compiler's folder was known.
    public let project: String
    /// "Swift", "Rust", "Go", "C and C++"…: the family that ran longest.
    public let tool: String
    /// Average processor share of the whole Mac while it ran, all its compilers together.
    public let averageCPU: Double
    /// The most memory its compilers held together at any one snapshot.
    public let peakMemory: UInt64
    /// How a test run ended; nil for a build.
    public let outcome: TestOutcome?
    /// A test run told to run only some tests (`--filter`, `-k`): never compared with whole runs.
    public let isPartial: Bool

    public init(
        kind: Kind = .build, start: Date, end: Date, project: String, tool: String, averageCPU: Double, peakMemory: UInt64,
        outcome: TestOutcome? = nil, isPartial: Bool = false
    ) {
        self.kind = kind
        self.outcome = outcome
        self.isPartial = isPartial
        self.start = start
        self.end = end
        self.project = project
        self.tool = tool
        self.averageCPU = averageCPU
        self.peakMemory = peakMemory
    }

    public var id: String {
        "\(start.timeIntervalSince1970)\u{1F}\(project)"
    }

    public var duration: TimeInterval {
        end.timeIntervalSince(start)
    }

    /// Counts towards how long this usually takes: a test run that failed or was cancelled may
    /// have stopped early, and one told to run a few tests isn't the project's suite.
    public var isTimed: Bool {
        !isPartial && outcome != .failed && outcome != .cancelled
    }
}

public protocol BuildHistoryStore: Sendable {
    func recordBuildRun(_ run: BuildRun) async throws
    /// Builds that started in the span, oldest first.
    func buildRuns(from: Date, to: Date) async throws -> [BuildRun]
    /// Test runs that started in the span, oldest first (D-278).
    func testRuns(from: Date, to: Date) async throws -> [BuildRun]
}

/// A compiler process in one snapshot, with the project it runs in.
public struct CompilerProcess: Hashable, Sendable {
    public let pid: Int32
    public let name: String
    public let project: String?
    public let cpuPercent: Double
    public let memory: UInt64

    public init(pid: Int32, name: String, project: String?, cpuPercent: Double, memory: UInt64) {
        self.pid = pid
        self.name = name
        self.project = project
        self.cpuPercent = cpuPercent
        self.memory = memory
    }
}

/// Turns each snapshot's compiler processes into finished builds. Pure.
public struct BuildTracker: Sendable {
    /// No compiler for this long ends a build: Xcode's steps leave short gaps between compiles.
    public static let gap: TimeInterval = 20
    /// Shorter builds aren't kept: a single file's check, not a build anyone waits for.
    public static let minimumDuration: TimeInterval = 3
    /// Longer than this, it isn't a build but something left running (a watcher, a service): dropped.
    public static let maximumDuration: TimeInterval = 2 * 3600

    /// The family a compiler process belongs to; nil for anything else.
    public static func family(_ name: String) -> String? {
        switch name {
        // xcodebuild runs from a build's start to its end, asset and interface compiles included,
        // so a command-line build is timed whole. Not cargo or go: `cargo run` and `go run` stay
        // running as long as the program they started.
        case "swift-frontend", "swiftc", "swift-driver", "swift-build", "xcodebuild", "actool", "ibtool": "Swift"
        case "rustc": "Rust"
        // Go's toolchain runs its compiler as a process named `compile`.
        case "compile": "Go"
        case "clang", "clang++", "cc", "c++", "gcc", "g++", "cc1", "cc1plus", "ld", "ld64": "C and C++"
        case "javac", "kotlinc": "Java and Kotlin"
        // Not esbuild: Vite's dev server keeps an esbuild service running all session, which
        // would read as one endless build.
        case "zig": "Zig"
        default: nil
        }
    }

    private struct Open {
        var start: Date
        var lastSeen: Date
        /// Half the snapshot interval when last seen: the build ran on about that long.
        var tail: TimeInterval = 0
        var snapshots = 0
        var cpuTotal = 0.0
        var peakMemory: UInt64 = 0
        var familyTime: [String: Double] = [:]
    }

    private var open: [String: Open] = [:]

    public init() {}

    /// The builds that finished by `at`: a project with no compiler for `gap`. `interval` is the
    /// snapshot's: a build is taken to start half an interval before it was first seen and end
    /// half an interval after it was last seen, the fair guess either way (1 s apart with a
    /// window open, 10 s without).
    public mutating func observe(_ compilers: [CompilerProcess], at: Date, interval: TimeInterval) -> [BuildRun] {
        // A compiler with no known folder (it exited before its folder was read) joins the only
        // build this snapshot or still open, or counts as unknown.
        let known = Set(compilers.compactMap(\.project))
        let fallback = known.count == 1 ? known.first : (known.isEmpty && open.count == 1 ? open.keys.first : nil)
        // No snapshot for longer than a build may pause: the Mac slept, or the clock jumped. A
        // build ends where it was last seen, and one still compiling after wake starts again, so
        // a lid closed mid-build doesn't count the night as build time (D-221).
        var finished: [BuildRun] = []
        for (project, build) in open where at.timeIntervalSince(build.lastSeen) > Self.gap || at < build.lastSeen {
            open[project] = nil
            if let run = Self.run(project, build) {
                finished.append(run)
            }
        }
        var byProject: [String: [CompilerProcess]] = [:]
        for compiler in compilers {
            byProject[compiler.project ?? fallback ?? "", default: []].append(compiler)
        }
        for (project, running) in byProject {
            var build = open[project] ?? Open(start: at.addingTimeInterval(-min(interval, Self.gap) / 2), lastSeen: at)
            build.lastSeen = at
            build.tail = min(interval, Self.gap) / 2
            build.snapshots += 1
            build.cpuTotal += running.reduce(0) { $0 + $1.cpuPercent }
            build.peakMemory = max(build.peakMemory, running.reduce(0) { $0 + $1.memory })
            for compiler in running {
                if let family = Self.family(compiler.name) {
                    build.familyTime[family, default: 0] += max(compiler.cpuPercent, 0.01)
                }
            }
            open[project] = build
        }
        for (project, build) in open where at.timeIntervalSince(build.start) > Self.maximumDuration {
            open[project] = nil
        }
        for (project, build) in open where byProject[project] == nil && at.timeIntervalSince(build.lastSeen) > Self.gap {
            open[project] = nil
            if let run = Self.run(project, build) {
                finished.append(run)
            }
        }
        return finished.sorted { $0.start < $1.start }
    }

    /// Every build still open, ended now: when the app quits.
    public mutating func finishAll() -> [BuildRun] {
        let runs = open.compactMap { Self.run($0.key, $0.value) }
        open = [:]
        return runs.sorted { $0.start < $1.start }
    }

    private static func run(_ project: String, _ build: Open) -> BuildRun? {
        let end = build.lastSeen.addingTimeInterval(build.tail)
        // Seen at least twice: one sighting is padded to a whole interval either side, so at 10 s
        // apart any stray clang (pip, Homebrew, an indexer) would pass the minimum.
        guard build.snapshots >= 2, end.timeIntervalSince(build.start) >= minimumDuration else {
            return nil
        }
        let tool = build.familyTime.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? "Swift"
        return BuildRun(
            start: build.start, end: end, project: project, tool: tool,
            averageCPU: build.cpuTotal / Double(max(1, build.snapshots)), peakMemory: build.peakMemory
        )
    }
}

/// Each project's builds, and whether they've got slower (D-209). Pure.
public struct ProjectBuilds: Hashable, Sendable, Identifiable {
    public let project: String
    public let tool: String
    public let count: Int
    public let last: BuildRun
    /// The median build in the last 7 days, and in the 3 weeks before; nil without 3 builds in each.
    public let recentMedian: TimeInterval?
    public let earlierMedian: TimeInterval?

    public init(project: String, tool: String, count: Int, last: BuildRun, recentMedian: TimeInterval?, earlierMedian: TimeInterval?) {
        self.project = project
        self.tool = tool
        self.count = count
        self.last = last
        self.recentMedian = recentMedian
        self.earlierMedian = earlierMedian
    }

    public var id: String {
        "\(project)\u{1F}\(tool)"
    }

    /// Slower by a quarter or more, and by 10 seconds or more.
    public var isSlower: Bool {
        guard let recentMedian, let earlierMedian else {
            return false
        }
        return recentMedian >= earlierMedian * 1.25 && recentMedian - earlierMedian >= 10
    }

    public var isFaster: Bool {
        guard let recentMedian, let earlierMedian else {
            return false
        }
        return recentMedian <= earlierMedian * 0.8 && earlierMedian - recentMedian >= 10
    }
}

public enum BuildStats {
    static let minimumBuilds = 3

    /// Each project with builds in `runs`, the most recently built first.
    public static func byProject(_ runs: [BuildRun], now: Date) -> [ProjectBuilds] {
        let recentStart = now.addingTimeInterval(-7 * 86400)
        let earlierStart = now.addingTimeInterval(-28 * 86400)
        return Dictionary(grouping: runs, by: \.project).compactMap { project, runs in
            // The last whole run, not the last `--filter` of one test, while there is one.
            let whole = runs.filter { !$0.isPartial }
            guard let last = (whole.isEmpty ? runs : whole).max(by: { $0.start < $1.start }) else {
                return nil
            }
            let timed = runs.filter(\.isTimed)
            let recent = timed.filter { $0.start >= recentStart }.map(\.duration)
            let earlier = timed.filter { $0.start >= earlierStart && $0.start < recentStart }.map(\.duration)
            let tools = Dictionary(grouping: runs, by: \.tool)
            let tool = tools.max { $0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key > $1.key) }?.key ?? last
                .tool
            return ProjectBuilds(
                project: project, tool: tool, count: timed.count, last: last,
                recentMedian: recent.count >= minimumBuilds ? Baselines.median(recent) : nil,
                earlierMedian: earlier.count >= minimumBuilds ? Baselines.median(earlier) : nil
            )
        }
        .sorted { $0.last.start > $1.last.start }
    }
}
