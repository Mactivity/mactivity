import Core
import Foundation
import SwiftUI

/// One figure in a secondary-figures grid.
public struct Figure: Identifiable, Hashable, Sendable {
    public let label: String
    public let value: String
    /// What the figure means, in a sentence or two, for terms like Wired or Load average. Shown
    /// on hover.
    public let help: String?

    public var id: String {
        label
    }

    public init(_ label: String, _ value: String, help: String? = nil) {
        self.label = label
        self.value = value
        self.help = help
    }

    /// The hover text: the whole figure, which may be truncated in its cell, then what it means.
    public var hoverText: String {
        let whole = String(format: FigureWords.hoverFormat, label, value)
        guard let help else {
            return whole
        }
        return whole + "\n" + help
    }
}

/// The six metric tabs. Each knows how to read its headline, status, sparkline value, and
/// secondary figures out of a snapshot, so every tab is built from the same skeleton (spec 4.3).
public enum MetricTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// One order everywhere: the two processors, memory and storage, network, then power (D-082).
    case cpu, gpu, memory, disk, network, battery

    public var id: String {
        rawValue
    }

    /// The metric's color: its sidebar symbol, its sparkline, its history bars (D-057).
    public var tint: Color {
        sidebarItem.tint
    }

    public var sidebarItem: SidebarItem {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .disk: .disk
        case .network: .network
        case .gpu: .gpu
        case .battery: .battery
        }
    }

    public var title: String {
        sidebarItem.title
    }

    public var symbol: String {
        sidebarItem.symbol
    }

    /// "Energy" for the Battery tab on a Mac without a battery (`SidebarItem.title(hasBattery:)`).
    public func title(hasBattery: Bool) -> String {
        sidebarItem.title(hasBattery: hasBattery)
    }

    public func symbol(hasBattery: Bool) -> String {
        sidebarItem.symbol(hasBattery: hasBattery)
    }

    /// The per-app metric the app list sorts by.
    public var appMetric: Metric {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .disk: .diskWrite
        case .network: .netIn
        case .gpu: .gpu
        case .battery: .energyImpact
        }
    }

    /// Series drawn in the history strip, first one filled.
    public var historyMetrics: [Metric] {
        switch self {
        case .cpu: [.cpu]
        case .memory: [.memory]
        case .disk: [.diskWrite, .diskRead]
        case .network: [.netIn, .netOut]
        case .gpu: [.gpu]
        case .battery: [.energyImpact]
        }
    }

    /// Fixed y domain for percentages; nil scales to the data.
    public var sparklineDomain: ClosedRange<Double>? {
        sparklineDomain(hasBattery: true)
    }

    /// Without a battery, the Battery tab plots the apps' power, which has no fixed top.
    public func sparklineDomain(hasBattery: Bool) -> ClosedRange<Double>? {
        switch self {
        case .cpu, .gpu, .memory: 0 ... 100
        case .battery: hasBattery ? 0 ... 100 : nil
        case .disk, .network: nil
        }
    }

    /// What the sparkline's values are, for VoiceOver.
    public func sparklineUnit(hasBattery: Bool) -> SparklineUnit {
        switch self {
        case .cpu, .gpu, .memory: .percent
        case .disk, .network: .rate
        case .battery: hasBattery ? .percent : .power
        }
    }

    /// The value the live sparkline plots (0...100 for percentages).
    public func sparklineValue(_ snapshot: Snapshot) -> Double? {
        let system = snapshot.system
        switch self {
        case .cpu: return system.cpu.totalPercent
        case .memory: return system.memory.usedFraction * 100
        case .disk: return system.disk.readBPS + system.disk.writeBPS
        case .network: return system.network.inBPS + system.network.outBPS
        case .gpu: return system.gpu?.utilizationPercent
        case .battery: return system.battery.map(\.percent) ?? snapshot.totalEnergyMW ?? 0
        }
    }

    /// Normal / Elevated / Critical, or nil where a status word means nothing (network).
    public func status(_ snapshot: Snapshot) -> MetricStatus? {
        let system = snapshot.system
        switch self {
        case .cpu:
            return system.cpu.status
        case .memory:
            return system.memory.status
        case .disk:
            return system.disk.bootVolume.map { MetricStatus(diskFreeFraction: $0.freeFraction) }
        case .network:
            return nil
        case .gpu:
            return system.gpu.map { MetricStatus(cpuPercent: $0.utilizationPercent) }
        case .battery:
            return system.battery?.status
        }
    }

    /// 3–6 secondary figures (spec 4.3 step 2).
    public func figures(_ snapshot: Snapshot) -> [Figure] {
        switch self {
        case .cpu: Self.cpuFigures(snapshot.system.cpu)
        case .memory: Self.memoryFigures(snapshot.system.memory)
        case .disk: Self.diskFigures(snapshot.system.disk)
        case .network: Self.networkFigures(snapshot.system.network)
        case .gpu: Self.gpuFigures(snapshot)
        case .battery: Self.batteryFigures(snapshot)
        }
    }

    private static func cpuFigures(_ cpu: CPUStats) -> [Figure] {
        let loadText = Formatters.loadAverage(cpu.loadAverage)
        return [
            Figure(FigureWords.user, Formatters.percent(cpu.userPercent)),
            Figure(FigureWords.system, Formatters.percent(cpu.systemPercent)),
            Figure(FigureWords.idle, Formatters.percent(cpu.idlePercent)),
        ] + cpu.clusters.map { cluster in
            Figure(
                clusterLabel(cluster.name, count: cluster.coreIndexes.count),
                Formatters.percent(cluster.percent),
                help: FigureHelp.cluster(cluster.name)
            )
        }
            + [Figure(FigureWords.loadAverage, loadText, help: FigureHelp.loadAverage)]
    }

    /// The kernel names clusters in English (`hw.perflevelN.name`): the known names get a whole
    /// localized label, anything else keeps the kernel's word.
    private static func clusterLabel(_ name: String, count: Int) -> String {
        switch name {
        case "Super":
            String(localized: "Super cores (\(count))", bundle: .strings, comment: "CPU figure: the Super core cluster and its core count")
        case "Performance":
            String(
                localized: "Performance cores (\(count))", bundle: .strings,
                comment: "CPU figure: the Performance core cluster and its core count"
            )
        case "Efficiency":
            String(
                localized: "Efficiency cores (\(count))", bundle: .strings,
                comment: "CPU figure: the Efficiency core cluster and its core count"
            )
        default:
            String(
                localized: "\(name) cores (\(count))", bundle: .strings,
                comment: "CPU figure: a core cluster's name as macOS reports it (in English), and its core count"
            )
        }
    }

    private static func memoryFigures(_ memory: MemoryStats) -> [Figure] {
        [
            Figure(FigureWords.appMemory, Formatters.memory(memory.appBytes), help: FigureHelp.appMemory),
            Figure(FigureWords.wired, Formatters.memory(memory.wiredBytes), help: FigureHelp.wired),
            Figure(FigureWords.compressed, Formatters.memory(memory.compressedBytes), help: FigureHelp.compressed),
            Figure(FigureWords.cachedFiles, Formatters.memory(memory.cachedFilesBytes), help: FigureHelp.cachedFiles),
            Figure(FigureWords.swapUsed, Formatters.memory(memory.swapUsedBytes), help: FigureHelp.swapUsed),
            Figure(FigureWords.pressure, memory.status.title, help: FigureHelp.pressure),
        ]
    }

    private static func diskFigures(_ disk: DiskStats) -> [Figure] {
        var figures = [
            Figure(FigureWords.reading, Formatters.rate(disk.readBPS), help: FigureHelp.diskRate),
            Figure(FigureWords.writing, Formatters.rate(disk.writeBPS), help: FigureHelp.diskRate),
        ]
        if let boot = disk.bootVolume {
            figures.append(Figure(FigureWords.capacity, Formatters.bytes(boot.totalBytes)))
            figures.append(Figure(FigureWords.free, Formatters.percent(boot.freeFraction * 100)))
        }
        for volume in disk.volumes.dropFirst().prefix(2) {
            let free = String(localized: "\(Formatters.bytes(volume.freeBytes)) free", bundle: .strings, comment: "Free space on a volume")
            figures.append(Figure(volume.name, free))
        }
        return figures
    }

    private static func networkFigures(_ network: NetworkStats) -> [Figure] {
        [
            Figure(FigureWords.download, Formatters.rate(network.inBPS), help: FigureHelp.networkRate),
            Figure(FigureWords.upload, Formatters.rate(network.outBPS), help: FigureHelp.networkRate),
            Figure(FigureWords.interface, network.primaryInterface ?? FigureWords.noInterface),
        ]
    }

    /// What the headline card doesn't already say: it shows the utilization and the GPU's name,
    /// so these are its memory, the app drawing on it most, and its temperature where the Mac
    /// reports one.
    private static func gpuFigures(_ snapshot: Snapshot) -> [Figure] {
        guard let gpu = snapshot.system.gpu else {
            return [Figure(FigureWords.gpu, FigureWords.unavailable)]
        }
        var figures = [Figure(FigureWords.memoryInUse, gpu.memoryInUseBytes.map { Formatters.memory($0) } ?? "–")]
        if let top = snapshot.apps.filter({ ($0.gpuPercent ?? 0) >= 0.5 }).max(by: { ($0.gpuPercent ?? 0) < ($1.gpuPercent ?? 0) }),
           let percent = top.gpuPercent {
            figures.append(Figure(FigureWords.mostUsedBy, "\(top.app.name) \(Formatters.percent(percent))"))
        }
        if let sensor = snapshot.system.sensors?.temperatures.first(where: { $0.id == "gpu" }) {
            let label = String(localized: "\(sensor.name) temperature", bundle: .strings, comment: "A temperature sensor's name")
            figures.append(Figure(label, Formatters.temperature(celsius: sensor.celsius)))
        }
        return figures
    }

    private static func batteryFigures(_ snapshot: Snapshot) -> [Figure] {
        let power = snapshot.totalEnergyMW ?? 0
        guard let battery = snapshot.system.battery else {
            // The headline already shows the apps' power; the Energy Impact total goes beside it.
            let impact = snapshot.totalEnergyImpact ?? 0
            let figure = Figure(FigureWords.energyImpact, Formatters.metric(impact, .energyImpact), help: FigureHelp.energyImpact)
            return [figure] + sensorFigures(snapshot.system.sensors)
        }
        return batteryOnly(battery, power: power) + sensorFigures(snapshot.system.sensors)
    }

    /// Temperatures and fans (spec 5.6). Fanless Macs show no fan figure at all, not a zero
    /// (spec 6.10). Accessory batteries have their own card beside these (D-165).
    static func sensorFigures(_ sensors: SensorStats?) -> [Figure] {
        guard let sensors else {
            return []
        }
        var figures = sensors.temperatures.map { sensor in
            let label = String(localized: "\(sensor.name) temperature", bundle: .strings, comment: "A temperature sensor's name")
            return Figure(label, Formatters.temperature(celsius: sensor.celsius))
        }
        if !sensors.fans.isEmpty {
            let speeds = sensors.fans.map { $0.rpm < 1 ? FigureWords.fanOff : "\(Int($0.rpm.rounded()).formatted()) rpm" }
            figures.append(Figure(sensors.fans.count == 1 ? FigureWords.fan : FigureWords.fans, speeds.joined(separator: " · ")))
        }
        return figures
    }

    /// "Power adapter · 100 W", or "Battery" (D-109).
    nonisolated static func sourceText(_ battery: BatteryStats) -> String {
        guard battery.source == .ac else {
            return FigureWords.battery
        }
        guard let watts = battery.adapterWatts else {
            return FigureWords.powerAdapter
        }
        return "\(FigureWords.powerAdapter) · \(Formatters.power(milliwatts: watts * 1000))"
    }

    private static func batteryOnly(_ battery: BatteryStats, power: Double) -> [Figure] {
        [
            Figure(FigureWords.source, sourceText(battery), help: battery.adapterWatts == nil ? nil : FigureHelp.adapter),
            Figure(FigureWords.timeRemaining, battery.timeRemaining.map { Formatters.duration($0) } ?? "–"),
            Figure(FigureWords.cycleCount, battery.cycleCount.map(String.init) ?? "–", help: FigureHelp.cycleCount),
            Figure(FigureWords.maxCapacity, battery.maxCapacityPercent.map { Formatters.percent($0) } ?? "–", help: FigureHelp.maxCapacity),
            Figure(
                FigureWords.powerDraw,
                (battery.systemLoadWatts ?? battery.powerDrawWatts).map { Formatters.power(milliwatts: $0 * 1000) } ?? "–",
                help: FigureHelp.powerDraw
            ),
            Figure(FigureWords.appsPower, Formatters.power(milliwatts: power), help: FigureHelp.appsPower),
        ]
    }

    /// Why the app list might be empty or partial, shown in its header.
    public func appListNote(_ snapshot: Snapshot) -> String? {
        switch self {
        case .network where snapshot.apps.allSatisfy { $0.netInBPS == nil }:
            String(localized: "Per-app network figures aren't available on this Mac. Totals above are system-wide.", bundle: .strings)
        case .network:
            // NetworkStatistics sees only this user's sockets, and not WebKit's (D-047).
            String(localized: "Safari's and system services' traffic counts in the totals, not per app.", bundle: .strings)
        case .gpu where snapshot.apps.allSatisfy { $0.gpuPercent == nil }:
            String(localized: "Per-app GPU figures appear while this window is open.", bundle: .strings)
        default:
            nil
        }
    }
}

/// Figure labels, looked up once: the figures are rebuilt on every sample.
enum FigureWords {
    /// A figure's hover text: its label, then its value ("Wired: 3.2 GB").
    static let hoverFormat = String(
        localized: "figure.hover",
        defaultValue: "%1$@: %2$@",
        bundle: .strings,
        comment: "Help tag on a figure: its label, then its value, e.g. Wired: 3.2 GB"
    )
    static let user = String(localized: "User", bundle: .strings, comment: "CPU figure: time spent in user processes")
    static let system = String(localized: "System", bundle: .strings, comment: "CPU figure: time spent in the system")
    static let idle = String(localized: "Idle", bundle: .strings, comment: "CPU figure: idle time")
    static let loadAverage = String(localized: "Load average", bundle: .strings)
    static let appMemory = String(localized: "App memory", bundle: .strings)
    static let wired = String(localized: "Wired", bundle: .strings, comment: "Memory figure: wired memory")
    static let compressed = String(localized: "Compressed", bundle: .strings, comment: "Memory figure: compressed memory")
    static let cachedFiles = String(localized: "Cached files", bundle: .strings)
    static let swapUsed = String(localized: "Swap used", bundle: .strings)
    static let pressure = String(localized: "Pressure", bundle: .strings, comment: "Memory figure: memory pressure")
    static let reading = String(localized: "Reading", bundle: .strings, comment: "Disk figure: read rate")
    static let writing = String(localized: "Writing", bundle: .strings, comment: "Disk figure: write rate")
    static let capacity = String(localized: "Capacity", bundle: .strings, comment: "Disk figure: startup disk size")
    static let free = String(localized: "Free", bundle: .strings, comment: "Disk: free space (a figure label and a legend entry)")
    static let download = String(localized: "Download", bundle: .strings, comment: "Network figure: download rate")
    static let upload = String(localized: "Upload", bundle: .strings, comment: "Network figure: upload rate")
    static let interface = String(localized: "Interface", bundle: .strings, comment: "Network figure: primary interface")
    static let receivedToday = String(localized: "Received today", bundle: .strings, comment: "Network figure: downloaded since midnight")
    static let sentToday = String(localized: "Sent today", bundle: .strings, comment: "Network figure: uploaded since midnight")
    static let readToday = String(localized: "Read today", bundle: .strings, comment: "Disk figure: read from disk since midnight")
    static let writtenToday = String(localized: "Written today", bundle: .strings, comment: "Disk figure: written to disk since midnight")
    static let noInterface = String(
        localized: "network.interface.none",
        defaultValue: "None",
        bundle: .strings,
        comment: "Network figure: no primary interface (agrees with “interface”)"
    )
    static let gpu = String(localized: "GPU", bundle: .strings, comment: "GPU figure: the GPU's name")
    static let unavailable = String(localized: "Unavailable", bundle: .strings, comment: "GPU figure: no GPU readings")
    static let mostUsedBy = String(
        localized: "Most used by",
        bundle: .strings,
        comment: "GPU figure: the app using the GPU most, e.g. Safari 12%"
    )
    static let memoryInUse = String(localized: "Memory in use", bundle: .strings, comment: "GPU figure: GPU memory in use")
    static let appsPower = String(localized: "Apps' power", bundle: .strings, comment: "Battery figure: total power drawn by apps")
    static let energyImpact = Metric.energyImpact.title
    static let fanOff = String(localized: "fan.off", defaultValue: "Off", bundle: .strings, comment: "Fan speed: the fans are stopped")
    static let fan = String(localized: "Fan", bundle: .strings, comment: "Figure label, one fan")
    static let fans = String(localized: "Fans", bundle: .strings, comment: "Figure label, several fans")
    static let source = String(localized: "Source", bundle: .strings, comment: "Battery figure: power source")
    static let powerAdapter = String(localized: "Power adapter", bundle: .strings, comment: "Power source")
    static let battery = String(localized: "Battery", bundle: .strings, comment: "Power source")
    static let timeRemaining = String(localized: "Time remaining", bundle: .strings, comment: "Battery figure")
    static let cycleCount = String(localized: "Cycle count", bundle: .strings, comment: "Battery figure")
    static let maxCapacity = String(localized: "Max capacity", bundle: .strings, comment: "Battery figure: maximum capacity")
    static let powerDraw = String(localized: "Power draw", bundle: .strings, comment: "Battery figure")
}

/// What the less obvious figures mean: short, plain sentences shown on hover (and on the Overview's
/// memory legend). Looked up once.
enum FigureHelp {
    static let appMemory = String(localized: "Memory your apps and their processes are using right now.", bundle: .strings)
    static let wired = String(
        localized: "Memory macOS keeps for itself. It can't be compressed or moved to disk.",
        bundle: .strings,
        comment: "Help: wired memory"
    )
    static let compressed = String(
        localized: "Memory macOS squeezed to make room, instead of writing it to disk.",
        bundle: .strings,
        comment: "Help: compressed memory"
    )
    static let cachedFiles = String(
        localized: "Recently used files kept in memory so they open faster. macOS frees it as soon as apps need it.",
        bundle: .strings
    )
    static let swapUsed = String(
        localized: "Memory written to disk because RAM was full. A lot of it slows your Mac down.",
        bundle: .strings
    )
    static let pressure = String(
        localized: "How hard macOS is working to find free memory. Normal is fine, even when memory looks full.",
        bundle: .strings,
        comment: "Help: memory pressure; Normal is the status word"
    )
    static let loadAverage = String(
        localized: "How many processes were running or waiting for the CPU, averaged over the last 1, 5, and 15 minutes.",
        bundle: .strings
    )
    static let energyImpact = String(
        localized: """
        macOS's measure of how much power apps draw, the same score Activity Monitor shows. \
        It has no unit: higher means more power.
        """,
        bundle: .strings,
        comment: "Help: the Energy Impact figure on a Mac without a battery"
    )
    static let appsPower = String(
        localized: "Power all apps draw together, as macOS measures it.",
        bundle: .strings,
        comment: "Help: the Apps' power figure"
    )
    /// Units and terms, in plain words (D-258).
    static let powerDraw = String(
        localized: """
        What your whole Mac is using right now, display included. Plugged in, it comes from the charger; \
        otherwise from the battery. Watts (W) measure power: 1 W is 1,000 milliwatts (mW).
        """,
        bundle: .strings,
        comment: "Help: the Power draw figure"
    )
    static let adapter = String(
        localized: "The charger's rating in watts (W): the most power it can deliver.",
        bundle: .strings,
        comment: "Help: the Source figure, e.g. Power adapter · 96 W"
    )
    static let cycleCount = String(
        localized: "One cycle is a full battery's worth of charge used, all at once or over several days.",
        bundle: .strings,
        comment: "Help: battery cycle count"
    )
    static let maxCapacity = String(
        localized: "How much charge the battery holds now, compared with when it was new.",
        bundle: .strings,
        comment: "Help: battery maximum capacity"
    )
    static let networkRate = String(
        localized: """
        In bytes per second (B/s), like file sizes. Internet speeds are usually given in bits per second (bps): \
        8 bits make a byte, so 100 Mbps is about 12.5 MB/s.
        """,
        bundle: .strings,
        comment: "Help: network download and upload rates; bits versus bytes"
    )
    static let diskRate = String(
        localized: "How much is read from or written to disk each second, in bytes (B/s). 1 MB is 1,000 kB, as Finder counts.",
        bundle: .strings,
        comment: "Help: disk read and write rates"
    )
    static let bytesTotal = String(
        localized: "Since midnight, in bytes, counted the way Finder counts file sizes: 1 GB is 1,000 MB.",
        bundle: .strings,
        comment: "Help: today's network or disk totals"
    )
    static let superCores = String(
        localized: "The fastest cores. macOS gives them the most demanding work.",
        bundle: .strings,
        comment: "Help: Super cores (a CPU core type)"
    )
    static let performanceCores = String(
        localized: "Fast cores for work that needs to finish quickly.",
        bundle: .strings,
        comment: "Help: Performance cores (a CPU core type)"
    )
    static let efficiencyCores = String(
        localized: "Low-power cores for background work. They save energy.",
        bundle: .strings,
        comment: "Help: Efficiency cores (a CPU core type)"
    )

    /// The explanation for a core cluster the kernel names; nil for a name it doesn't know.
    static func cluster(_ name: String) -> String? {
        switch name {
        case "Super": superCores
        case "Performance": performanceCores
        case "Efficiency": efficiencyCores
        default: nil
        }
    }
}
