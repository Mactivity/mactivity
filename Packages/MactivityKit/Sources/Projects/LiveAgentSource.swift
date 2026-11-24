import Core
import Darwin
import Foundation

/// The running AI agent sessions (D-148), read while the Agents tab shows, and once a minute
/// for agent history (D-192) by a second instance of its own: the process table,
/// then usage for each session's processes only. CPU is the change in CPU time since the last
/// read, as a share of the whole Mac.
public actor LiveAgentSource: AgentSource {
    /// Suspending, so a read after wake isn't divided by the night (as D-142 for the sampler).
    /// CPU by PID and start, so a PID reused since isn't read as the old process.
    private var previous: (at: SuspendingClock.Instant, wall: Date, cpu: [Int32: (started: UInt64, cpu: Duration)])?
    private let ownGroup = getpgrp()
    private let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    public init() {}

    public func sessions() async throws -> [AgentSession] {
        let table = Self.table()
        let found = AgentDetection.sessions(table)
        let now = SuspendingClock.now
        let elapsed = previous.map { (now - $0.at).seconds } ?? 0
        let before = previous?.cpu ?? [:]
        var cpuNow: [Int32: (started: UInt64, cpu: Duration)] = [:]
        var sessions: [AgentSession] = []
        for (root, agent, descendants) in found {
            var memory: UInt64 = 0
            var cpuPercent = 0.0
            var childLoad: [(name: String, cpu: Double)] = []
            for entry in [root] + descendants {
                guard let usage = ProcessInspector.usage(entry.pid) else {
                    continue
                }
                memory += usage.footprint
                cpuNow[entry.pid] = (usage.started, usage.cpu)
                // A process started since the last read (a build, a test run the agent began)
                // counts all its time; one already running, what it used since (D-219).
                let seen = before[entry.pid].flatMap { $0.started == usage.started ? $0.cpu : nil }
                let then = seen ?? (Self.startedSince(entry.pid, previous?.wall) ? .zero : nil)
                if elapsed > 0, let then, usage.cpu >= then {
                    let share = (usage.cpu - then).seconds / elapsed / cores * 100
                    cpuPercent += share
                    if entry.pid != root.pid {
                        childLoad.append((entry.name, share))
                    }
                }
            }
            let directory = ProcessInspector.workingDirectory(root.pid)
            let started = ProcessInspector.basics(root.pid)?.startedAt ?? Date()
            var names: [String] = []
            for child in childLoad.sorted(by: { $0.cpu > $1.cpu }) where child.cpu > 0.05 && !names.contains(child.name) {
                names.append(child.name)
            }
            sessions.append(AgentSession(
                pid: root.pid, agent: agent, project: directory.map(Self.projectName), directory: directory,
                host: AgentDetection.host(of: root.pid, table: table), startedAt: started,
                processCount: descendants.count + 1, cpuPercent: cpuPercent, memoryBytes: memory,
                busiestChildren: Array(names.prefix(3)), stopTargets: stopTargets(root, descendants: descendants)
            ))
        }
        previous = (now, Date(), cpuNow)
        return sessions.sorted { ($0.cpuPercent, $0.memoryBytes) > ($1.cpuPercent, $1.memoryBytes) }
    }

    /// Whether `pid` started after `date`.
    static func startedSince(_ pid: Int32, _ date: Date?) -> Bool {
        guard let date, let started = ProcessInspector.basics(pid)?.startedAt else {
            return false
        }
        return started >= date
    }

    /// The project's folder name: the nearest root with a marker, else the folder itself. A
    /// coding agent's worktree (`…/api/.claude/worktrees/agent-a1b2…`) is its project's, not a
    /// project named after the agent run.
    static func projectName(_ directory: String) -> String {
        if let worktrees = directory.range(of: "/.claude/worktrees/") {
            return projectName(String(directory[..<worktrees.lowerBound]))
        }
        let home = NSHomeDirectory()
        let root = ProjectDetection.projectRoot(from: directory, home: home) { FileManager.default.fileExists(atPath: $0) }?.root
        return ((root ?? directory) as NSString).lastPathComponent
    }

    /// The agent and everything it started: its own process group when it leads one (a
    /// terminal's job), never a shell's or an app's (D-145); otherwise the agent and each
    /// descendant by PID, so the app or editor hosting it is never touched. Claude Code runs each
    /// shell in a group of its own, so descendants outside the agent's group are added by PID.
    private func stopTargets(_ root: AgentDetection.Entry, descendants: [AgentDetection.Entry]) -> [TerminationTarget] {
        if let group = ProcessInspector.basics(root.pid)?.processGroupID, group == root.pid,
           ProjectDetection.groupIsStoppable(processGroupID: group, ownProcessGroupID: ownGroup, chain: [(root.name, root.path)]) {
            let outside = descendants.filter { ProcessInspector.basics($0.pid)?.processGroupID != group }
            return Self.targets(group: group, root: root.pid, outside: outside.map(\.pid))
        }
        return [.process(root.pid)] + descendants.map { .process($0.pid) }
    }

    /// Pure: the group, then each descendant outside it.
    static func targets(group: Int32?, root: Int32, outside: [Int32]) -> [TerminationTarget] {
        (group.map { [.processGroup($0)] } ?? [.process(root)]) + outside.map { .process($0) }
    }

    /// Every process: PID, parent, name and path; arguments only for node and bun, where the
    /// agent's package shows (`node …/@openai/codex/…`).
    static func table() -> [AgentDetection.Entry] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: max(capacity, 64))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else {
            return []
        }
        return pids.prefix(Int(count)).compactMap { pid -> AgentDetection.Entry? in
            // This user's processes only: another account's agents (Fast User Switching) aren't
            // this user's to see or stop (D-221).
            guard pid > 0, let identity = ProcessInspector.identity(pid), identity.uid == getuid() else {
                return nil
            }
            let path = ProcessInspector.executablePath(pid)
            let arguments = identity.name.hasPrefix("node") || identity.name == "bun" ? ProcessInspector.arguments(pid) : []
            return AgentDetection.Entry(pid: pid, parentPID: identity.parentPID, name: identity.name, path: path, arguments: arguments)
        }
    }
}
