import Foundation

// Dev servers grouped by project (spec 5.5, 6.12).

public enum DevRuntime: String, CaseIterable, Hashable, Sendable, Codable {
    case node, python, go, ruby, java, bun, deno, rust, other

    /// Runtime product names, verbatim; only "Other" is translated.
    public var title: String {
        switch self {
        case .node: "Node"
        case .python: "Python"
        case .go: "Go"
        case .ruby: "Ruby"
        case .java: "Java"
        case .bun: "Bun"
        case .deno: "Deno"
        case .rust: "Rust"
        case .other: String(localized: "Other", bundle: .strings, comment: "A dev server's runtime that isn't one Mactivity knows.")
        }
    }
}

/// Working / idle N min / barely used (spec 5.5, 6.12, 7.3).
public enum ProjectActivity: Hashable, Sendable, Codable {
    /// Used CPU in the last 15 minutes.
    case working
    /// No CPU for at least 15 minutes.
    case idle(minutes: Int)
    /// Up at least a day with under a minute of CPU time in total.
    case barelyUsed

    public var isIdle: Bool {
        self != .working
    }

    public var title: String {
        switch self {
        case .working:
            String(localized: "Working", bundle: .strings, comment: "A dev server that used CPU in the last 15 minutes.")
        case let .idle(minutes):
            String(
                localized: "Idle \(Formatters.duration(.seconds(minutes * 60)))", bundle: .strings,
                comment: "A dev server with no CPU use for a while. The argument is a short duration, e.g. 2h 5m."
            )
        case .barelyUsed:
            String(localized: "Barely used", bundle: .strings, comment: "A dev server up for a day or more with almost no CPU time.")
        }

    }

    /// The menu bar window's narrower column: one unit, "Idle 3h" for 3h 10m, "Idle 2d" for 2d 4h.
    public var shortTitle: String {
        guard case let .idle(minutes) = self else {
            return title
        }
        let whole = minutes >= 1440 ? minutes / 1440 * 1440 : minutes >= 60 ? minutes / 60 * 60 : minutes
        return ProjectActivity.idle(minutes: whole).title
    }
}

/// One process that holds at least one listening TCP port.
public struct DevServer: Hashable, Sendable, Identifiable {
    public let pid: Int32
    public let name: String
    /// The command line, e.g. "node node_modules/.bin/vite --port 4321".
    public let command: String
    public let runtime: DevRuntime
    public let ports: [UInt16]
    /// Footprint of everything `stopTarget` would stop.
    public let memoryBytes: UInt64
    public let startedAt: Date
    /// Total CPU time since it started.
    public let cpuTime: Duration
    public let activity: ProjectActivity
    /// What "Stop" signals: the process group when it's the server's own, else just the PID.
    public let stopTarget: TerminationTarget

    public var id: Int32 {
        pid
    }

    public init(
        pid: Int32, name: String, command: String, runtime: DevRuntime, ports: [UInt16], memoryBytes: UInt64,
        startedAt: Date, cpuTime: Duration, activity: ProjectActivity, stopTarget: TerminationTarget
    ) {
        self.pid = pid
        self.name = name
        self.command = command
        self.runtime = runtime
        self.ports = ports
        self.memoryBytes = memoryBytes
        self.startedAt = startedAt
        self.cpuTime = cpuTime
        self.activity = activity
        self.stopTarget = stopTarget
    }
}

/// Dev servers that share a project root.
public struct Project: Hashable, Sendable, Identifiable {
    /// The project root's path.
    public let id: String
    /// The root folder's name.
    public let name: String
    public let servers: [DevServer]

    public init(rootPath: String, name: String, servers: [DevServer]) {
        id = rootPath
        self.name = name
        self.servers = servers
    }

    public var rootPath: String {
        id
    }

    /// The runtime most servers use; ties go to the first.
    public var runtime: DevRuntime {
        let counts = Dictionary(grouping: servers, by: \.runtime).mapValues(\.count)
        return servers.map(\.runtime).max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .other
    }

    public var ports: [UInt16] {
        Array(Set(servers.flatMap(\.ports))).sorted()
    }

    public var memoryBytes: UInt64 {
        servers.reduce(0) { $0 + $1.memoryBytes }
    }

    public var startedAt: Date {
        servers.map(\.startedAt).min() ?? .distantPast
    }

    /// Working if any server works; barely used if all are; otherwise idle for the shortest idle time.
    public var activity: ProjectActivity {
        if servers.contains(where: { $0.activity == .working }) {
            return .working
        }
        let idle = servers.compactMap { server -> Int? in
            if case let .idle(minutes) = server.activity {
                return minutes
            }
            return nil
        }
        if let minutes = idle.min() {
            return .idle(minutes: minutes)
        }
        return servers.isEmpty ? .working : .barelyUsed
    }
}

public protocol ProjectSource: Sendable {
    /// Every project with at least one listening dev server, busiest first.
    func projects() async throws -> [Project]
}
