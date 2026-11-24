import Core
import Foundation

/// A Docker container as the Projects tab shows it (expansion E5).
public struct Container: Hashable, Sendable, Identifiable {
    public enum State: String, Hashable, Sendable, CaseIterable {
        case created, running, paused, restarting, removing, exited, dead

        /// Running, paused, or restarting: something Stop can stop.
        public var isActive: Bool {
            switch self {
            case .running, .paused, .restarting: true
            case .created, .removing, .exited, .dead: false
            }
        }
    }

    /// The full 64-character ID.
    public let id: String
    /// Without the leading slash: "storefront-web-db-1".
    public let name: String
    /// "postgres:16-alpine".
    public let image: String
    public let state: State
    /// Docker's own words: "Up 3 hours (healthy)", "Exited (0) 2 days ago".
    public let status: String
    /// Published host ports, sorted, no duplicates (the IPv4 and IPv6 bindings are one port).
    public let ports: [UInt16]
    /// 100% is one core, like `docker stats` and Activity Monitor. Nil until two samples exist,
    /// and for containers that aren't running.
    public let cpuPercent: Double?
    /// Resident memory without the page cache, as `docker stats` counts it.
    public let memoryUsedBytes: UInt64?
    /// The container's limit, or the engine VM's memory when it has none.
    public let memoryLimitBytes: UInt64?
    /// `com.docker.compose.project`.
    public let composeProject: String?
    /// `com.docker.compose.service`.
    public let composeService: String?
    /// `com.docker.compose.project.working_dir`: the folder with the compose file, so a container
    /// can join the Mactivity project with the same root.
    public let workingDirectory: String?

    public init(
        id: String,
        name: String,
        image: String,
        state: State,
        status: String,
        ports: [UInt16],
        cpuPercent: Double?,
        memoryUsedBytes: UInt64?,
        memoryLimitBytes: UInt64?,
        composeProject: String?,
        composeService: String?,
        workingDirectory: String?
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.ports = ports
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.composeProject = composeProject
        self.composeService = composeService
        self.workingDirectory = workingDirectory
    }

    /// What Stop and Restart pass to `ConfirmedAction`.
    public var target: TerminationTarget {
        .container(id: id, name: name)
    }

    /// Whether this container belongs to the project at `rootPath`: its compose working directory
    /// is that folder or inside it.
    public func belongs(toProjectAt rootPath: String) -> Bool {
        guard let workingDirectory else {
            return false
        }
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        let directory = workingDirectory.hasSuffix("/") ? String(workingDirectory.dropLast()) : workingDirectory
        return directory == root || directory.hasPrefix(root + "/")
    }
}

/// Containers from a Docker engine. The live one talks to the daemon's Unix socket; the simulated
/// one is for previews, tests, and "Simulated data".
///
/// Lives in the Docker module rather than Core because it's an expansion behind a flag (spec 9);
/// it depends only on Core, so moving it is mechanical if Core should own it.
public protocol ContainerSource: Sendable {
    /// Every container, running or not, with figures for the running ones. Throws
    /// `DockerError.noEngine` when there's no socket, `.cannotConnect` when the engine is down.
    func containers() async throws -> [Container]

    /// The engine whose socket was found, or nil. Cheap: no request is made.
    func engine() async -> DockerEngine?
}

/// Restarts a container. Takes only a `ConfirmedTermination`, which only the UI's
/// `ConfirmedAction` creates (CLAUDE.md rule 4): a restart stops the container first.
public protocol ContainerRestarter: Sendable {
    func restart(_ request: ConfirmedTermination) async throws
}

/// Groups containers for display: compose projects by name, then containers outside compose.
public enum ContainerGrouping {
    public struct Group: Hashable, Sendable, Identifiable {
        /// The compose project, or nil for containers outside compose.
        public let project: String?
        public let workingDirectory: String?
        public let containers: [Container]

        public var id: String {
            project.map { "compose:\($0)" } ?? "standalone"
        }

        public var runningCount: Int {
            containers.count(where: { $0.state.isActive })
        }
    }

    /// Compose projects with something running first, then by name; standalone containers last.
    /// Inside a group: running first, then by name.
    public static func groups(_ containers: [Container]) -> [Group] {
        let byProject = Dictionary(grouping: containers, by: \.composeProject)
        let groups = byProject.map { project, members in
            Group(
                project: project,
                workingDirectory: members.lazy.compactMap(\.workingDirectory).first,
                containers: members.sorted(by: order)
            )
        }
        return groups.sorted { lhs, rhs in
            if (lhs.project == nil) != (rhs.project == nil) {
                return lhs.project != nil
            }
            if (lhs.runningCount > 0) != (rhs.runningCount > 0) {
                return lhs.runningCount > 0
            }
            return (lhs.project ?? "").localizedStandardCompare(rhs.project ?? "") == .orderedAscending
        }
    }

    static func order(_ lhs: Container, _ rhs: Container) -> Bool {
        if lhs.state.isActive != rhs.state.isActive {
            return lhs.state.isActive
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
