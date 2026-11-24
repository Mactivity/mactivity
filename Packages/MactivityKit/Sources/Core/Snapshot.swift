import Foundation

/// One raw reading of one process, before it is attributed to an app. Counters are cumulative
/// since the process started; the sampler turns them into rates by diffing two readings.
public struct ProcessReading: Hashable, Sendable, Codable, Identifiable {
    public let pid: Int32
    public let parentPID: Int32
    public let uid: UInt32
    /// Short name (`pbi_name` / `pbi_comm`).
    public let name: String
    /// Full executable path, when readable.
    public let executablePath: String?
    public let startTime: Date
    /// User + system CPU time.
    public let cpuTime: Duration
    /// `ri_phys_footprint`, the number Activity Monitor calls "Memory".
    public let footprintBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    /// `ri_energy_nj`: the energy the process's own threads used, in nanojoules (D-109).
    public let energyNJ: UInt64
    /// False when the kernel returned partial data (other-user or root processes without the helper).
    public let isComplete: Bool
    /// Interrupt plus package-idle wakeups since start (`ri_interrupt_wkups` + `ri_pkg_idle_wkups`),
    /// for Energy Impact.
    public let wakeups: UInt64

    public var id: Int32 {
        pid
    }

    public init(
        pid: Int32,
        parentPID: Int32,
        uid: UInt32,
        name: String,
        executablePath: String?,
        startTime: Date,
        cpuTime: Duration,
        footprintBytes: UInt64,
        diskReadBytes: UInt64,
        diskWriteBytes: UInt64,
        energyNJ: UInt64,
        isComplete: Bool,
        wakeups: UInt64 = 0
    ) {
        self.wakeups = wakeups
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.name = name
        self.executablePath = executablePath
        self.startTime = startTime
        self.cpuTime = cpuTime
        self.footprintBytes = footprintBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.energyNJ = energyNJ
        self.isComplete = isComplete
    }
}

/// One process in a snapshot: attributed to an app, with rates for the last interval.
public struct ProcessSample: Hashable, Sendable, Codable, Identifiable {
    public let pid: Int32
    public let app: AppIdentity.ID
    public let name: String
    public let cpuPercent: Double
    public let footprintBytes: UInt64
    public let diskReadBPS: Double
    public let diskWriteBPS: Double
    public let energyMW: Double?
    /// Nil when per-process network figures are unavailable (spec 6.5).
    public let netInBPS: Double?
    public let netOutBPS: Double?
    /// Nil when per-process GPU figures are unavailable (spec 6.6).
    public let gpuPercent: Double?
    /// Activity Monitor-style Energy Impact over the interval; nil when counters aren't readable.
    public let energyImpact: Double?

    public var id: Int32 {
        pid
    }

    public init(
        pid: Int32,
        app: AppIdentity.ID,
        name: String,
        cpuPercent: Double,
        footprintBytes: UInt64,
        diskReadBPS: Double,
        diskWriteBPS: Double,
        energyMW: Double?,
        netInBPS: Double?,
        netOutBPS: Double?,
        gpuPercent: Double?,
        energyImpact: Double? = nil
    ) {
        self.energyImpact = energyImpact
        self.pid = pid
        self.app = app
        self.name = name
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
        self.diskReadBPS = diskReadBPS
        self.diskWriteBPS = diskWriteBPS
        self.energyMW = energyMW
        self.netInBPS = netInBPS
        self.netOutBPS = netOutBPS
        self.gpuPercent = gpuPercent
    }
}

extension ProcessSample {
    /// The same sample with network rates set. A copy of every other field, so adding a field
    /// to `ProcessSample` can't silently drop it here (rebuilding it by hand once lost Energy
    /// Impact, D-074).
    public func withNetwork(inBPS: Double?, outBPS: Double?) -> ProcessSample {
        ProcessSample(
            pid: pid, app: app, name: name, cpuPercent: cpuPercent, footprintBytes: footprintBytes,
            diskReadBPS: diskReadBPS, diskWriteBPS: diskWriteBPS, energyMW: energyMW,
            netInBPS: inBPS, netOutBPS: outBPS, gpuPercent: gpuPercent, energyImpact: energyImpact
        )
    }

    /// The figure for one metric, or nil when that metric isn't available per process.
    public func value(for metric: Metric) -> Double? {
        switch metric {
        case .cpu: cpuPercent
        case .memory: Double(footprintBytes)
        case .energy: energyMW
        case .diskRead: diskReadBPS
        case .diskWrite: diskWriteBPS
        case .netIn: netInBPS
        case .netOut: netOutBPS
        case .gpu: gpuPercent
        case .energyImpact: energyImpact
        case .cpuTemperature, .gpuTemperature, .fanSpeed, .thermalPressure,
             .batteryLevel, .memoryPressure, .swapUsed, .diskFree, .onBattery, .powerDraw, .batteryTempCharging, .batteryTempInUse: nil
        }
    }
}

/// Per-app totals: the sum of that app's processes, never double counted.
public struct AppAggregate: Hashable, Sendable, Codable, Identifiable {
    public let app: AppIdentity
    public let processCount: Int
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let energyMW: Double?
    public let diskReadBPS: Double
    public let diskWriteBPS: Double
    public let netInBPS: Double?
    public let netOutBPS: Double?
    public let gpuPercent: Double?
    public let energyImpact: Double?

    public var id: AppIdentity.ID {
        app.id
    }

    public init(
        app: AppIdentity,
        processCount: Int,
        cpuPercent: Double,
        memoryBytes: UInt64,
        energyMW: Double?,
        diskReadBPS: Double,
        diskWriteBPS: Double,
        netInBPS: Double?,
        netOutBPS: Double?,
        gpuPercent: Double?,
        energyImpact: Double? = nil
    ) {
        self.energyImpact = energyImpact
        self.app = app
        self.processCount = processCount
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.energyMW = energyMW
        self.diskReadBPS = diskReadBPS
        self.diskWriteBPS = diskWriteBPS
        self.netInBPS = netInBPS
        self.netOutBPS = netOutBPS
        self.gpuPercent = gpuPercent
    }

    /// The figure for one metric, or nil when that metric isn't available per app.
    public func value(for metric: Metric) -> Double? {
        switch metric {
        case .cpu: cpuPercent
        case .memory: Double(memoryBytes)
        case .energy: energyMW
        case .diskRead: diskReadBPS
        case .diskWrite: diskWriteBPS
        case .netIn: netInBPS
        case .netOut: netOutBPS
        case .gpu: gpuPercent
        case .energyImpact: energyImpact
        case .cpuTemperature, .gpuTemperature, .fanSpeed, .thermalPressure,
             .batteryLevel, .memoryPressure, .swapUsed, .diskFree, .onBattery, .powerDraw, .batteryTempCharging, .batteryTempInUse: nil
        }
    }

    /// The one order every top-apps list uses (menu bar, app list, `mactivity top`, Shortcuts):
    /// the figure highest first, apps without one last; ties by name in Finder order
    /// (`localizedStandardCompare`, so "App 2" comes before "App 10"), then by id, so two apps
    /// with the same name and figure never swap places between ticks.
    public static func ranked(_ apps: [AppAggregate], by value: (AppAggregate) -> Double?) -> [AppAggregate] {
        apps.map { (app: $0, value: value($0) ?? -1) }
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : nameOrder(lhs.app, rhs.app)
            }
            .map(\.app)
    }

    /// The tiebreak of `ranked`: name in Finder order, then id. For any list of apps sorted by
    /// something else, so equal rows keep a stable order.
    public static func nameOrder(_ lhs: AppAggregate, _ rhs: AppAggregate) -> Bool {
        switch lhs.app.name.localizedStandardCompare(rhs.app.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.id < rhs.id
        }
    }
}

/// Everything one sampler tick produced. Published once per tick; UI, History, and Alerts
/// all read the same value (spec 6.13).
public struct Snapshot: Hashable, Sendable, Codable {
    public let at: Date
    /// Wall time since the previous snapshot, used for every rate in this one.
    public let interval: Duration
    public let system: SystemSample
    public let apps: [AppAggregate]
    /// Per-process figures. While the macOS row is collapsed, macOS's own processes whose usage
    /// wasn't read are left out; they're counted in that row and in `processCount` (D-086).
    public let processes: [ProcessSample]
    /// Every running process, including the ones `processes` leaves out.
    public let processCount: Int
    /// The processes attributed to macOS, including the ones `processes` leaves out. Not saved.
    public let systemPIDs: Set<Int32>

    public init(
        at: Date,
        interval: Duration,
        system: SystemSample,
        apps: [AppAggregate],
        processes: [ProcessSample],
        processCount: Int? = nil,
        systemPIDs: Set<Int32> = []
    ) {
        self.at = at
        self.interval = interval
        self.system = system
        self.apps = apps
        self.processes = processes
        self.processCount = processCount ?? processes.count
        self.systemPIDs = systemPIDs
    }

    private enum CodingKeys: String, CodingKey {
        case at, interval, system, apps, processes, processCount
    }

    /// Snapshots saved before `processCount` existed (fixtures) count their processes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decode(Date.self, forKey: .at)
        interval = try container.decode(Duration.self, forKey: .interval)
        system = try container.decode(SystemSample.self, forKey: .system)
        apps = try container.decode([AppAggregate].self, forKey: .apps)
        processes = try container.decode([ProcessSample].self, forKey: .processes)
        processCount = try container.decodeIfPresent(Int.self, forKey: .processCount) ?? processes.count
        systemPIDs = []
    }

    /// Power drawn by every app together, in milliwatts; nil when no app reports any.
    public var totalEnergyMW: Double? {
        let values = apps.compactMap(\.energyMW)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// Every app's Energy Impact added up; nil when no app reports any.
    public var totalEnergyImpact: Double? {
        let values = apps.compactMap(\.energyImpact)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// One system-wide figure: the system sample's where it has one, the apps' sum for energy.
    /// What History records each minute and a recording writes each snapshot.
    public func systemValue(for metric: Metric) -> Double? {
        let system = system
        return switch metric {
        case .cpu: system.cpu.totalPercent
        case .memory: Double(system.memory.usedBytes)
        case .energy: totalEnergyMW
        case .diskRead: system.disk.readBPS
        case .diskWrite: system.disk.writeBPS
        case .netIn: system.network.inBPS
        case .netOut: system.network.outBPS
        case .gpu: system.gpu?.utilizationPercent
        case .energyImpact: totalEnergyImpact
        case .cpuTemperature: system.sensors?.temperature(id: "cpu")
        case .gpuTemperature: system.sensors?.temperature(id: "gpu")
        case .fanSpeed: system.sensors.flatMap { $0.fans.isEmpty ? nil : $0.fans.map(\.rpm).max() }
        case .thermalPressure: Double(system.thermal.rank)
        case .batteryLevel: system.battery?.percent
        case .memoryPressure: Double(100 - min(100, max(0, system.memory.availableLevel)))
        case .swapUsed: Double(system.memory.swapUsedBytes)
        case .diskFree: system.disk.bootVolume.map { Double($0.freeBytes) }
        case .onBattery: system.battery.map { $0.source == .battery ? 1 : 0 }
        // The whole Mac in milliwatts (D-258). On battery, what leaves the battery is the whole
        // Mac too; plugged in, that reads 0, so without the whole-Mac reading nothing is recorded.
        case .powerDraw: system.battery.flatMap { battery in
                (battery.systemLoadWatts ?? (battery.source == .battery ? battery.powerDrawWatts : nil)).map { $0 * 1000 }
            }
        // Split by what the battery was doing at that moment (D-275).
        case .batteryTempCharging: system.battery.flatMap { $0.isCharging ? $0.temperatureCelsius : nil }
        case .batteryTempInUse: system.battery.flatMap { $0.isCharging ? nil : $0.temperatureCelsius }
        }
    }

    /// Apps sorted by a metric, highest first (`AppAggregate.ranked`). Apps without a figure for
    /// that metric sort last.
    public func topApps(by metric: Metric, limit: Int) -> [AppAggregate] {
        Array(AppAggregate.ranked(apps) { $0.value(for: metric) }.prefix(limit))
    }
}
