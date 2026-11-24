import Foundation

/// A watchdog for runaway dev processes (D-156): a node, python or test runner stuck at a full
/// core, or one whose memory keeps growing. Fed every snapshot; reports each process once. Pure.
///
/// Only dev runtimes by name are watched. Compilers and build tools are left out: a long build is
/// meant to be busy. A gap between snapshots (sleep) starts the clock again, so time asleep never
/// counts as time at full speed.
public struct RunawayWatch: Sendable {
    public enum Kind: Hashable, Sendable {
        /// At a full core or more for this many seconds.
        case stuck(seconds: TimeInterval)
        /// Its memory now, and how much it grew over the window.
        case leaking(bytes: UInt64, grewBy: UInt64)
    }

    public struct Finding: Hashable, Sendable {
        public let pid: Int32
        public let name: String
        public let app: AppIdentity.ID
        public let kind: Kind

        public init(pid: Int32, name: String, app: AppIdentity.ID, kind: Kind) {
            self.pid = pid
            self.name = name
            self.app = app
            self.kind = kind
        }
    }

    /// One core's worth, near enough: a spinning single-threaded process reads 95–100%.
    public static let fullCore = 0.9
    /// Growth over `leakWindow` that counts, and the least it must hold by then.
    public static let leakGrowth: UInt64 = 1_000_000_000
    public static let leakFloor: UInt64 = 2_000_000_000
    public static let leakWindow: TimeInterval = 30 * 60
    /// Longer between snapshots than this, and the clocks start again.
    static let maxGap: TimeInterval = 120

    /// Dev runtimes, by process name. `python3.13` and the like match by prefix.
    static let runtimes: Set<String> = [
        "node",
        "bun",
        "deno",
        "ruby",
        "java",
        "php",
        "beam.smp",
        "dotnet",
        "esbuild",
        "uvicorn",
        "gunicorn",
    ]
    static let runtimePrefixes = ["python", "Python"]

    private struct Key: Hashable {
        let pid: Int32
        let name: String
    }

    private var hotSince: [Key: Date] = [:]
    private var memory: [Key: [(at: Date, bytes: UInt64)]] = [:]
    private var reported: Set<Key> = []
    private var reportedLeaks: Set<Key> = []
    private var lastAt: Date?

    public init() {}

    public static func watches(_ name: String) -> Bool {
        runtimes.contains(name) || runtimePrefixes.contains { name.hasPrefix($0) }
    }

    /// New findings in this snapshot. `stuckAfter`: how long at a full core counts.
    public mutating func observe(_ snapshot: Snapshot, stuckAfter: TimeInterval) -> [Finding] {
        let now = snapshot.at
        if let lastAt, now.timeIntervalSince(lastAt) > Self.maxGap || now < lastAt {
            hotSince = [:]
            memory = [:]
        }
        lastAt = now
        let cores = Double(max(1, snapshot.system.cpu.perCorePercent.count))
        var seen = Set<Key>()
        var findings: [Finding] = []
        for process in snapshot.processes where Self.watches(process.name) {
            let key = Key(pid: process.pid, name: process.name)
            seen.insert(key)
            // CPU is a share of the whole Mac; one core is 100 / cores of it.
            if process.cpuPercent * cores / 100 >= Self.fullCore {
                let since = hotSince[key] ?? now
                hotSince[key] = since
                let seconds = now.timeIntervalSince(since)
                if seconds >= stuckAfter, reported.insert(key).inserted {
                    findings.append(Finding(pid: process.pid, name: process.name, app: process.app, kind: .stuck(seconds: seconds)))
                }
            } else {
                hotSince[key] = nil
            }
            if let finding = trackMemory(key, process: process, now: now) {
                findings.append(finding)
            }
        }
        // Gone processes: forget them, so a reused PID starts clean.
        hotSince = hotSince.filter { seen.contains($0.key) }
        memory = memory.filter { seen.contains($0.key) }
        reported = reported.filter { seen.contains($0) }
        reportedLeaks = reportedLeaks.filter { seen.contains($0) }
        return findings
    }

    /// One reading a minute per process, `leakWindow` of them; a leak is growth across the whole
    /// window to a new high, not a spike that came back down.
    private mutating func trackMemory(_ key: Key, process: ProcessSample, now: Date) -> Finding? {
        var readings = memory[key] ?? []
        if let last = readings.last, now.timeIntervalSince(last.at) < 60 {
            return nil
        }
        readings.append((now, process.footprintBytes))
        readings.removeAll { now.timeIntervalSince($0.at) > Self.leakWindow }
        memory[key] = readings
        guard let first = readings.first, now.timeIntervalSince(first.at) >= Self.leakWindow - 90,
              process.footprintBytes >= Self.leakFloor,
              process.footprintBytes >= first.bytes + Self.leakGrowth,
              readings.allSatisfy({ $0.bytes <= process.footprintBytes }),
              !reportedLeaks.contains(key) else {
            return nil
        }
        reportedLeaks.insert(key)
        return Finding(
            pid: process.pid, name: process.name, app: process.app,
            kind: .leaking(bytes: process.footprintBytes, grewBy: process.footprintBytes - first.bytes)
        )
    }
}

/// A finding with what the alert names: the app it belongs to, its project and the agent that
/// started it, when known.
public struct RunawayReport: Hashable, Sendable {
    public let finding: RunawayWatch.Finding
    public let app: AppIdentity
    public let project: String?
    public let agent: String?

    public init(finding: RunawayWatch.Finding, app: AppIdentity, project: String?, agent: String?) {
        self.finding = finding
        self.app = app
        self.project = project
        self.agent = agent
    }
}
