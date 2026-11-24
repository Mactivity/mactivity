import Foundation

/// AI coding agents (D-148): Claude Code, Codex and the rest, each session with everything it
/// started (shells, node, test runners), so "what is my agent doing to my Mac" has an answer.
public struct AgentSession: Hashable, Sendable, Identifiable {
    public var id: Int32 {
        pid
    }

    /// The agent's own process: the session's root.
    public let pid: Int32
    /// "Claude Code", "Codex"…
    public let agent: String
    /// The folder it works in, by name ("mactivity"), and its full path.
    public let project: String?
    public let directory: String?
    /// What it runs in: Terminal, iTerm, the Claude app, VS Code.
    public let host: String?
    public let startedAt: Date
    /// The root and every descendant still running.
    public let processCount: Int
    /// Percent of the whole Mac, like app rows.
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    /// The busiest child processes by name, for a line under the row ("node, swift-frontend").
    public let busiestChildren: [String]
    /// What Stop signals: the agent's own process group when it leads one (a terminal's job),
    /// else the agent and each process it started, one by one, never its host app or shell.
    public let stopTargets: [TerminationTarget]

    public init(
        pid: Int32, agent: String, project: String?, directory: String?, host: String?, startedAt: Date, processCount: Int,
        cpuPercent: Double, memoryBytes: UInt64, busiestChildren: [String], stopTargets: [TerminationTarget]
    ) {
        self.pid = pid
        self.agent = agent
        self.project = project
        self.directory = directory
        self.host = host
        self.startedAt = startedAt
        self.processCount = processCount
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.busiestChildren = busiestChildren
        self.stopTargets = stopTargets
    }
}

public protocol AgentSource: Sendable {
    /// Every agent session running now, busiest first.
    func sessions() async throws -> [AgentSession]
}

public enum AgentDetection {
    /// A process in the table: enough to build the tree.
    public struct Entry: Sendable {
        public let pid: Int32
        public let parentPID: Int32
        public let name: String
        public let path: String?
        public let arguments: [String]

        public init(pid: Int32, parentPID: Int32, name: String, path: String?, arguments: [String] = []) {
            self.pid = pid
            self.parentPID = parentPID
            self.name = name
            self.path = path
            self.arguments = arguments
        }
    }

    /// Agent CLIs by executable name. Node-based ones also run as `node …/<package>/…`.
    static let byName: [String: String] = [
        "claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI", "aider": "Aider", "cursor-agent": "Cursor Agent",
        "opencode": "opencode", "amp": "Amp", "goose": "Goose", "qwen": "Qwen Code", "crush": "Crush", "copilot": "Copilot CLI",
    ]
    static let byPackage: [(fragment: String, agent: String)] = [
        ("@anthropic-ai/claude-code", "Claude Code"), ("@openai/codex", "Codex"), ("@google/gemini-cli", "Gemini CLI"),
        ("@sourcegraph/amp", "Amp"), ("opencode-ai", "opencode"), ("@qwen-code", "Qwen Code"), ("@github/copilot", "Copilot CLI"),
    ]

    /// Pure: which agent a process is, or nil.
    public static func agent(_ entry: Entry) -> String? {
        // Exact names: the Claude app's executable is "Claude"; its Claude Code CLI, "claude"
        // (shipped as its own small claude.app).
        if let agent = byName[entry.name] {
            return agent
        }
        guard entry.name.hasPrefix("node") || entry.name == "bun" else {
            return nil
        }
        let words = ([entry.path ?? ""] + entry.arguments.prefix(3)).joined(separator: " ")
        return byPackage.first { words.contains($0.fragment) }?.agent
    }

    /// Pure: the sessions' roots (agent processes whose parent isn't the same agent, so a CLI
    /// that re-execs or forks itself counts once) and each one's descendants.
    public static func sessions(_ table: [Entry]) -> [(root: Entry, agent: String, descendants: [Entry])] {
        let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [Entry]] = [:]
        for entry in table {
            children[entry.parentPID, default: []].append(entry)
        }
        var found: [(root: Entry, agent: String, descendants: [Entry])] = []
        for entry in table {
            guard let agent = agent(entry) else {
                continue
            }
            if let parent = byPID[entry.parentPID], self.agent(parent) == agent {
                continue
            }
            var descendants: [Entry] = []
            var queue = children[entry.pid] ?? []
            while let next = queue.popLast(), descendants.count < 2000 {
                descendants.append(next)
                queue += children[next.pid] ?? []
            }
            found.append((entry, agent, descendants))
        }
        return found
    }

    /// The app the session runs in: the first ancestor inside an `.app`, by bundle name.
    public static func host(of pid: Int32, table: [Entry]) -> String? {
        let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var current = byPID[pid]?.parentPID
        for _ in 0 ..< 32 {
            guard let id = current, id > 1, let entry = byPID[id] else {
                return nil
            }
            if let path = entry.path, let range = path.range(of: ".app/") {
                let bundle = path[..<range.lowerBound]
                return bundle.split(separator: "/").last.map(String.init)
            }
            current = entry.parentPID
        }
        return nil
    }
}
