import Core
import Foundation

/// Fake containers for previews, tests, and "Simulated data" (CLAUDE.md rule 1). Its compose
/// working directories match `SimulatedDevServers`' project roots, so containers join projects.
///
/// Also stops and restarts its own containers, so the confirmation path can be exercised
/// without an engine. Like the live terminator, it refuses anything that isn't a container.
public actor SimulatedContainerSource: ContainerSource, ProcessTerminator, ContainerRestarter {
    private var list: [Container]
    private let engineKind: DockerEngine.Kind?
    public private(set) var requests: [ConfirmedTermination] = []

    /// `engine: nil` simulates a Mac with no Docker at all.
    public init(engine: DockerEngine.Kind? = .dockerDesktop, containers: [Container] = SimulatedContainerSource.sample) {
        engineKind = engine
        list = containers
    }

    public func engine() async -> DockerEngine? {
        engineKind.map { DockerEngine(kind: $0, socketPath: "/simulated/docker.sock") }
    }

    public func containers() async throws -> [Container] {
        guard engineKind != nil else {
            throw DockerError.noEngine
        }
        return list
    }

    public func terminate(_ request: ConfirmedTermination) async throws -> TerminationResult {
        guard case let .container(id, _) = request.target, let index = list.firstIndex(where: { $0.id == id }) else {
            throw DockerError.refused
        }
        requests.append(request)
        let old = list[index]
        list[index] = old.with(
            state: .exited,
            status: request.mode == .quit ? "Exited (0) Less than a second ago" : "Exited (137) Less than a second ago"
        )
        return TerminationResult(terminated: [], survivors: [])
    }

    public func restart(_ request: ConfirmedTermination) async throws {
        guard case let .container(id, _) = request.target, let index = list.firstIndex(where: { $0.id == id }) else {
            throw DockerError.refused
        }
        requests.append(request)
        list[index] = list[index].with(state: .running, status: "Up Less than a second")
    }

    // MARK: Sample data

    private static let gigabyte: UInt64 = 1 << 30
    private static let megabyte: UInt64 = 1 << 20

    public static let sample: [Container] = [
        make(
            "storefront-web-db-1",
            image: "postgres:16-alpine",
            status: "Up 3 hours (healthy)",
            ports: [5432],
            cpu: 1.8,
            memory: 212 * megabyte,
            project: "storefront-web",
            service: "db",
            root: "/Users/demo/Developer/storefront-web"
        ),
        make(
            "storefront-web-redis-1",
            image: "redis:7",
            status: "Up 3 hours",
            ports: [6379],
            cpu: 0.4,
            memory: 14 * megabyte,
            project: "storefront-web",
            service: "redis",
            root: "/Users/demo/Developer/storefront-web"
        ),
        make(
            "storefront-web-mailpit-1",
            image: "axllent/mailpit",
            status: "Up 3 hours",
            ports: [1025, 8025],
            cpu: 0.1,
            memory: 22 * megabyte,
            project: "storefront-web",
            service: "mailpit",
            root: "/Users/demo/Developer/storefront-web"
        ),
        make(
            "api-postgres-1",
            image: "postgis/postgis:16-3.4",
            status: "Up 2 days",
            ports: [5433],
            cpu: 0.3,
            memory: 96 * megabyte,
            project: "api",
            service: "postgres",
            root: "/Users/demo/Developer/api"
        ),
        make(
            "api-worker-1",
            image: "api-worker:dev",
            state: .exited,
            status: "Exited (1) 40 minutes ago",
            ports: [],
            cpu: nil,
            memory: nil,
            project: "api",
            service: "worker",
            root: "/Users/demo/Developer/api"
        ),
        make(
            "minio",
            image: "minio/minio:latest",
            status: "Up 5 days",
            ports: [9000, 9001],
            cpu: 12.6,
            memory: 1380 * megabyte,
            project: nil,
            service: nil,
            root: nil
        ),
    ]

    // swiftlint:disable:next function_parameter_count
    private static func make(
        _ name: String, image: String, state: Container.State = .running, status: String, ports: [UInt16],
        cpu: Double?, memory: UInt64?, project: String?, service: String?, root: String?
    ) -> Container {
        let hex = name.utf8.reduce(into: "") { $0 += String($1, radix: 16) }
        let id = String((hex + String(repeating: "0", count: 64)).prefix(64))
        return Container(
            id: id, name: name, image: image, state: state, status: status, ports: ports,
            cpuPercent: cpu, memoryUsedBytes: memory, memoryLimitBytes: memory.map { _ in 8 * gigabyte },
            composeProject: project, composeService: service, workingDirectory: root
        )
    }
}

extension Container {
    func with(state: State, status: String) -> Container {
        Container(
            id: id, name: name, image: image, state: state, status: status, ports: ports,
            cpuPercent: state == .running ? cpuPercent : nil,
            memoryUsedBytes: state == .running ? memoryUsedBytes : nil,
            memoryLimitBytes: memoryLimitBytes,
            composeProject: composeProject, composeService: composeService, workingDirectory: workingDirectory
        )
    }
}
