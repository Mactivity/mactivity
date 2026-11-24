import Core
@testable import Docker
import Foundation
import Testing

enum IDs {
    static let db = "4f2a9c1e8b7d6a5f4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a19"
    static let redis = "7c3e5a1b9d8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c2b1a0f9e8d7c6b5a4f3e2d"
    static let worker = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
    static let minio = "e9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8"
}

extension FakeDockerDaemon {
    var engine: DockerEngine {
        DockerEngine(kind: .dockerDesktop, socketPath: socketPath)
    }

    /// The fixture engine: four containers, three running.
    func serveFixtures(chunkedMinio: Bool = false) {
        route("GET", "/containers/json?all=1", .fixture("docker-containers.json"))
        route("GET", "/containers/\(IDs.db)/stats?stream=false", .fixture("docker-stats-db.json"))
        route("GET", "/containers/\(IDs.db)/stats?stream=false&one-shot=true", .fixture("docker-stats-db.json"))
        route("GET", "/containers/\(IDs.redis)/stats?stream=false", .fixture("docker-stats-redis-first.json"))
        route("GET", "/containers/\(IDs.redis)/stats?stream=false&one-shot=true", .fixture("docker-stats-redis-later.json"))
        let minio: Reply = chunkedMinio ? .chunkedFixture("docker-stats-minio.json", chunkSize: 97) : .fixture("docker-stats-minio.json")
        route("GET", "/containers/\(IDs.minio)/stats?stream=false", minio)
        route("GET", "/containers/\(IDs.minio)/stats?stream=false&one-shot=true", minio)
    }
}

@Suite("Container listing")
struct ContainerSourceTests {
    @Test("Lists every container with names, images, states, ports, and compose labels")
    func listing() async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.serveFixtures()
        let source = DockerContainerSource(engine: daemon.engine)

        let containers = try await source.containers()

        #expect(containers.map(\.name) == ["storefront-web-db-1", "storefront-web-redis-1", "api-worker-1", "minio"])
        let db = try #require(containers.first { $0.id == IDs.db })
        #expect(db.image == "postgres:16-alpine")
        #expect(db.state == .running)
        #expect(db.status == "Up 3 hours (healthy)")
        #expect(db.ports == [5432], "IPv4 and IPv6 bindings of one port are one port")
        #expect(db.composeProject == "storefront-web")
        #expect(db.composeService == "db")
        #expect(db.workingDirectory == "/Users/demo/Developer/storefront-web")
        #expect(db.target == .container(id: IDs.db, name: "storefront-web-db-1"))

        let worker = try #require(containers.first { $0.id == IDs.worker })
        #expect(worker.state == .exited)
        #expect(worker.ports.isEmpty, "An unpublished port isn't a host port")
        #expect(worker.cpuPercent == nil && worker.memoryUsedBytes == nil)

        let minio = try #require(containers.first { $0.id == IDs.minio })
        #expect(minio.ports == [9000, 9001])
        #expect(minio.composeProject == nil)

        // One list, one stats call per running container, nothing for the exited one, no POSTs.
        let lines = daemon.requests.map(\.line).sorted()
        #expect(lines == [
            "GET /containers/\(IDs.db)/stats?stream=false",
            "GET /containers/\(IDs.redis)/stats?stream=false",
            "GET /containers/\(IDs.minio)/stats?stream=false",
            "GET /containers/json?all=1",
        ].sorted())
    }

    @Test("CPU and memory match docker stats, and later readings diff against the kept sample")
    func statsMath() async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.serveFixtures()
        let source = DockerContainerSource(engine: daemon.engine)

        let first = try await source.containers()
        let db = try #require(first.first { $0.id == IDs.db })
        // (2.0e9 − 1.8e9) / (90e9 − 82e9) × 8 CPUs × 100
        #expect(try abs(#require(db.cpuPercent) - 20) < 1e-9)
        // cgroup v2: usage − inactive_file
        #expect(db.memoryUsedBytes == 250_000_000 - 27_705_344)
        #expect(db.memoryLimitBytes == 8_217_530_368)

        let redis = try #require(first.first { $0.id == IDs.redis })
        #expect(redis.cpuPercent == nil, "No precpu sample and nothing kept yet")
        // cgroup v1: usage − total_inactive_file
        #expect(redis.memoryUsedBytes == 15_000_000)

        let second = try await source.containers()
        let later = try #require(second.first { $0.id == IDs.redis })
        // (0.7e9 − 0.5e9) / (60e9 − 40e9) × 4 CPUs (from percpu_usage, online_cpus is 0) × 100
        #expect(try abs(#require(later.cpuPercent) - 4) < 1e-9)
        #expect(later.memoryUsedBytes == 16_000_000)
        #expect(daemon.requests.contains { $0.path == "/containers/\(IDs.redis)/stats?stream=false&one-shot=true" })
    }

    @Test("A chunked stats response decodes like a sized one")
    func chunkedStats() async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.serveFixtures(chunkedMinio: true)
        let source = DockerContainerSource(engine: daemon.engine)

        let minio = try #require(try await source.containers().first { $0.id == IDs.minio })

        #expect(try abs(#require(minio.cpuPercent) - 100) < 1e-9)
        #expect(minio.memoryUsedBytes == 1_400_000_000)
    }

    @Test("A container whose stats fail keeps its row without figures")
    func failedStats() async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.serveFixtures()
        daemon.route("GET", "/containers/\(IDs.minio)/stats?stream=false", .body(#"{"message":"boom"}"#, status: 500))
        let containers = try await DockerContainerSource(engine: daemon.engine).containers()

        let minio = try #require(containers.first { $0.id == IDs.minio })
        #expect(minio.cpuPercent == nil && minio.memoryUsedBytes == nil)
        #expect(containers.count == 4)
    }

    @Test("No socket anywhere is noEngine; a socket nobody answers is cannotConnect")
    func missingEngine() async throws {
        let none = DockerContainerSource(discover: { nil })
        await #expect(throws: DockerError.noEngine) { try await none.containers() }
        #expect(await none.engine() == nil)

        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("mdk-none-\(UUID().uuidString.prefix(6)).sock")
        let dead = DockerContainerSource(engine: DockerEngine(kind: .other, socketPath: path))
        await #expect {
            try await dead.containers()
        } throws: { error in
            if case DockerError.cannotConnect = error {
                return true
            }
            return false
        }
    }

    @Test("An Engine API error carries its message")
    func apiError() async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.route("GET", "/containers/json?all=1", .body(#"{"message":"client version 1.52 is too new"}"#, status: 400))
        await #expect(throws: DockerError.http(status: 400, message: "client version 1.52 is too new")) {
            try await DockerContainerSource(engine: daemon.engine).containers()
        }
    }
}

@Suite("Stats math")
struct StatsMathTests {
    typealias Sample = DockerStatsMath.CPUSample

    /// Previous sample: 1,000 ns container, 2,000 ns system.
    @Test("CPU percent: delta over delta, times online CPUs", arguments: [
        // 500 / 8,000 × 4 × 100
        (Sample(containerNanoseconds: 1500, systemNanoseconds: 10000, onlineCPUs: 4), 25.0),
        (Sample(containerNanoseconds: 1000, systemNanoseconds: 10000, onlineCPUs: 4), 0.0),
        // 8,000 / 8,000 × 8 × 100: eight busy cores
        (Sample(containerNanoseconds: 9000, systemNanoseconds: 10000, onlineCPUs: 8), 800.0),
    ] as [(Sample, Double)])
    func cpu(current: Sample, expected: Double) throws {
        let previous = Sample(containerNanoseconds: 1000, systemNanoseconds: 2000, onlineCPUs: 4)
        #expect(try abs(#require(DockerStatsMath.cpuPercent(current: current, previous: previous)) - expected) < 1e-9)
    }

    @Test("No system interval, no reading")
    func noInterval() {
        let sample = Sample(containerNanoseconds: 5, systemNanoseconds: 10, onlineCPUs: 2)
        #expect(DockerStatsMath.cpuPercent(current: sample, previous: sample) == nil)
    }

    @Test("Memory without page cache", arguments: [
        (["total_inactive_file": UInt64(30)], UInt64(70)),
        (["inactive_file": 25], 75),
        (["inactive_file": 500], 100),
        ([:], 100),
    ] as [([String: UInt64], UInt64)])
    func memory(stats: [String: UInt64], expected: UInt64) {
        #expect(DockerStatsMath.memoryUsed(usage: 100, stats: stats) == expected)
    }
}

@Suite("Grouping")
struct ContainerGroupingTests {
    @Test("Compose projects first, running first inside, standalone last")
    func groups() {
        let groups = ContainerGrouping.groups(SimulatedContainerSource.sample)
        #expect(groups.map(\.project) == ["api", "storefront-web", nil])
        #expect(groups[0].containers.map(\.name) == ["api-postgres-1", "api-worker-1"])
        #expect(groups[0].runningCount == 1)
        #expect(groups[1].workingDirectory == "/Users/demo/Developer/storefront-web")
    }

    @Test("A container joins the project whose root holds its compose folder", arguments: [
        ("/Users/demo/Developer/storefront-web", true),
        ("/Users/demo/Developer/storefront-web/", true),
        ("/Users/demo/Developer", true),
        ("/Users/demo/Developer/storefront", false),
        ("/Users/demo/Developer/storefront-web/apps", false),
    ])
    func joinsProject(root: String, expected: Bool) throws {
        let db = try #require(SimulatedContainerSource.sample.first)
        #expect(db.belongs(toProjectAt: root) == expected)
    }
}

@Suite("Refresh cost")
struct RefreshCostTests {
    @Test("One refresh (list + three stats calls) against the fake daemon")
    func cost() async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.serveFixtures()
        let source = DockerContainerSource(engine: daemon.engine)
        _ = try await source.containers()

        let calls = 50
        let clock = ContinuousClock()
        let cpuBefore = Self.processCPUSeconds()
        let start = clock.now
        for _ in 0 ..< calls {
            _ = try await source.containers()
        }
        let wall = (clock.now - start) / calls
        let cpu = (Self.processCPUSeconds() - cpuBefore) / Double(calls)
        let line = "[timing] Docker refresh, 4 containers / 3 running: \(wall) wall, "
            + "\(String(format: "%.3f", cpu * 1000)) ms CPU (client and fake daemon together) per refresh\n"
        FileHandle.standardError.write(Data(line.utf8))
        #expect(wall < .milliseconds(50))
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }
}
