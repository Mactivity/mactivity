import Core
import Darwin
import Foundation
import os

/// Finds dev servers: the user's processes (outside app bundles) that hold a listening TCP
/// port, grouped by the project folder they run in (spec 5.5, 6.12).
///
/// It watches snapshots to know when each process last used CPU, and scans ports only when
/// asked (the Projects views ask every few seconds while visible).
public actor ProjectMonitor: ProjectSource {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    private static let log = Logger(subsystem: "app.mactivity.projects", category: "monitor")

    private var tracker = ActivityTracker()
    private var candidates: [Int32] = []
    private var lastProcesses: [ProcessSample] = []
    private let home: String
    private let ownGroup: Int32
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        home = FileManager.default.homeDirectoryForCurrentUser.path
        ownGroup = getpgrp()
        self.clock = clock
    }

    /// Called once per snapshot.
    public func observe(_ snapshot: Snapshot) {
        // Between idle process passes the sampler reuses the same samples; nothing to do.
        guard snapshot.processes != lastProcesses else {
            return
        }
        lastProcesses = snapshot.processes
        let systemIDs = Set(snapshot.apps.filter { $0.app.kind == .system }.map(\.id))
        let possible = snapshot.processes.filter { !systemIDs.contains($0.app) }
        tracker.observe(possible, at: snapshot.at, coreCount: snapshot.system.cpu.perCorePercent.count)
        candidates = possible.map(\.pid)
    }

    public func projects() async throws -> [Project] {
        let now = clock()
        let me = getpid()
        var servers: [(server: DevServer, root: String)] = []
        var claimedGroups = Set<Int32>()
        for pid in candidates where pid != me {
            // Dev servers run from the command line, not from inside an app bundle.
            guard let path = ProcessInspector.executablePath(pid), !path.contains(".app/") else {
                continue
            }
            let ports = ProcessInspector.listeningPorts(pid)
            guard !ports.isEmpty,
                  let directory = ProcessInspector.workingDirectory(pid),
                  let (root, markers) = ProjectDetection.projectRoot(from: directory, home: home, exists: {
                      FileManager.default.fileExists(atPath: $0)
                  }),
                  let basics = ProcessInspector.basics(pid)
            else {
                continue
            }
            let target = stopTarget(pid: pid, group: basics.processGroupID)
            if case let .processGroup(group) = target {
                // Two listening processes in one job are one server.
                guard claimedGroups.insert(group).inserted else {
                    merge(ports: ports, intoGroup: group, servers: &servers)
                    continue
                }
            }
            let members: [Int32] = if case let .processGroup(group) = target {
                ProcessInspector.members(ofGroup: group)
            } else {
                [pid]
            }
            let usages = members.compactMap(ProcessInspector.usage)
            let cpu = usages.reduce(Duration.zero) { $0 + $1.cpu }
            let arguments = ProcessInspector.arguments(pid)
            let lastActive = tracker.lastActive(among: members) ?? now
            let server = DevServer(
                pid: pid,
                name: basics.name,
                command: ProjectDetection.commandLine(arguments.isEmpty ? [path] : arguments, home: home),
                runtime: ProjectDetection.runtime(
                    executablePath: path, name: basics.name, arguments: arguments, root: root, markers: markers
                ),
                ports: Array(Set(ports.map(\.port))).sorted(),
                memoryBytes: usages.reduce(0) { $0 + $1.footprint },
                startedAt: basics.startedAt,
                cpuTime: cpu,
                activity: ProjectDetection.activity(lastActiveAt: lastActive, startedAt: basics.startedAt, cpuTime: cpu, now: now),
                stopTarget: target
            )
            servers.append((server, root))
        }
        return ProjectDetection.projects(servers)
    }

    private func stopTarget(pid: Int32, group: Int32) -> TerminationTarget {
        let stoppable = ProjectDetection.groupIsStoppable(
            processGroupID: group, ownProcessGroupID: ownGroup, chain: Self.chain(from: group, to: pid)
        )
        return stoppable ? .processGroup(group) : .process(pid)
    }

    /// The processes from the group leader down to `pid`, leader first; empty when `pid` isn't a
    /// descendant of the leader within a few steps (then only the process itself is stopped).
    static func chain(from leader: Int32, to pid: Int32) -> [(name: String, path: String?)] {
        guard leader > 1 else {
            return []
        }
        var chain: [(name: String, path: String?)] = []
        var current = pid
        for _ in 0 ..< 8 {
            guard let identity = ProcessInspector.identity(current) else {
                return []
            }
            chain.insert((identity.name, ProcessInspector.executablePath(current)), at: 0)
            if current == leader {
                return chain
            }
            guard identity.parentPID > 1 else {
                return []
            }
            current = identity.parentPID
        }
        return []
    }

    private func merge(ports: [ListeningPort], intoGroup group: Int32, servers: inout [(server: DevServer, root: String)]) {
        guard let index = servers.firstIndex(where: { $0.server.stopTarget == .processGroup(group) }) else {
            return
        }
        let old = servers[index].server
        servers[index].server = DevServer(
            pid: old.pid, name: old.name, command: old.command, runtime: old.runtime,
            ports: Array(Set(old.ports + ports.map(\.port))).sorted(), memoryBytes: old.memoryBytes,
            startedAt: old.startedAt, cpuTime: old.cpuTime, activity: old.activity, stopTarget: old.stopTarget
        )
    }
}
