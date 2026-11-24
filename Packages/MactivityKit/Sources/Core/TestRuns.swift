import Foundation

// Test run times (D-278): `swift test`, `npm test`, `pytest` and `cargo test`, timed by project
// from their own processes, with no hook in any of them. Kept with builds (D-209) and judged by
// the same slower-or-faster rule.

/// How a test command ended, from its exit status.
public enum TestOutcome: String, Hashable, Sendable {
    case passed, failed, cancelled
    /// The exit wasn't seen: macOS refused to report it, or the process was gone first.
    case unknown

    /// What `wait` reports: the low 7 bits are the signal that ended it, the next 8 its exit code.
    public init(waitStatus status: Int32) {
        let signal = status & 0x7F
        let code = (status >> 8) & 0xFF
        switch signal {
        case 0:
            // 130 and 143: a wrapper reporting the signal that ended what it ran.
            self = code == 0 ? .passed : code == 130 || code == 143 ? .cancelled : .failed
        case SIGINT, SIGTERM, SIGKILL, SIGHUP, SIGQUIT:
            self = .cancelled
        default:
            self = .failed
        }
    }
}

/// What a process's arguments say it's doing.
public struct TestCommand: Hashable, Sendable {
    /// "swift test", "npm test", "pytest", "cargo test", "jest", "vitest".
    public let tool: String
    /// Told to run only some of the tests.
    public let isPartial: Bool
    /// Stays running and tests again on every save: not a run with an end.
    public let isWatching: Bool
    /// The project the arguments name, when they name one (`swift test --package-path`).
    public let directory: String?

    public init(tool: String, isPartial: Bool = false, isWatching: Bool = false, directory: String? = nil) {
        self.tool = tool
        self.isPartial = isPartial
        self.isWatching = isWatching
        self.directory = directory
    }
}

/// Pure: which processes are test commands, from their names and arguments.
public enum TestRunRules {
    /// Whether this process's arguments are worth reading, once. The only check every process
    /// gets on every snapshot, so a name comparison and nothing else.
    public static func needsArguments(name: String) -> Bool {
        switch name {
        // swift-test is a link to swift-package, and the kernel names a process after the file.
        case "swift-package", "swift-test", "cargo", "node", "npm", "yarn", "pnpm", "bun", "pytest", "Python":
            true
        default:
            name.hasPrefix("python")
        }
    }

    /// The test command a process is, or nil. `arguments` starts with argv[0].
    public static func command(name: String, arguments: [String]) -> TestCommand? {
        let words = expanded(arguments)
        switch name {
        case "swift-test": return swiftTest(words)
        // Also `swift package` and `swift build`: only its argv[0] says which.
        case "swift-package": return words.first.map(base) == "swift-test" ? swiftTest(words) : nil
        case "cargo": return cargoTest(words)
        case "pytest": return pytest(Array(words.dropFirst()))
        case "npm", "yarn", "pnpm", "bun": return packageManagerTest(tool: name, Array(words.dropFirst()))
        case "node":
            // After npm's title replaced them, argv[0] is "npm" and not node's own path.
            if words.first == "npm" {
                return packageManagerTest(tool: "npm", Array(words.dropFirst()))
            }
            return nodeTest(Array(words.dropFirst()))
        default:
            return name == "Python" || name.hasPrefix("python") ? pythonTest(Array(words.dropFirst())) : nil
        }
    }

    /// npm rewrites its own argv[0] to its title and blanks the rest: seen as
    /// ["npm test", "", ""]. Those are the arguments now.
    private static func expanded(_ arguments: [String]) -> [String] {
        guard let first = arguments.first, first.contains(" "), first.hasPrefix("npm ") else {
            return arguments
        }
        return first.split(separator: " ").map(String.init) + arguments.dropFirst().filter { !$0.isEmpty }
    }

    /// Whether a process running in `folder` is inside `parent`'s. Not known counts as inside: a
    /// worker that exited before its folder was read.
    public static func isInside(_ folder: String?, _ parent: String?) -> Bool {
        guard let folder, let parent else {
            return true
        }
        return folder == parent || folder.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private static func base(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }

    // MARK: swift test

    private static func swiftTest(_ words: [String]) -> TestCommand? {
        let options = Array(words.dropFirst())
        let notRuns: Set = ["list", "last", "--help", "-h", "--version", "--list-tests", "-l"]
        guard !options.contains(where: { notRuns.contains($0) }) else {
            return nil
        }
        let partial = options.contains { word in
            ["--filter", "--skip", "-s", "--specifier"].contains(word) || word.hasPrefix("--filter=") || word.hasPrefix("--skip=")
        }
        var directory: String?
        for (index, word) in options.enumerated() {
            if word == "--package-path", index + 1 < options.count {
                directory = options[index + 1]
            } else if word.hasPrefix("--package-path=") {
                directory = String(word.dropFirst("--package-path=".count))
            }
        }
        return TestCommand(tool: "swift test", isPartial: partial, directory: directory)
    }

    // MARK: cargo test

    /// Options that take a value, so the value isn't read as a test name.
    private static let cargoValueOptions: Set<String> = [
        "--features", "-F", "--manifest-path", "--target", "--profile", "-j", "--jobs", "--target-dir", "--color",
        "--message-format", "--config", "-Z", "--lockfile-path", "--timings",
    ]
    /// Options that pick which tests run.
    private static let cargoPartialOptions: Set<String> = [
        "-p", "--package", "--lib", "--bin", "--bins", "--test", "--tests", "--example", "--examples", "--bench", "--benches", "--doc",
    ]

    private static func cargoTest(_ words: [String]) -> TestCommand? {
        var rest = Array(words.dropFirst())
        // `cargo +nightly test`, `cargo --locked test`: the first word that isn't an option.
        while let first = rest.first, first.hasPrefix("-") || first.hasPrefix("+") {
            rest.removeFirst()
        }
        guard let subcommand = rest.first else {
            return nil
        }
        var options = Array(rest.dropFirst())
        switch subcommand {
        case "test", "t":
            break
        case "nextest":
            guard options.first == "run" else {
                return nil
            }
            options.removeFirst()
        default:
            return nil
        }
        // Compiles and doesn't run; after `--`, the options belong to the test binary.
        let beforeSeparator = options.prefix { $0 != "--" }
        guard !beforeSeparator.contains("--no-run") else {
            return nil
        }
        var partial = options.count > beforeSeparator.count + 1
        var skipNext = false
        for word in beforeSeparator {
            if skipNext {
                skipNext = false
            } else if cargoPartialOptions.contains(word) || word.hasPrefix("--package=") {
                partial = true
                skipNext = ["-p", "--package", "--bin", "--test", "--example", "--bench"].contains(word)
            } else if cargoValueOptions.contains(word) {
                skipNext = true
            } else if !word.hasPrefix("-") {
                partial = true
            }
        }
        return TestCommand(tool: "cargo test", isPartial: partial)
    }

    // MARK: pytest

    private static func pythonTest(_ arguments: [String]) -> TestCommand? {
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word == "-m" {
                return index + 1 < arguments.count && arguments[index + 1] == "pytest"
                    ? pytest(Array(arguments.dropFirst(index + 2)))
                    : nil
            }
            // -c runs a string, and the rest isn't a test command's.
            if word == "-c" {
                return nil
            }
            // The interpreter's own options; -X, -W take a value.
            if word.hasPrefix("-") {
                index += word == "-X" || word == "-W" ? 2 : 1
                continue
            }
            let script = base(word)
            return script == "pytest" || script == "py.test" ? pytest(Array(arguments.dropFirst(index + 1))) : nil
        }
        return nil
    }

    private static func pytest(_ options: [String]) -> TestCommand? {
        let notRuns: Set = ["--version", "-V", "--help", "-h", "--collect-only", "--co", "--fixtures", "--markers"]
        guard !options.contains(where: { notRuns.contains($0) }) else {
            return nil
        }
        let picks: Set = ["-k", "-m", "--lf", "--last-failed", "--ff", "--failed-first", "--sw", "--stepwise"]
        let valueOptions: Set = [
            "-c", "-o", "-n", "-p", "-r", "--rootdir", "--tb", "--maxfail", "--cov", "--cov-report", "--confcutdir", "--basetemp",
            "--durations",
        ]
        var partial = false
        var skipNext = false
        for word in options {
            if skipNext {
                skipNext = false
            } else if picks.contains(word) {
                partial = true
            } else if valueOptions.contains(word) {
                skipNext = true
            } else if !word.hasPrefix("-"),
                      // A folder of tests is still the suite's shape; one file or one test isn't.
                      word.contains("::") || word.hasSuffix(".py") {
                partial = true
            }
        }
        return TestCommand(tool: "pytest", isPartial: partial)
    }

    // MARK: npm test, jest, vitest

    /// `npm test`, `npm t`, `npm run test`, `npm run test:unit`, `yarn test`, `pnpm test`, `bun test`.
    private static func packageManagerTest(tool: String, _ words: [String]) -> TestCommand? {
        var rest = words.drop { $0.hasPrefix("-") }
        guard let first = rest.first else {
            return nil
        }
        rest = rest.dropFirst()
        var script = first
        if first == "run" || first == "run-script" {
            guard let named = rest.first(where: { !$0.hasPrefix("-") }) else {
                return nil
            }
            script = named
            rest = rest.drop { $0 != named }.dropFirst()
        }
        let isTest = script == "test" || script == "tst" || (tool == "npm" && script == "t")
            || script.hasPrefix("test:") || script.hasPrefix("test-")
        guard isTest else {
            return nil
        }
        // "test:unit" is a part of the suite; `npm test -- one.test.js` or `yarn test one` too.
        let picksTests = script != "test" && script != "t" && script != "tst"
        let partial = picksTests || rest.contains { !$0.hasPrefix("-") }
        let watching = rest.contains("--watch") || rest.contains("--watchAll") || script.contains("watch")
        return TestCommand(tool: tool + " test", isPartial: partial, isWatching: watching)
    }

    /// node running npm, yarn or pnpm's script, or jest or vitest directly.
    private static func nodeTest(_ arguments: [String]) -> TestCommand? {
        // Node's own options, then the script.
        guard let scriptIndex = arguments.firstIndex(where: { !$0.hasPrefix("-") }) else {
            return nil
        }
        let script = arguments[scriptIndex]
        let name = base(script)
        let options = Array(arguments.dropFirst(scriptIndex + 1))
        switch name {
        case "npm", "npm-cli.js": return packageManagerTest(tool: "npm", options)
        case "yarn", "yarn.js", "yarn.cjs": return packageManagerTest(tool: "yarn", options)
        case "pnpm", "pnpm.cjs": return packageManagerTest(tool: "pnpm", options)
        case "jest", "jest.js": return jest(options)
        case "vitest", "vitest.mjs": return vitest(options)
        default: return nil
        }
    }

    private static let jestPicks = [
        "-t", "--testNamePattern", "--testPathPattern", "--findRelatedTests", "--onlyChanged", "-o", "--onlyFailures", "-f",
    ]
    private static let jestNotRuns: Set<String> = ["--version", "--help", "-h", "--listTests", "--showConfig", "--init"]

    private static func jest(_ options: [String]) -> TestCommand? {
        guard !options.contains(where: { jestNotRuns.contains($0) }) else {
            return nil
        }
        let watching = options.contains { $0 == "--watch" || $0 == "--watchAll" || $0 == "-w" }
        return TestCommand(tool: "jest", isPartial: picksTests(options), isWatching: watching)
    }

    /// Vitest watches unless told `run`, and exits by itself only then.
    private static func vitest(_ options: [String]) -> TestCommand? {
        guard !options.contains(where: { jestNotRuns.contains($0) || $0 == "list" }) else {
            return nil
        }
        let runs = options.contains("run") || options.contains("--run")
        let rest = options.filter { $0 != "run" && $0 != "--run" }
        return TestCommand(tool: "vitest", isPartial: picksTests(rest), isWatching: !runs || options.contains("--watch"))
    }

    private static func picksTests(_ options: [String]) -> Bool {
        options.contains { word in
            jestPicks.contains(word) || jestPicks.contains { word.hasPrefix($0 + "=") } || !word.hasPrefix("-")
        }
    }
}

/// A test command's top process in one snapshot: what it runs under it (`sh`, jest, workers) is
/// part of the run.
public struct TestProcess: Hashable, Sendable {
    public let pid: Int32
    /// The kernel's, so the time is right however late Mactivity first saw it.
    public let startedAt: Date
    public let tool: String
    public let project: String
    public let isPartial: Bool
    public let isWatching: Bool

    public init(pid: Int32, startedAt: Date, tool: String, project: String, isPartial: Bool = false, isWatching: Bool = false) {
        self.pid = pid
        self.startedAt = startedAt
        self.tool = tool
        self.project = project
        self.isPartial = isPartial
        self.isWatching = isWatching
    }
}

/// A process's exit, as the kernel reported it.
public struct ProcessExit: Hashable, Sendable {
    public let at: Date
    /// As `wait` reports it; nil when macOS gave the time but not the status.
    public let waitStatus: Int32?

    public init(at: Date, waitStatus: Int32?) {
        self.at = at
        self.waitStatus = waitStatus
    }
}

/// Turns each snapshot's test processes and the exits since the last one into finished runs.
/// Pure. Unlike a build, which is many short compilers, a test run is one process: it starts when
/// the kernel says, and ends when it exits.
public struct TestRunTracker: Sendable {
    /// Shorter isn't a suite anyone waits for.
    public static let minimumDuration: TimeInterval = 1

    private struct Key: Hashable {
        let pid: Int32
        let startedAt: Date
    }

    private struct Open {
        var process: TestProcess
        var lastSeen: Date
        var tail: TimeInterval
    }

    private var open: [Key: Open] = [:]
    /// Ended, but maybe still in a snapshot taken before the exit: not a new run.
    private var ended = Set<Key>()
    private var lastTick: Date?

    public init() {}

    public mutating func observe(_ running: [TestProcess], exits: [Int32: ProcessExit], at: Date, interval: TimeInterval) -> [BuildRun] {
        // No snapshot for a while: the Mac slept or the clock jumped, and a run across that isn't
        // its length. Its start is the kernel's, so it can't be saved the way a build is.
        if let lastTick, at.timeIntervalSince(lastTick) > max(BuildTracker.gap, interval * 3) || at < lastTick {
            ended.formUnion(open.keys)
            open = [:]
        }
        lastTick = at
        let keys = Set(running.map { Key(pid: $0.pid, startedAt: $0.startedAt) })
        ended = ended.intersection(keys)
        for process in running {
            let key = Key(pid: process.pid, startedAt: process.startedAt)
            guard !ended.contains(key) else {
                continue
            }
            open[key] = Open(process: process, lastSeen: at, tail: interval / 2)
        }
        var finished: [BuildRun] = []
        for (key, run) in open {
            let exit = exits[key.pid]
            guard !keys.contains(key) || exit != nil else {
                continue
            }
            open[key] = nil
            ended.insert(key)
            if let result = Self.run(run, exit: exit) {
                finished.append(result)
            }
        }
        // A run still open past the limit isn't a suite: something waiting on input, or a `npm
        // test` that starts a watcher.
        for (key, run) in open where at.timeIntervalSince(run.process.startedAt) > BuildTracker.maximumDuration {
            open[key] = nil
            ended.insert(key)
        }
        return finished.sorted { $0.start < $1.start }
    }

    private static func run(_ run: Open, exit: ProcessExit?) -> BuildRun? {
        let process = run.process
        // Without the exit, half a snapshot after it was last seen: the fair guess, as for builds.
        let end = exit?.at ?? run.lastSeen.addingTimeInterval(run.tail)
        let duration = end.timeIntervalSince(process.startedAt)
        guard !process.isWatching, duration >= minimumDuration, duration <= BuildTracker.maximumDuration else {
            return nil
        }
        // Not its processor or memory: only its top process is known here, not its workers.
        return BuildRun(
            kind: .test, start: process.startedAt, end: end, project: process.project, tool: process.tool, averageCPU: 0, peakMemory: 0,
            outcome: exit?.waitStatus.map(TestOutcome.init(waitStatus:)) ?? .unknown, isPartial: process.isPartial
        )
    }
}

public enum TestStats {
    /// Each project and tool with test runs, the most recently run first. One row per tool: a
    /// project's `swift test` and its `npm test` aren't the same suite. The same slower-or-faster
    /// rule as builds, over the whole runs that finished.
    public static func byProject(_ runs: [BuildRun], now: Date) -> [ProjectBuilds] {
        Dictionary(grouping: runs, by: \.tool).values
            .flatMap { BuildStats.byProject($0, now: now) }
            .sorted { $0.last.start > $1.last.start }
    }
}
