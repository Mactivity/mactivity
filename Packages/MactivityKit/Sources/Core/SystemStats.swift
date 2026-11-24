import Foundation

// System-wide figures, one struct per data source (spec 6.3–6.10).
// Percentages are 0...100. Byte counts are bytes. Rates are bytes per second.

/// A group of cores that share a performance level (`hw.perflevelN`).
///
/// Apple silicon doesn't always have "P" and "E" cores: an M5 Pro reports levels named
/// "Super" and "Performance". So the split is by level, named by the kernel, not a fixed pair.
public struct CoreCluster: Hashable, Sendable, Codable {
    /// Kernel name for the level, e.g. "Performance", "Efficiency", "Super".
    public let name: String
    /// 0 is the most performant level.
    public let level: Int
    /// Indexes into `CPUStats.perCorePercent`.
    public let coreIndexes: [Int]
    /// Average load across the cluster's cores, 0...100.
    public let percent: Double

    public init(name: String, level: Int, coreIndexes: [Int], percent: Double) {
        self.name = name
        self.level = level
        self.coreIndexes = coreIndexes
        self.percent = percent
    }
}

public struct LoadAverage: Hashable, Sendable, Codable {
    public let one: Double
    public let five: Double
    public let fifteen: Double

    public init(one: Double, five: Double, fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }

    public static let zero = LoadAverage(one: 0, five: 0, fifteen: 0)
}

public struct CPUStats: Hashable, Sendable, Codable {
    /// User + system + nice, across all cores, 0...100.
    public let totalPercent: Double
    public let userPercent: Double
    public let systemPercent: Double
    public let perCorePercent: [Double]
    public let clusters: [CoreCluster]
    public let loadAverage: LoadAverage

    public init(
        totalPercent: Double,
        userPercent: Double,
        systemPercent: Double,
        perCorePercent: [Double],
        clusters: [CoreCluster],
        loadAverage: LoadAverage
    ) {
        self.totalPercent = totalPercent
        self.userPercent = userPercent
        self.systemPercent = systemPercent
        self.perCorePercent = perCorePercent
        self.clusters = clusters
        self.loadAverage = loadAverage
    }

    public var idlePercent: Double {
        max(0, 100 - totalPercent)
    }

    public var status: MetricStatus {
        MetricStatus(cpuPercent: totalPercent)
    }
}

public enum MemoryPressure: String, Hashable, Sendable, Codable {
    case normal, warning, critical
}

public struct MemoryStats: Hashable, Sendable, Codable {
    public let totalBytes: UInt64
    /// App + wired + compressed, the number Activity Monitor calls "Memory Used".
    public let usedBytes: UInt64
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedFilesBytes: UInt64
    public let swapUsedBytes: UInt64
    public let pressure: MemoryPressure
    /// `kern.memorystatus_level`: percent of memory available, 0...100.
    public let availableLevel: Int

    public init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        appBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedFilesBytes: UInt64,
        swapUsedBytes: UInt64,
        pressure: MemoryPressure,
        availableLevel: Int
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFilesBytes = cachedFilesBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
        self.availableLevel = availableLevel
    }

    public var usedFraction: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes)
    }

    public var status: MetricStatus {
        MetricStatus(memoryPressure: pressure)
    }
}

public struct VolumeStats: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let totalBytes: UInt64
    public let freeBytes: UInt64

    public init(id: String, name: String, totalBytes: UInt64, freeBytes: UInt64) {
        self.id = id
        self.name = name
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    public var freeFraction: Double {
        totalBytes == 0 ? 0 : Double(freeBytes) / Double(totalBytes)
    }
}

/// Everything the Mac's physical disks have done since they attached (at startup, for the
/// internal one): Activity Monitor's Data read, Data written, Reads in, Writes out (D-097).
public struct DiskTotals: Hashable, Sendable, Codable {
    public let bytesRead: UInt64
    public let bytesWritten: UInt64
    /// Nil when a driver doesn't report operation counts.
    public let reads: UInt64?
    public let writes: UInt64?

    public init(bytesRead: UInt64, bytesWritten: UInt64, reads: UInt64?, writes: UInt64?) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.reads = reads
        self.writes = writes
    }
}

public struct DiskStats: Hashable, Sendable, Codable {
    public let volumes: [VolumeStats]
    public let readBPS: Double
    public let writeBPS: Double
    /// Since startup, summed over the physical disks.
    public let totals: DiskTotals?
    /// Operations a second, like Activity Monitor's Reads in/sec and Writes out/sec.
    public let readsPerSecond: Double?
    public let writesPerSecond: Double?

    public init(
        volumes: [VolumeStats], readBPS: Double, writeBPS: Double,
        totals: DiskTotals? = nil, readsPerSecond: Double? = nil, writesPerSecond: Double? = nil
    ) {
        self.volumes = volumes
        self.readBPS = readBPS
        self.writeBPS = writeBPS
        self.totals = totals
        self.readsPerSecond = readsPerSecond
        self.writesPerSecond = writesPerSecond
    }

    /// The boot volume, if present. Sources list it first.
    public var bootVolume: VolumeStats? {
        volumes.first
    }
}

public struct NetworkStats: Hashable, Sendable, Codable {
    public let inBPS: Double
    public let outBPS: Double
    /// BSD name of the primary interface, e.g. "en0".
    public let primaryInterface: String?

    public init(inBPS: Double, outBPS: Double, primaryInterface: String?) {
        self.inBPS = inBPS
        self.outBPS = outBPS
        self.primaryInterface = primaryInterface
    }
}

public struct GPUStats: Hashable, Sendable, Codable {
    public let name: String
    public let utilizationPercent: Double
    public let memoryInUseBytes: UInt64?

    public init(name: String, utilizationPercent: Double, memoryInUseBytes: UInt64?) {
        self.name = name
        self.utilizationPercent = utilizationPercent
        self.memoryInUseBytes = memoryInUseBytes
    }
}

public struct BatteryStats: Hashable, Sendable, Codable {
    public enum PowerSource: String, Hashable, Sendable, Codable {
        case battery, ac
    }

    public let percent: Double
    public let isCharging: Bool
    public let source: PowerSource
    /// Time to empty on battery, time to full on AC. Nil while the system is still estimating.
    public let timeRemaining: Duration?
    public let cycleCount: Int?
    public let maxCapacityPercent: Double?
    /// Watts leaving the battery: positive while discharging, 0 on the adapter.
    public let powerDrawWatts: Double?
    /// What the whole Mac draws in watts, from the adapter or the battery (D-109). Nil where the
    /// battery doesn't report it.
    public let systemLoadWatts: Double?
    /// The connected power adapter's rating in watts. Nil on battery or when unknown.
    public let adapterWatts: Double?
    /// The battery's own temperature in °C (D-275). Nil where it can't be read.
    public let temperatureCelsius: Double?
    /// What actually comes in from the adapter, in watts: the Mac's load plus what goes into the
    /// battery (D-274). Nil on battery or when unknown.
    public let adapterInputWatts: Double?

    public init(
        percent: Double,
        isCharging: Bool,
        source: PowerSource,
        timeRemaining: Duration?,
        cycleCount: Int?,
        maxCapacityPercent: Double?,
        powerDrawWatts: Double?,
        systemLoadWatts: Double? = nil,
        adapterWatts: Double? = nil,
        temperatureCelsius: Double? = nil,
        adapterInputWatts: Double? = nil
    ) {
        self.percent = percent
        self.isCharging = isCharging
        self.source = source
        self.timeRemaining = timeRemaining
        self.cycleCount = cycleCount
        self.maxCapacityPercent = maxCapacityPercent
        self.powerDrawWatts = powerDrawWatts
        self.systemLoadWatts = systemLoadWatts
        self.adapterWatts = adapterWatts
        self.temperatureCelsius = temperatureCelsius
        self.adapterInputWatts = adapterInputWatts
    }

    /// Critical at 10% or less on battery, elevated at 20% or less; always normal on the power
    /// adapter.
    public var status: MetricStatus {
        guard source == .battery else {
            return .normal
        }
        return percent <= 10 ? .critical : percent <= 20 ? .elevated : .normal
    }
}

public struct TemperatureReading: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let celsius: Double

    public init(id: String, name: String, celsius: Double) {
        self.id = id
        self.name = name
        self.celsius = celsius
    }
}

public struct FanReading: Hashable, Sendable, Codable, Identifiable {
    public let id: Int
    public let rpm: Double
    public let minRPM: Double?
    public let maxRPM: Double?

    public init(id: Int, rpm: Double, minRPM: Double?, maxRPM: Double?) {
        self.id = id
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }
}

public struct PeripheralBattery: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case airPods, mouse, keyboard, trackpad, other
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let percent: Double

    public init(id: String, name: String, kind: Kind, percent: Double) {
        self.id = id
        self.name = name
        self.kind = kind
        self.percent = percent
    }
}

public struct SensorStats: Hashable, Sendable, Codable {
    public let temperatures: [TemperatureReading]
    /// Empty on fanless Macs. The UI hides the fan section rather than showing zero.
    public let fans: [FanReading]
    public let peripherals: [PeripheralBattery]

    public init(temperatures: [TemperatureReading], fans: [FanReading], peripherals: [PeripheralBattery]) {
        self.temperatures = temperatures
        self.fans = fans
        self.peripherals = peripherals
    }

    /// One temperature by sensor group id ("cpu", "gpu"), nil when this Mac has no such sensor.
    public func temperature(id: String) -> Double? {
        temperatures.first { $0.id == id }?.celsius
    }
}

/// `ProcessInfo.thermalState`, as a Core value.
public enum ThermalPressure: String, Hashable, Sendable, Codable, Comparable {
    case nominal, fair, serious, critical

    /// 0 nominal … 3 critical.
    public var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }

    public static func < (lhs: ThermalPressure, rhs: ThermalPressure) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct SystemSample: Hashable, Sendable, Codable {
    public let cpu: CPUStats
    public let memory: MemoryStats
    public let disk: DiskStats
    public let network: NetworkStats
    public let gpu: GPUStats?
    public let battery: BatteryStats?
    public let sensors: SensorStats?
    public let thermal: ThermalPressure
    public let uptime: Duration

    public init(
        cpu: CPUStats,
        memory: MemoryStats,
        disk: DiskStats,
        network: NetworkStats,
        gpu: GPUStats?,
        battery: BatteryStats?,
        sensors: SensorStats?,
        thermal: ThermalPressure,
        uptime: Duration
    ) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.gpu = gpu
        self.battery = battery
        self.sensors = sensors
        self.thermal = thermal
        self.uptime = uptime
    }
}
