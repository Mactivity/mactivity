import Core
import Foundation

/// Fixed sets for Projects' Databases, SSH and Folders views, in previews, tests and Simulated data.
public struct SimulatedLocalDatabases: LocalDatabaseSource {
    private let now: Date

    public init(now: Date = Date()) {
        self.now = now
    }

    public func databases() async -> [LocalDatabase] {
        let brew = "/opt/homebrew/var/"
        return [
            LocalDatabase(
                pid: 812, engine: .postgres, pids: [812, 830, 831, 832, 833], memoryBytes: 96_000_000,
                startedAt: now.addingTimeInterval(-19 * 86400), ports: [5432], dataDirectory: brew + "postgresql@16",
                dataSource: .arguments,
                connections: 2, isReadable: true, processName: "postgres"
            ),
            LocalDatabase(
                pid: 815, engine: .redis, pids: [815], memoryBytes: 12_000_000, startedAt: now.addingTimeInterval(-19 * 86400),
                ports: [6379], dataDirectory: brew + "db/redis", dataSource: .workingDirectory, connections: 0, isReadable: true,
                processName: "redis-server"
            ),
            LocalDatabase(
                pid: 921, engine: .mongodb, pids: [921], memoryBytes: 180_000_000, startedAt: now.addingTimeInterval(-40 * 86400),
                ports: [27017], dataDirectory: brew + "mongodb", dataSource: .arguments, connections: 0, isReadable: true,
                processName: "mongod"
            ),
            LocalDatabase(
                pid: 240, engine: .mysql, pids: [240], memoryBytes: 0, startedAt: now.addingTimeInterval(-3 * 86400), ports: [],
                dataDirectory: nil, dataSource: nil, connections: nil, isReadable: false, processName: "mysqld"
            ),
        ]
    }

    public func diskUse(of database: LocalDatabase) async -> DatabaseDiskUse? {
        switch database.engine {
        case .postgres: DatabaseDiskUse(bytes: 2_400_000_000, lastWrite: now.addingTimeInterval(-3600))
        case .redis: DatabaseDiskUse(bytes: 48_000_000, lastWrite: now.addingTimeInterval(-3 * 86400))
        case .mongodb: DatabaseDiskUse(bytes: 860_000_000, lastWrite: now.addingTimeInterval(-37 * 86400))
        case .mysql, .mariadb: nil
        }
    }
}

public struct SimulatedRemoteSessions: RemoteSessionSource {
    private let now: Date

    public init(now: Date = Date()) {
        self.now = now
    }

    public func sessions() async -> [RemoteSession] {
        [
            RemoteSession(
                pid: 3101, kind: .tunnel, host: "bastion.example.com", startedAt: now.addingTimeInterval(-3 * 86400),
                forwards: [
                    SSHForward(kind: .local, listenPort: 15432, targetHost: "db.internal", targetPort: 5432, isListening: true),
                    SSHForward(kind: .dynamic, listenPort: 1080, isListening: true),
                ]
            ),
            RemoteSession(
                pid: 3180, kind: .shell, host: "build-01.example.com", jump: "bastion.example.com",
                startedAt: now.addingTimeInterval(-5 * 3600),
                forwards: [
                    SSHForward(kind: .remote, listenPort: 9000, targetHost: "localhost", targetPort: 3000),
                    SSHForward(kind: .local, listenPort: 8443, isFromSocketOnly: true, isListening: true),
                ]
            ),
            RemoteSession(
                pid: 3244, kind: .shared, host: "203.0.113.7", startedAt: now.addingTimeInterval(-40 * 60)
            ),
            RemoteSession(
                pid: 3301, kind: .command, host: "github.com", startedAt: now.addingTimeInterval(-12), startedBy: "git"
            ),
        ]
    }
}

public struct SimulatedProjectGlance: ProjectGlanceSource {
    private let now: Date

    public init(now: Date = Date()) {
        self.now = now
    }

    public func scan(update: @escaping @Sendable ([ProjectGlance]) -> Void) async -> [ProjectGlance] {
        let dev = "/Users/demo/Developer/"
        func version(_ runtime: String, _ version: String, _ file: String) -> ProjectRuntimeVersion {
            ProjectRuntimeVersion(runtime: runtime, version: version, file: file)
        }
        func project(
            _ name: String, _ languages: [ProjectLanguage], _ runtime: ProjectRuntimeVersion?, _ size: UInt64?, days: Double
        ) -> ProjectGlance {
            ProjectGlance(
                root: dev + name, name: name, languages: languages, runtime: runtime, sizeBytes: size,
                lastWorked: now.addingTimeInterval(-days * 86400)
            )
        }
        let projects = ProjectGlance.sorted([
            project("storefront-web", [.typeScript], version("Node", "20.11.0", ".nvmrc"), 2_100_000_000, days: 0.1),
            project("ios-app", [.swift], version("Swift tools", "6.0", "Package.swift"), 8_400_000_000, days: 1),
            project("ingest", [.rust], version("Rust", "1.82", "rust-toolchain.toml"), 5_200_000_000, days: 9),
            project("api", [.go], version("Go", "1.23", "go.mod"), 310_000_000, days: 34),
            project("ml-notes", [.python], version("Python", ">=3.11", "pyproject.toml"), 1_700_000_000, days: 88),
            project("old-scripts", [], nil, 4_000_000, days: 410),
        ])
        update(projects)
        return projects
    }
}
