import Core
import Foundation

/// Pure rules for turning a listening process into a project (spec 6.12). No I/O: the file
/// system comes in as a closure so fixtures can stand in for it.
public enum ProjectDetection {
    /// Files or folders that mark a project root (spec 6.12).
    public static let rootMarkers = [
        "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Gemfile", "pom.xml", "deno.json", ".git",
    ]

    /// Homebrew's own checkouts: `brew services` (Postgres, Redis, MySQL, Ollama) run from inside
    /// them, and with its `.git` the prefix read as a project called "homebrew", whose quiet
    /// databases Stop Idle would stop (D-145).
    static let toolPrefixes = ["/opt/homebrew", "/usr/local/Homebrew", "/home/linuxbrew/.linuxbrew"]

    /// Walks up from `directory` to the nearest folder containing a marker. Never returns `/`, the
    /// home folder itself (a dotfiles `.git` in `~` isn't a project), or anything in Homebrew.
    ///
    /// - Returns: the root and the markers found in it.
    public static func projectRoot(
        from directory: String,
        home: String,
        exists: (String) -> Bool
    ) -> (root: String, markers: Set<String>)? {
        var current = normalized(directory)
        let home = normalized(home)
        if toolPrefixes.contains(where: { current == $0 || current.hasPrefix($0 + "/") }) {
            return nil
        }
        while current != "/", current != home, !current.isEmpty {
            let markers = Set(rootMarkers.filter { exists(current + "/" + $0) })
            if !markers.isEmpty {
                return (current, markers)
            }
            current = parent(of: current)
        }
        return nil
    }

    /// Executable-name prefixes of interpreters, checked in order ("python3.13" → python).
    static let interpreterPrefixes: [(prefix: String, runtime: DevRuntime)] = [
        ("node", .node), ("bun", .bun), ("deno", .deno), ("python", .python), ("ruby", .ruby), ("java", .java),
    ]

    /// The runtime from the executable, its arguments, and the project's markers (spec 5.5).
    public static func runtime(
        executablePath: String?,
        name: String,
        arguments: [String],
        root: String,
        markers: Set<String>
    ) -> DevRuntime {
        let executable = (executablePath ?? name).split(separator: "/").last.map(String.init) ?? name
        let lower = executable.lowercased()
        if let match = interpreterPrefixes.first(where: { lower.hasPrefix($0.prefix) }) {
            return match.runtime
        }
        let path = executablePath ?? ""
        if path.contains("/target/debug/") || path.contains("/target/release/") {
            return .rust
        }
        if path.contains("/go-build") {
            return .go
        }
        // A compiled binary inside the project folder takes the project's language.
        if path.hasPrefix(root + "/") {
            if markers.contains("go.mod") {
                return .go
            }
            if markers.contains("Cargo.toml") {
                return .rust
            }
        }
        return .other
    }

    /// Spec 6.12: up ≥ 24 h with under 60 s of CPU in total is "barely used"; otherwise no CPU for
    /// 15 minutes is "idle N min".
    public static func activity(lastActiveAt: Date, startedAt: Date, cpuTime: Duration, now: Date) -> ProjectActivity {
        if now.timeIntervalSince(startedAt) >= 24 * 3600, cpuTime < .seconds(60) {
            return .barelyUsed
        }
        let idle = now.timeIntervalSince(lastActiveAt)
        if idle >= 15 * 60 {
            return .idle(minutes: Int(idle / 60))
        }
        return .working
    }

    /// Groups servers by project root, busiest first: working projects, then by memory.
    public static func projects(_ servers: [(server: DevServer, root: String)]) -> [Project] {
        Dictionary(grouping: servers, by: \.root)
            .map { root, entries in
                Project(
                    rootPath: root,
                    name: root.split(separator: "/").last.map(String.init) ?? root,
                    servers: entries.map(\.server).sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
                )
            }
            .sorted { lhs, rhs in
                if (lhs.activity == .working) != (rhs.activity == .working) {
                    return lhs.activity == .working
                }
                if lhs.memoryBytes != rhs.memoryBytes {
                    return lhs.memoryBytes > rhs.memoryBytes
                }
                return lhs.name < rhs.name
            }
    }

    /// Whether stopping the whole process group is safe: the group must be the server's own job,
    /// not a shell's, an app's, an editor's, or ours (spec 6.12 says "SIGTERM to the process group").
    ///
    /// An allowlist (D-145): `chain` runs from the group leader down to the listening process.
    /// The group is the job only when the leader is the server itself, or every process above the
    /// server is a known runner (npm, node, make…). A denylist of shells let Stop kill Neovim, a
    /// Python REPL or PowerShell that started a server in their own group, with SIGKILL after 5 s.
    public static func groupIsStoppable(
        processGroupID: Int32,
        ownProcessGroupID: Int32,
        chain: [(name: String, path: String?)]
    ) -> Bool {
        guard processGroupID > 1, processGroupID != ownProcessGroupID, let leader = chain.first, chain.count <= 8 else {
            return false
        }
        func isRunner(_ process: (name: String, path: String?), leading: Bool) -> Bool {
            if let path = process.path, path.contains(".app/") {
                return false
            }
            // `sh -c` from an npm script is fine in the middle, never as the group's leader.
            if !leading, process.name == "sh" {
                return true
            }
            return runners.contains(process.name) || process.name.hasPrefix("python3.")
        }
        if chain.count == 1 {
            // The server leads its own group: stop the group, unless it's a shell or an app.
            return !shells.contains(leader.name) && !leader.name.hasPrefix("-") && !(leader.path?.contains(".app/") ?? false)
        }
        return chain.dropLast().enumerated().allSatisfy { index, process in isRunner(process, leading: index == 0) }
    }

    /// Processes that run a dev server for you and stop with it: package managers, runtimes,
    /// watchers, task runners, Procfile managers.
    static let runners: Set<String> = [
        "npm", "npx", "pnpm", "pnpx", "yarn", "bun", "bunx", "deno", "node", "nodemon", "tsx", "ts-node", "turbo", "nx",
        "concurrently", "vite", "next", "make", "gmake", "env", "python", "python3", "uv", "poetry", "pipenv",
        "ruby", "bundle", "rails", "foreman", "overmind", "honcho", "go", "air", "cargo", "cargo-watch", "watchexec",
        "mix", "beam.smp", "java", "gradle", "mvn", "dotnet", "php", "wrangler", "netlify", "vercel",
    ]

    /// Login shells show as "-zsh".
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "login", "tmux", "screen"]

    /// `KERN_PROCARGS2`: argc (Int32), the executable path, NUL padding, then argc NUL-terminated
    /// arguments, then the environment (ignored).
    public static func parseProcArgs(_ data: [UInt8]) -> (executable: String, arguments: [String])? {
        guard data.count >= 4 else {
            return nil
        }
        let argc = Int(Int32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        var index = 4
        func nextString() -> String? {
            let start = index
            while index < data.count, data[index] != 0 {
                index += 1
            }
            guard index <= data.count else {
                return nil
            }
            return String(bytes: data[start ..< index], encoding: .utf8)
        }
        guard let executable = nextString() else {
            return nil
        }
        while index < data.count, data[index] == 0 {
            index += 1
        }
        var arguments: [String] = []
        while arguments.count < argc, index < data.count {
            guard let argument = nextString() else {
                break
            }
            arguments.append(argument)
            index += 1
        }
        return (executable, arguments)
    }

    /// A readable command line: the executable's name then the arguments, home abbreviated.
    public static func commandLine(_ arguments: [String], home: String) -> String {
        guard let first = arguments.first else {
            return ""
        }
        let name = first.split(separator: "/").last.map(String.init) ?? first
        return ([name] + arguments.dropFirst())
            .map { Formatters.displayPath($0, home: home) }
            .joined(separator: " ")
    }

    private static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else {
            return "/"
        }
        let parent = String(path[..<slash])
        return parent.isEmpty ? "/" : parent
    }
}

/// When each process last used CPU, fed by snapshots so "idle 42 min" survives the Projects tab
/// being closed. Pure value type.
public struct ActivityTracker: Sendable {
    /// One core's percent below which a tick counts as idle.
    public static let activeThreshold = 0.2

    private(set) var lastActive: [Int32: Date] = [:]

    public init() {}

    public mutating func observe(_ snapshot: Snapshot) {
        observe(snapshot.processes, at: snapshot.at, coreCount: snapshot.system.cpu.perCorePercent.count)
    }

    /// Only the processes that could be dev servers; the macOS row's thousand never are.
    public mutating func observe(_ processes: [ProcessSample], at date: Date, coreCount: Int) {
        let cores = Double(max(1, coreCount))
        for process in processes where lastActive[process.pid] == nil || process.cpuPercent * cores >= Self.activeThreshold {
            lastActive[process.pid] = date
        }
        if lastActive.count > processes.count * 2 {
            let seen = Set(processes.map(\.pid))
            lastActive = lastActive.filter { seen.contains($0.key) }
        }
    }

    /// The most recent activity among `pids`; nil if none has been seen.
    public func lastActive(among pids: [Int32]) -> Date? {
        pids.compactMap { lastActive[$0] }.max()
    }
}
