import Core
import Foundation

/// Fake dev servers for previews, tests, and "Simulated data" mode. It is also its own
/// terminator, so stopping a server in simulated mode removes it and frees its ports.
public actor SimulatedDevServers: ProjectSource, ProcessTerminator {
    private struct Entry {
        let root: String
        let server: DevServer
    }

    private var entries: [Entry]

    /// The storefront-web Next.js server, idle for 42 minutes: the one simulated process details
    /// describe in full.
    public static let storefrontPID: Int32 = 4101

    public init(now: Date = Date()) {
        func server(
            _ pid: Int32, _ name: String, _ command: String, _ runtime: DevRuntime, _ ports: [UInt16], megabytes: Double,
            hoursUp: Double, activity: ProjectActivity
        ) -> DevServer {
            DevServer(
                pid: pid, name: name, command: command, runtime: runtime, ports: ports,
                memoryBytes: UInt64(megabytes * 1_048_576), startedAt: now.addingTimeInterval(-hoursUp * 3600),
                cpuTime: .seconds(activity == .barelyUsed ? 12 : 340), activity: activity, stopTarget: .processGroup(pid)
            )
        }
        entries = [
            Entry(root: "/Users/demo/Developer/storefront-web", server: server(
                Self.storefrontPID, "node", "node node_modules/.bin/next dev -p 4322", .node, [4322], megabytes: 458, hoursUp: 5,
                activity: .idle(minutes: 42)
            )),
            Entry(root: "/Users/demo/Developer/docs-site", server: server(
                4201, "node", "node node_modules/.bin/astro dev", .node, [4321], megabytes: 212, hoursUp: 2, activity: .working
            )),
            Entry(root: "/Users/demo/Developer/api", server: server(
                4301, "python3.13", "python3.13 -m uvicorn app.main:app --reload --port 8000", .python, [8000], megabytes: 96,
                hoursUp: 30, activity: .barelyUsed
            )),
            Entry(root: "/Users/demo/Developer/storefront-web", server: server(
                4401, "node", "node node_modules/.bin/storybook dev -p 6006", .node, [6006], megabytes: 390, hoursUp: 5,
                activity: .idle(minutes: 18)
            )),
            Entry(root: "/Users/demo/Developer/ledger", server: server(
                4501, "ledger", "ledger serve --addr :3000", .go, [3000], megabytes: 38, hoursUp: 50, activity: .idle(minutes: 190)
            )),
        ]
    }

    public func projects() async throws -> [Project] {
        let grouped = Dictionary(grouping: entries, by: \.root)
        return grouped.map { root, entries in
            Project(
                rootPath: root, name: root.split(separator: "/").last.map(String.init) ?? root,
                servers: entries.map(\.server).sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
            )
        }
        .sorted { lhs, rhs in
            if (lhs.activity == .working) != (rhs.activity == .working) {
                return lhs.activity == .working
            }
            return lhs.memoryBytes > rhs.memoryBytes
        }
    }

    public func terminate(_ request: ConfirmedTermination) async throws -> TerminationResult {
        let stopped = entries.filter { $0.server.stopTarget == request.target || request.target == .process($0.server.pid) }
        entries.removeAll { entry in stopped.contains { $0.server.pid == entry.server.pid } }
        return TerminationResult(terminated: stopped.map(\.server.pid), survivors: [])
    }
}
