import Core
import Foundation

/// Loads JSON fixtures from `Tests/Fixtures/`, shared by every test target.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A 4-core Mac with six apps: macOS, Xcode, Safari, Slack, a bare `node`, and Terminal.
    static func snapshot() throws -> Snapshot {
        try load("snapshot-readouts.json")
    }

    static let english = Locale(identifier: "en_US")

    /// Two projects: a working Vite app and an idle API with two ports.
    static func projects(now: Date) -> [Project] {
        let web = DevServer(
            pid: 4312, name: "node", command: "node node_modules/.bin/vite --port 4321", runtime: .node, ports: [4321],
            memoryBytes: 480_247_808, startedAt: now.addingTimeInterval(-7500), cpuTime: .seconds(95), activity: .working,
            stopTarget: .processGroup(4312)
        )
        let api = DevServer(
            pid: 5120, name: "python3", command: "python3 -m uvicorn app:api", runtime: .python, ports: [8080, 8081],
            memoryBytes: 96_468_992, startedAt: now.addingTimeInterval(-10800), cpuTime: .seconds(70), activity: .idle(minutes: 125),
            stopTarget: .process(5120)
        )
        return [
            Project(rootPath: "/Users/demo/Developer/storefront-web", name: "storefront-web", servers: [web]),
            Project(rootPath: "/Users/demo/Developer/api", name: "api", servers: [api]),
        ]
    }

    /// `base` with its CPU, memory, battery, or apps replaced.
    static func variant(
        of base: Snapshot,
        at: Date? = nil,
        cpu: Double? = nil,
        memoryUsed: UInt64? = nil,
        battery: BatteryStats?? = nil,
        apps: [AppAggregate]? = nil
    ) -> Snapshot {
        let system = base.system
        let oldCPU = system.cpu
        let oldMemory = system.memory
        return Snapshot(
            at: at ?? base.at,
            interval: base.interval,
            system: SystemSample(
                cpu: CPUStats(
                    totalPercent: cpu ?? oldCPU.totalPercent, userPercent: oldCPU.userPercent, systemPercent: oldCPU.systemPercent,
                    perCorePercent: oldCPU.perCorePercent, clusters: oldCPU.clusters, loadAverage: oldCPU.loadAverage
                ),
                memory: MemoryStats(
                    totalBytes: oldMemory.totalBytes, usedBytes: memoryUsed ?? oldMemory.usedBytes, appBytes: oldMemory.appBytes,
                    wiredBytes: oldMemory.wiredBytes, compressedBytes: oldMemory.compressedBytes,
                    cachedFilesBytes: oldMemory.cachedFilesBytes, swapUsedBytes: oldMemory.swapUsedBytes,
                    pressure: oldMemory.pressure, availableLevel: oldMemory.availableLevel
                ),
                disk: system.disk, network: system.network, gpu: system.gpu,
                battery: battery ?? system.battery,
                sensors: system.sensors, thermal: system.thermal, uptime: system.uptime
            ),
            apps: apps ?? base.apps,
            processes: base.processes
        )
    }
}
