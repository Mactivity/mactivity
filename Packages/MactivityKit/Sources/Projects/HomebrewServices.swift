import Core
import Darwin
import Foundation

/// Homebrew services (1.4, D-225): what `brew services` starts (the `homebrew.mxcl.*` launchd
/// plists), whether each is running, what it holds, and the command that stops it, for the user
/// to run. Stopping its process wouldn't do: launchd starts a `KeepAlive` service again.
public struct HomebrewService: Sendable, Hashable, Identifiable {
    /// "postgresql@16".
    public let formula: String
    public let plistPath: String
    /// In /Library/LaunchDaemons: started with `sudo brew services`, runs as root.
    public let asRoot: Bool
    /// The service's processes: the one launchd started and the ones it started.
    public let pids: [Int32]
    public let memoryBytes: UInt64
    /// Processor time its processes used since they started.
    public let cpuSeconds: Double
    public let startedAt: Date?
    public let ports: [UInt16]
    /// The executable's name: History records it as "other:<name>".
    public let executableName: String
    /// Its figures could be read: a root service's can't without the helper.
    public let isReadable: Bool

    public var id: String {
        plistPath
    }

    public var isRunning: Bool {
        !pids.isEmpty
    }

    public var stopCommand: String {
        asRoot ? "sudo brew services stop \(formula)" : "brew services stop \(formula)"
    }

    public init(
        formula: String, plistPath: String, asRoot: Bool, pids: [Int32] = [], memoryBytes: UInt64 = 0, cpuSeconds: Double = 0,
        startedAt: Date? = nil, ports: [UInt16] = [], executableName: String, isReadable: Bool = true
    ) {
        self.isReadable = isReadable
        self.formula = formula
        self.plistPath = plistPath
        self.asRoot = asRoot
        self.pids = pids
        self.memoryBytes = memoryBytes
        self.cpuSeconds = cpuSeconds
        self.startedAt = startedAt
        self.ports = ports
        self.executableName = executableName
    }

    /// Percent of one core, on average since it started.
    public func averageCPU(now: Date) -> Double? {
        guard let startedAt, now.timeIntervalSince(startedAt) >= 60 else {
            return nil
        }
        return cpuSeconds / now.timeIntervalSince(startedAt) * 100
    }
}

/// The services `brew services` started. Live reads launchd's plists and the process table;
/// Simulated has a fixed set.
public protocol HomebrewServiceSource: Sendable {
    func services() async -> [HomebrewService]
}

/// Pure rules, with the file system and process table passed in.
public enum HomebrewServiceRules {
    static let labelPrefix = "homebrew.mxcl."

    /// "homebrew.mxcl.postgresql@16.plist" → "postgresql@16".
    public static func formula(plistName: String) -> String? {
        guard plistName.hasPrefix(labelPrefix), plistName.hasSuffix(".plist") else {
            return nil
        }
        let name = String(plistName.dropFirst(labelPrefix.count).dropLast(".plist".count))
        return name.isEmpty ? nil : name
    }

    /// A process of the service: run from its keg, and started by launchd or by one of the
    /// service's own processes. A `psql` you run in Terminal comes from the same keg, but its
    /// parent is your shell.
    public struct Process: Sendable, Hashable {
        public let pid: Int32
        public let parentPID: Int32
        public let name: String
        public let executable: String
        /// Read only for launchd's children under a Homebrew prefix.
        public let arguments: [String]

        public init(pid: Int32, parentPID: Int32, name: String = "", executable: String, arguments: [String] = []) {
            self.pid = pid
            self.parentPID = parentPID
            self.name = name
            self.executable = executable
            self.arguments = arguments
        }
    }

    /// The service's processes: launchd's children that run from its keg, or that another
    /// formula's program runs for it (Jenkins and Kafka run openjdk's `java` on a jar in their
    /// keg; a wrapper script names it), and everything those start (D-225).
    public static func processes(inKeg keg: String, opt: String? = nil, among table: [Process]) -> [Int32] {
        let marks = [keg + "/"] + (opt.map { [$0 + "/"] } ?? [])
        let roots = table.filter { process in
            process.parentPID == 1
                &&
                (process.executable.hasPrefix(keg + "/") || process.arguments.dropFirst().contains { arg in
                    marks.contains { arg.contains($0) }
                })
        }
        return DevDeviceRules.descendants(of: roots.map(\.pid), in: table.map { ($0.pid, $0.parentPID) })
    }

    /// The name History knows the service by: its busiest process's (mysqld, not the
    /// mysqld_safe script that started it), or the plist program's.
    public static func historyName(pids: [Int32], table: [Process], program: String?, formula: String) -> String {
        if let first = pids.first, let name = table.first(where: { $0.pid == first })?.name, !name.isEmpty {
            return name
        }
        return program.map { ($0 as NSString).lastPathComponent } ?? formula
    }

    /// Not busy for two weeks: the newest hour History saw it use 1% of a core or more is that
    /// long ago, or there's none in at least that much history.
    public static let quietAfter: TimeInterval = 14 * 86400

    /// The newest hour at 1% of a core or more, from the service's History series.
    public static func lastBusy(_ points: [SeriesPoint]) -> Date? {
        points.last { $0.average >= 1 }?.at
    }
}

public struct LiveHomebrewServices: HomebrewServiceSource {
    private let home: String
    /// Homebrew's prefixes: Apple silicon's, then Intel's (still found on migrated Macs).
    static let prefixes = ["/opt/homebrew", "/usr/local"]
    static let shells: Set<String> = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/usr/bin/env"]

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public func services() async -> [HomebrewService] {
        let home = home
        return await Task.detached(priority: .utility) { Self.read(home: home) }.value
    }

    static func read(home: String) -> [HomebrewService] {
        let folders = [(home + "/Library/LaunchAgents", false), ("/Library/LaunchDaemons", true)]
        let plists = folders.flatMap { folder, asRoot in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .compactMap { name in HomebrewServiceRules.formula(plistName: name).map { (folder + "/" + name, $0, asRoot) } }
        }
        guard !plists.isEmpty else {
            return []
        }
        let table = processTable()
        return plists.map { path, formula, asRoot in
            let program = Self.program(path)
            let keg = Self.keg(formula: formula, program: program)
            let opt = prefixes.map { $0 + "/opt/" + formula }.first { FileManager.default.fileExists(atPath: $0) }
            var busiest: (pid: Int32, cpu: Double)?
            let pids = keg.map { HomebrewServiceRules.processes(inKeg: $0, opt: opt, among: table) } ?? []
            var memory: UInt64 = 0
            var cpu = 0.0
            var readable = pids.isEmpty
            var started: Date?
            var ports = Set<UInt16>()
            for pid in pids {
                if let usage = ProcessInspector.usage(pid) {
                    memory &+= usage.footprint
                    cpu += usage.cpu.seconds
                    readable = true
                    if usage.cpu.seconds > busiest?.cpu ?? -1 {
                        busiest = (pid, usage.cpu.seconds)
                    }
                }
                if let start = ProcessInspector.basics(pid)?.startedAt {
                    started = min(started ?? start, start)
                }
                ports.formUnion(ProcessInspector.listeningPorts(pid).map(\.port))
            }
            return HomebrewService(
                formula: formula, plistPath: path, asRoot: asRoot, pids: pids, memoryBytes: memory, cpuSeconds: cpu,
                startedAt: started, ports: ports.sorted(),
                executableName: HomebrewServiceRules.historyName(
                    pids: busiest.map { [$0.pid] } ?? pids, table: table, program: program, formula: formula
                ),
                isReadable: readable
            )
        }
        .sorted { ($0.isRunning ? 0 : 1, $0.formula) < ($1.isRunning ? 0 : 1, $1.formula) }
    }

    /// The plist's program: `Program`, else the first of `ProgramArguments`.
    static func program(_ plistPath: String) -> String? {
        guard let plist = NSDictionary(contentsOfFile: plistPath) else {
            return nil
        }
        return plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
    }

    /// The formula's folder in the Cellar, every installed version under it, where its
    /// processes run from: /opt/homebrew/opt/postgresql@16 resolves into
    /// /opt/homebrew/Cellar/postgresql@16/16.4, and a service still running 16.3 after an
    /// upgrade counts too. The prefix the plist's program names comes first.
    static func keg(formula: String, program: String?) -> String? {
        let ordered = prefixes.sorted { left, _ in program?.hasPrefix(left + "/") == true }
        for prefix in ordered {
            let opt = prefix + "/opt/" + formula
            if FileManager.default.fileExists(atPath: opt) {
                return ((opt as NSString).resolvingSymlinksInPath as NSString).deletingLastPathComponent
            }
        }
        // A program outside opt/ (a cask, a tap's odd layout): its own folder.
        return program.map { (($0 as NSString).resolvingSymlinksInPath as NSString).deletingLastPathComponent }
    }

    static func processTable() -> [HomebrewServiceRules.Process] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: max(capacity, 64))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else {
            return []
        }
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 1, let identity = ProcessInspector.identity(pid), let path = ProcessInspector.executablePath(pid) else {
                return nil
            }
            // Arguments only where a service may hide in them: launchd's children run from Homebrew,
            // or a shell running a formula's script (MySQL's mysqld_safe).
            let underBrew = identity.parentPID == 1 && (prefixes.contains { path.hasPrefix($0 + "/") } || shells.contains(path))
            return HomebrewServiceRules.Process(
                pid: pid, parentPID: identity.parentPID, name: identity.name, executable: path,
                arguments: underBrew ? ProcessInspector.arguments(pid) : []
            )
        }
    }
}

public struct SimulatedHomebrewServices: HomebrewServiceSource {
    private let now: Date

    public init(now: Date = Date()) {
        self.now = now
    }

    public func services() async -> [HomebrewService] {
        let agents = "/Users/demo/Library/LaunchAgents/homebrew.mxcl."
        return [
            HomebrewService(
                formula: "postgresql@16", plistPath: agents + "postgresql@16.plist", asRoot: false, pids: [812, 830, 831, 832],
                memoryBytes: 96_000_000, cpuSeconds: 410, startedAt: now.addingTimeInterval(-19 * 86400), ports: [5432],
                executableName: "postgres"
            ),
            HomebrewService(
                formula: "redis", plistPath: agents + "redis.plist", asRoot: false, pids: [815], memoryBytes: 12_000_000,
                cpuSeconds: 95, startedAt: now.addingTimeInterval(-19 * 86400), ports: [6379], executableName: "redis-server"
            ),
            HomebrewService(
                formula: "ollama", plistPath: agents + "ollama.plist", asRoot: false, pids: [902], memoryBytes: 5_400_000_000,
                cpuSeconds: 2600, startedAt: now.addingTimeInterval(-2 * 86400), ports: [11434], executableName: "ollama"
            ),
            HomebrewService(
                formula: "nginx", plistPath: "/Library/LaunchDaemons/homebrew.mxcl.nginx.plist", asRoot: true, executableName: "nginx"
            ),
        ]
    }
}
