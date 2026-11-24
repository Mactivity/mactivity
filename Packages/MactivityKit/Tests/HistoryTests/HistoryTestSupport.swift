import Core
import Foundation
import GRDB
@testable import History

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date = Build.base) {
        current = date
    }

    var now: Date {
        lock.withLock { current }
    }

    func set(_ date: Date) {
        lock.withLock { current = date }
    }

    /// Seconds after `Build.base`.
    func set(offset seconds: TimeInterval) {
        set(Build.base.addingTimeInterval(seconds))
    }
}

/// Hand-built snapshots at chosen times with chosen values.
enum Build {
    /// A quarter-hour boundary (so also a minute boundary): 2026-09-21 12:00:00 UTC.
    static let base = Date(timeIntervalSince1970: 1_789_999_200)

    static func identity(_ id: String) -> AppIdentity {
        AppIdentity(
            id: id, name: "App \(id)", bundleID: "com.example.\(id)",
            iconKey: "/Applications/\(id).app", kind: .app
        )
    }

    static func app(
        _ id: String,
        cpu: Double = 0,
        memory: UInt64 = 0,
        energy: Double? = nil,
        diskRead: Double = 0,
        diskWrite: Double = 0,
        netIn: Double? = nil,
        netOut: Double? = nil,
        gpu: Double? = nil,
        identity: AppIdentity? = nil
    ) -> AppAggregate {
        AppAggregate(
            app: identity ?? Self.identity(id), processCount: 1, cpuPercent: cpu, memoryBytes: memory,
            energyMW: energy, diskReadBPS: diskRead, diskWriteBPS: diskWrite,
            netInBPS: netIn, netOutBPS: netOut, gpuPercent: gpu
        )
    }

    /// A snapshot `seconds` after `base`.
    static func snapshot(
        at seconds: TimeInterval,
        cpu: Double = 0,
        memoryUsed: UInt64 = 0,
        diskRead: Double = 0,
        diskWrite: Double = 0,
        netIn: Double = 0,
        netOut: Double = 0,
        gpu: Double? = nil,
        apps: [AppAggregate] = [],
        battery: BatteryStats? = nil,
        sensors: SensorStats? = nil,
        thermal: ThermalPressure = .nominal,
        interval: Duration = .seconds(5)
    ) -> Snapshot {
        let system = SystemSample(
            cpu: CPUStats(
                totalPercent: cpu, userPercent: cpu, systemPercent: 0,
                perCorePercent: [], clusters: [], loadAverage: .zero
            ),
            memory: MemoryStats(
                totalBytes: 64_000_000_000, usedBytes: memoryUsed, appBytes: memoryUsed, wiredBytes: 0,
                compressedBytes: 0, cachedFilesBytes: 0, swapUsedBytes: 0, pressure: .normal, availableLevel: 50
            ),
            disk: DiskStats(volumes: [], readBPS: diskRead, writeBPS: diskWrite),
            network: NetworkStats(inBPS: netIn, outBPS: netOut, primaryInterface: "en0"),
            gpu: gpu.map { GPUStats(name: "Test GPU", utilizationPercent: $0, memoryInUseBytes: nil) },
            battery: battery,
            sensors: sensors,
            thermal: thermal,
            uptime: .seconds(3600)
        )
        return Snapshot(
            at: base.addingTimeInterval(seconds), interval: interval, system: system,
            apps: apps, processes: []
        )
    }

    static func date(_ seconds: TimeInterval) -> Date {
        base.addingTimeInterval(seconds)
    }
}

extension SQLiteHistoryStore {
    /// In-memory store on a test clock.
    static func inMemory(clock: TestClock, retentionDays: Int = 30) throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(url: nil, retentionDays: retentionDays, now: { clock.now })
    }

    func rowCount(_ table: String) throws -> Int {
        try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") } ?? 0
    }

    func rowTimes(_ table: String, app: String = "*") throws -> [Int64] {
        try database.read {
            try Int64.fetchAll($0, sql: "SELECT t FROM \(table) WHERE app = ? ORDER BY t", arguments: [app])
        }
    }
}

let minute: TimeInterval = 60
let hour: TimeInterval = 3600
let day: TimeInterval = 86400
