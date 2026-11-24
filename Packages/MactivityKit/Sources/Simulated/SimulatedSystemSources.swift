import Core
import Foundation

// Believable fake system figures. Each source advances one tick per `sample()` call and is
// deterministic for a given seed, so tests can assert exact sequences.

public actor SimulatedCPUSource: CPUSource {
    private let topology: CPUTopology
    private let overall: Wander
    private let perCore: [Wander]
    private var tick = 0

    public init(seed: UInt64 = 0xC0FFEE, topology: CPUTopology = SimulatedCatalog.topology) {
        self.topology = topology
        overall = Wander(seed: seed, base: 0.2, amplitude: 0.12, spikeChance: 0.03)
        perCore = (0 ..< topology.coreCount).map { index in
            Wander(seed: seed &+ UInt64(index + 1), base: 0, amplitude: 0.1, spikeChance: 0.01)
        }
    }

    public func sample() async throws -> CPUStats {
        defer { tick += 1 }
        let level = overall.value(at: tick)
        let cores = perCore.enumerated().map { index, wander in
            // The most performant level carries more of the load, like the real scheduler.
            let bias = topology.levels.first { $0.coreIndexes.contains(index) }?.level == 0 ? 1.3 : 0.8
            let total = min(1, max(0, level * bias + (wander.value(at: tick) - 0.05))) * 100
            return (user: total * 0.68, system: total * 0.32)
        }
        let load = level * Double(topology.coreCount) * 0.6
        return CPUStats.aggregate(
            perCore: cores,
            topology: topology,
            loadAverage: LoadAverage(one: load, five: load * 0.9, fifteen: load * 0.8)
        )
    }
}

public actor SimulatedMemorySource: MemorySource {
    private let wander: Wander
    private var tick = 0

    public init(seed: UInt64 = 0xBEEF) {
        wander = Wander(seed: seed, base: 0.55, amplitude: 0.08, spikeChance: 0)
    }

    public func sample() async throws -> MemoryStats {
        defer { tick += 1 }
        let total = SimulatedCatalog.totalMemoryBytes
        let usedFraction = wander.value(at: tick)
        let used = UInt64(Double(total) * usedFraction)
        let wired = used / 5
        let compressed = used / 10
        let pressure: MemoryPressure = usedFraction > 0.9 ? .critical : usedFraction > 0.75 ? .warning : .normal
        return MemoryStats(
            totalBytes: total,
            usedBytes: used,
            appBytes: used - wired - compressed,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedFilesBytes: (total - used) / 2,
            swapUsedBytes: usedFraction > 0.7 ? 1_200_000_000 : 0,
            pressure: pressure,
            availableLevel: Int((1 - usedFraction) * 100)
        )
    }
}

public actor SimulatedDiskSource: DiskSource {
    private let read: Wander
    private let write: Wander
    private var tick = 0

    public init(seed: UInt64 = 0xD15C) {
        read = Wander(seed: seed, base: 0.08, amplitude: 0.06, spikeChance: 0.04)
        write = Wander(seed: seed &+ 1, base: 0.05, amplitude: 0.04, spikeChance: 0.03)
    }

    public func sample() async throws -> DiskStats {
        defer { tick += 1 }
        let readBPS = read.value(at: tick) * 120_000_000
        let writeBPS = write.value(at: tick) * 80_000_000
        return DiskStats(
            volumes: [
                VolumeStats(id: "/", name: "Macintosh HD", totalBytes: 994_000_000_000, freeBytes: 412_300_000_000),
                VolumeStats(
                    id: "/Volumes/Archive",
                    name: "Archive",
                    totalBytes: 2_000_000_000_000,
                    freeBytes: 1_310_000_000_000
                ),
            ],
            readBPS: readBPS,
            writeBPS: writeBPS,
            // Nine days up: about a terabyte each way, as on a Mac that builds code.
            totals: DiskTotals(
                bytesRead: 972_790_000_000 + UInt64(tick) * 9_000_000,
                bytesWritten: 1_090_000_000_000 + UInt64(tick) * 4_000_000,
                reads: 33_143_868 + UInt64(tick) * 180,
                writes: 56_922_471 + UInt64(tick) * 240
            ),
            readsPerSecond: readBPS / 48000,
            writesPerSecond: writeBPS / 36000
        )
    }
}

public actor SimulatedNetworkSource: NetworkSource {
    private let down: Wander
    private let up: Wander
    private var tick = 0

    public init(seed: UInt64 = 0x0E7) {
        down = Wander(seed: seed, base: 0.1, amplitude: 0.08, spikeChance: 0.05)
        up = Wander(seed: seed &+ 1, base: 0.04, amplitude: 0.03, spikeChance: 0.02)
    }

    public func sample() async throws -> NetworkStats {
        defer { tick += 1 }
        return NetworkStats(
            inBPS: down.value(at: tick) * 12_000_000,
            outBPS: up.value(at: tick) * 3_000_000,
            primaryInterface: "en0"
        )
    }
}

public actor SimulatedGPUSource: GPUSource {
    private let wander: Wander
    private var tick = 0

    public init(seed: UInt64 = 0x6A0) {
        wander = Wander(seed: seed, base: 0.12, amplitude: 0.1, spikeChance: 0.04)
    }

    public func sample() async throws -> GPUStats? {
        defer { tick += 1 }
        return GPUStats(
            name: "Apple M5 Pro",
            utilizationPercent: wander.value(at: tick) * 100,
            memoryInUseBytes: 2_400_000_000
        )
    }

    public func clientGPUTime() async -> [Int32: UInt64] {
        [:]
    }
}

public actor SimulatedBatterySource: BatterySource {
    private let hasBattery: Bool
    private var tick = 0

    /// Pass `hasBattery: false` to simulate a desktop Mac.
    public init(hasBattery: Bool = true) {
        self.hasBattery = hasBattery
    }

    public func sample() async throws -> BatteryStats? {
        defer { tick += 1 }
        guard hasBattery else {
            return nil
        }
        // Drains a tenth of a percent per tick from 84%, floors at 20%.
        let percent = max(20, 84 - Double(tick) * 0.1)
        return BatteryStats(
            percent: percent,
            isCharging: false,
            source: .battery,
            timeRemaining: .seconds(Int(percent / 84 * 5.5 * 3600)),
            cycleCount: 212,
            maxCapacityPercent: 96,
            powerDrawWatts: 11.4,
            temperatureCelsius: 29.5
        )
    }
}

public actor SimulatedSensorSource: SensorSource {
    private let wander: Wander
    private let hasFans: Bool
    private var tick = 0

    /// Pass `hasFans: false` to simulate a fanless Mac.
    public init(seed: UInt64 = 0x7E3, hasFans: Bool = true) {
        wander = Wander(seed: seed, base: 0.4, amplitude: 0.15, spikeChance: 0.02)
        self.hasFans = hasFans
    }

    public func sample() async throws -> SensorStats {
        defer { tick += 1 }
        let heat = wander.value(at: tick)
        return SensorStats(
            temperatures: [
                TemperatureReading(id: "cpu", name: "CPU", celsius: 38 + heat * 50),
                TemperatureReading(id: "gpu", name: "GPU", celsius: 35 + heat * 40),
            ],
            fans: hasFans ? [FanReading(id: 0, rpm: 1200 + heat * 3000, minRPM: 1200, maxRPM: 5800)] : [],
            peripherals: [
                PeripheralBattery(id: "airpods", name: "AirPods Pro", kind: .airPods, percent: 70),
                PeripheralBattery(id: "trackpad", name: "Magic Trackpad", kind: .trackpad, percent: 45),
            ]
        )
    }
}

/// Accessories whose batteries drain over the day and charge overnight (D-094).
public actor SimulatedPeripheralSource: PeripheralBatterySource {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func peripherals() -> [PeripheralBattery] {
        let hour = Double(Calendar.current.component(.hour, from: now()))
        return [
            PeripheralBattery(id: "airpods", name: "AirPods Pro", kind: .airPods, percent: max(10, 100 - hour * 3.5)),
            PeripheralBattery(id: "trackpad", name: "Magic Trackpad", kind: .trackpad, percent: 45),
        ]
    }
}

/// A couple of crashes and a hang, for previews and simulated mode.
public struct SimulatedCrashReports: CrashReportSource {
    public init() {}

    public func reports(since date: Date) async -> [CrashReport] {
        let now = Date()
        return [
            CrashReport(id: "1", at: now - 3600 * 5, appName: "Xcode", bundleID: "com.apple.dt.Xcode", kind: .crash, path: "/dev/null"),
            CrashReport(id: "2", at: now - 86400 * 2, appName: "Xcode", bundleID: "com.apple.dt.Xcode", kind: .crash, path: "/dev/null"),
            CrashReport(id: "3", at: now - 86400 * 3, appName: "Safari", bundleID: "com.apple.Safari", kind: .hang, path: "/dev/null"),
        ].filter { $0.at >= date }
    }
}

/// One update waiting, so previews and screenshots show the Checkup item (D-120).
public struct SimulatedSoftwareUpdates: SoftwareUpdateSource {
    public init() {}

    public func pending() async -> [PendingUpdate] {
        [PendingUpdate(name: "macOS Tahoe", version: "26.1")]
    }

    /// The first app given, updated three days ago, and macOS ten days ago.
    public func installed(apps: [AppIdentity], since: Date) async -> [InstalledUpdate] {
        let now = Date()
        var updates = [InstalledUpdate(app: nil, name: "macOS", version: "26.0.1", installedAt: now.addingTimeInterval(-10 * 86400))]
        if let app = apps.first {
            updates.insert(
                InstalledUpdate(app: app, name: app.name, version: "16.2", installedAt: now.addingTimeInterval(-3 * 86400)),
                at: 0
            )
        }
        return updates.filter { $0.installedAt >= since }
    }
}

/// What macOS flagged (D-212), made up: one heavy writer, one Spotlight catch-up, one memory kill.
public struct SimulatedMacReports: MacReportSource {
    public init() {}

    public func macReports(since: Date) async -> [MacReport] {
        let now = Date()
        return [
            MacReport(
                id: "sim-writes", at: now - 2 * 86400, kind: .diskWrites(bytes: 137e9, seconds: 11400),
                process: "Google Chrome Helper", ownerBundleID: "com.google.Chrome", path: "/dev/null"
            ),
            MacReport(
                id: "sim-spotlight", at: now - 4 * 86400, kind: .diskWrites(bytes: 8.6e9, seconds: 55000),
                process: "mds_stores", ownerBundleID: "com.apple.Spotlight", path: "/dev/null"
            ),
            MacReport(id: "sim-memory", at: now - 6 * 86400, kind: .memoryKill, process: "Safari", ownerBundleID: nil, path: "/dev/null"),
        ].filter { $0.at >= since }
    }
}
