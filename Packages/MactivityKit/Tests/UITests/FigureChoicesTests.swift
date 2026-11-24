import AppKit
import Core
import Foundation
import Simulated
import Testing
@testable import UI

/// Hand-built systems for figure tests: 20 of 36 GB used, 1.0 MB/s down and 114 kB/s up,
/// 412 of 1 TB free, 84% with 5h 30m left.
enum FigureFixture {
    static let gib: UInt64 = 1_073_741_824

    static func memory(used: UInt64 = 20 * gib, total: UInt64 = 36 * gib, pressure: MemoryPressure = .normal) -> MemoryStats {
        MemoryStats(
            totalBytes: total, usedBytes: used, appBytes: used / 2, wiredBytes: used / 4, compressedBytes: used / 4,
            cachedFilesBytes: 0, swapUsedBytes: 0, pressure: pressure, availableLevel: 40
        )
    }

    static func battery(
        percent: Double = 84, source: BatteryStats.PowerSource = .battery, charging: Bool = false,
        seconds: Int64? = 5 * 3600 + 30 * 60, watts: Double? = 11.4
    ) -> BatteryStats {
        BatteryStats(
            percent: percent, isCharging: charging, source: source, timeRemaining: seconds.map { .seconds($0) },
            cycleCount: 100, maxCapacityPercent: 95, powerDrawWatts: watts
        )
    }

    static func sensors(cpu: Double? = 54, gpu: Double? = 47, other: Double = 71) -> SensorStats {
        var temperatures: [TemperatureReading] = []
        if let cpu {
            temperatures.append(TemperatureReading(id: "cpu", name: "CPU", celsius: cpu))
        }
        if let gpu {
            temperatures.append(TemperatureReading(id: "gpu", name: "GPU", celsius: gpu))
        }
        temperatures.append(TemperatureReading(id: "ssd", name: "SSD", celsius: other))
        return SensorStats(temperatures: temperatures, fans: [], peripherals: [])
    }

    static func system(
        cpu: Double = 23,
        memory: MemoryStats = memory(),
        inBPS: Double = 1_000_000, outBPS: Double = 114_000,
        readBPS: Double = 12_000_000, writeBPS: Double = 3_000_000,
        freeBytes: UInt64 = 412_000_000_000,
        gpu: Double? = 8,
        battery: BatteryStats? = battery(),
        sensors: SensorStats? = sensors()
    ) -> SystemSample {
        SystemSample(
            cpu: CPUStats(
                totalPercent: cpu,
                userPercent: cpu,
                systemPercent: 0,
                perCorePercent: [cpu, cpu],
                clusters: [],
                loadAverage: .zero
            ),
            memory: memory,
            disk: DiskStats(
                volumes: [VolumeStats(id: "boot", name: "Macintosh HD", totalBytes: 1_000_000_000_000, freeBytes: freeBytes)],
                readBPS: readBPS, writeBPS: writeBPS
            ),
            network: NetworkStats(inBPS: inBPS, outBPS: outBPS, primaryInterface: "en0"),
            gpu: gpu.map { GPUStats(name: "Apple GPU", utilizationPercent: $0, memoryInUseBytes: nil) },
            battery: battery, sensors: sensors, thermal: .nominal, uptime: .seconds(3 * 86400)
        )
    }

    static func snapshot(_ system: SystemSample = system()) -> Snapshot {
        Snapshot(at: Date(timeIntervalSince1970: 1_000_000), interval: .seconds(1), system: system, apps: [], processes: [])
    }

    /// The fixture's edge cases: no battery, on the adapter, still estimating, no GPU or sensors.
    static var edgeSystems: [SystemSample] {
        [
            system(),
            system(gpu: nil, battery: nil, sensors: nil),
            system(battery: battery(source: .ac, charging: true, seconds: 40 * 60, watts: 0)),
            system(battery: battery(percent: 100, source: .ac, seconds: nil, watts: 0)),
            system(battery: battery(seconds: nil, watts: nil)),
            system(memory: memory(pressure: .critical), inBPS: 0, outBPS: 0, readBPS: 0, writeBPS: 0, freeBytes: 0),
        ]
    }
}

/// Today's figures before choices existed, copied from the code they replaced: Automatic must
/// match them exactly.
enum LegacyFigures {
    static func headline(_ tab: MetricTab, _ system: SystemSample) -> String {
        switch tab {
        case .cpu: Formatters.percent(system.cpu.totalPercent)
        case .memory: Formatters.memory(system.memory.usedBytes)
        case .disk: Formatters.bytes(system.disk.bootVolume?.freeBytes ?? 0)
        case .network: Formatters.rate(system.network.inBPS)
        case .gpu: system.gpu.map { Formatters.percent($0.utilizationPercent) } ?? "–"
        // Without a battery (a desktop), the apps' power: none in these app-less fixtures.
        case .battery: system.battery.map { Formatters.percent($0.percent) } ?? Formatters.power(milliwatts: 0)
        }
    }

    static func caption(_ tab: MetricTab, _ system: SystemSample) -> String {
        switch tab {
        case .cpu:
            return "\(system.cpu.perCorePercent.count) cores"
        case .memory:
            return "used of \(Formatters.memory(system.memory.totalBytes))"
        case .disk:
            return "free on \(system.disk.bootVolume?.name ?? "startup disk")"
        case .network:
            return "down · \(Formatters.rate(system.network.outBPS)) up"
        case .gpu:
            return system.gpu?.name ?? "No GPU statistics"
        case .battery:
            guard let battery = system.battery else {
                return "used by apps"
            }
            if battery.source == .ac {
                return battery.isCharging ? "Charging" : "On power adapter"
            }
            return battery.timeRemaining.map { "\(Formatters.duration($0)) remaining" } ?? "Calculating…"
        }
    }

    static func row(_ tab: MetricTab, _ system: SystemSample) -> String {
        let short = switch tab {
        case .memory: "of \(Formatters.memory(system.memory.totalBytes))"
        case .disk: "free"
        case .network: "↓ · \(Formatters.rate(system.network.outBPS)) ↑"
        case .battery: system.battery?.timeRemaining.map { Formatters.duration($0) } ?? ""
        default: ""
        }
        return [headline(tab, system), short].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func menuBarValue(_ metric: MenuBarMetric, _ system: SystemSample) -> Double? {
        switch metric {
        case .cpu: system.cpu.totalPercent
        case .memory: system.memory.usedFraction * 100
        case .network: system.network.inBPS + system.network.outBPS
        case .gpu: system.gpu?.utilizationPercent
        case .battery: system.battery?.percent
        case .temperature: system.sensors?.temperature(id: "cpu")
        }
    }

    static func withinBand(_ metric: MenuBarMetric, _ old: Double?, _ new: Double?) -> Bool {
        guard let old, let new else {
            return old == nil && new == nil
        }
        switch metric {
        case .cpu, .gpu, .memory, .battery, .temperature: return abs(new - old) < 2
        case .network: return abs(new - old) < max(old * 0.25, 10000)
        }
    }

    static func worthRedrawing(_ metric: MenuBarMetric, from old: SystemSample, to new: SystemSample) -> Bool {
        let before = menuBarValue(metric, old)
        let after = menuBarValue(metric, new)
        return MenuBarLayout.text(metric, value: before) != MenuBarLayout.text(metric, value: after)
            && !withinBand(metric, before, after)
    }
}

@MainActor
@Suite("Figure choices: cards and rows")
struct FigureChoicesCardTests {
    private func simulatedSystems() async -> [SystemSample] {
        let source = SimulatedSnapshotSource()
        var systems: [SystemSample] = []
        for _ in 0 ..< 40 {
            await systems.append(source.next().system)
        }
        return systems + FigureFixture.edgeSystems
    }

    @Test("Automatic headlines, captions, and rows are exactly today's")
    func automaticIsToday() async {
        for system in await simulatedSystems() {
            let snapshot = FigureFixture.snapshot(system)
            for tab in MetricTab.allCases {
                #expect(tab.headline(snapshot).figure == LegacyFigures.headline(tab, system), "\(tab) headline")
                #expect(tab.caption(snapshot) == LegacyFigures.caption(tab, system), "\(tab) caption")
                #expect(CompactOverview.value(tab, snapshot) == LegacyFigures.row(tab, system), "\(tab) row")
                #expect(tab.headline(snapshot, choices: .automatic) == tab.headline(snapshot))
            }
        }
    }

    @Test("Memory: used, percent, or pressure")
    func memory() {
        let snapshot = FigureFixture.snapshot()
        let gb20 = Formatters.memory(20 * FigureFixture.gib)
        let gb36 = Formatters.memory(36 * FigureFixture.gib)
        let percent = Formatters.percent(20.0 / 36 * 100)
        func check(_ choice: MemoryFigure, _ headline: String, _ caption: String, _ row: String) {
            let choices = FigureChoices(memory: choice)
            #expect(MetricTab.memory.headline(snapshot, choices: choices).figure == headline)
            #expect(MetricTab.memory.caption(snapshot, choices: choices) == caption)
            #expect(MetricTab.memory.rowValue(snapshot, choices: choices) == row)
        }
        check(.used, gb20, "used of \(gb36)", "\(gb20) of \(gb36)")
        check(.percent, percent, "\(gb20) of \(gb36)", "\(percent) used")
        check(.pressure, "Normal", "pressure · \(gb20) of \(gb36) used", "Normal")
    }

    @Test("Network: both, download, or upload")
    func network() {
        let snapshot = FigureFixture.snapshot()
        let down = Formatters.rate(1_000_000)
        let up = Formatters.rate(114_000)
        func check(_ choice: NetworkFigure, _ headline: String, _ caption: String, _ row: String) {
            let choices = FigureChoices(network: choice)
            #expect(MetricTab.network.headline(snapshot, choices: choices).figure == headline)
            #expect(MetricTab.network.caption(snapshot, choices: choices) == caption)
            #expect(MetricTab.network.rowValue(snapshot, choices: choices) == row)
        }
        check(.both, down, "down · \(up) up", "\(down) ↓ · \(up) ↑")
        check(.download, "↓ \(down)", "download · \(up) up", "↓ \(down)")
        check(.upload, "↑ \(up)", "upload · \(down) down", "↑ \(up)")
    }

    @Test("Disk: free, percent used, or activity")
    func disk() {
        let snapshot = FigureFixture.snapshot()
        let free = Formatters.bytes(UInt64(412_000_000_000))
        let used = Formatters.percent(58.8)
        let read = Formatters.rate(12_000_000)
        let write = Formatters.rate(3_000_000)
        func check(_ choice: DiskFigure, _ headline: String, _ caption: String, _ row: String) {
            let choices = FigureChoices(disk: choice)
            #expect(MetricTab.disk.headline(snapshot, choices: choices).figure == headline)
            #expect(MetricTab.disk.caption(snapshot, choices: choices) == caption)
            #expect(MetricTab.disk.rowValue(snapshot, choices: choices) == row)
        }
        check(.free, free, "free on Macintosh HD", "\(free) free")
        check(.percentUsed, used, "used · \(free) free on Macintosh HD", "\(used) used")
        check(.activity, read, "read · \(write) write", "\(read) read · \(write) write")
    }

    @Test("Battery: percent, time left, both, or power draw, on battery and on the adapter")
    func battery() {
        let percent = Formatters.percent(84)
        let time = Formatters.duration(.seconds(5 * 3600 + 30 * 60))
        let watts = Formatters.power(milliwatts: 11400)
        func check(_ system: SystemSample, _ choice: BatteryFigure, _ headline: String, _ caption: String, _ row: String) {
            let snapshot = FigureFixture.snapshot(system)
            let choices = FigureChoices(battery: choice)
            #expect(MetricTab.battery.headline(snapshot, choices: choices).figure == headline, "\(choice)")
            #expect(MetricTab.battery.caption(snapshot, choices: choices) == caption, "\(choice)")
            #expect(MetricTab.battery.rowValue(snapshot, choices: choices) == row, "\(choice)")
        }
        let onBattery = FigureFixture.system()
        check(onBattery, .percent, percent, "\(time) remaining", percent)
        check(onBattery, .timeLeft, time, "\(percent) · on battery", time)
        check(onBattery, .percentAndTime, percent, "\(time) remaining", "\(percent) · \(time)")
        check(onBattery, .power, watts, "\(percent) · on battery", watts)
        let charging = FigureFixture.system(battery: FigureFixture.battery(source: .ac, charging: true, seconds: 2400, watts: 0))
        check(charging, .timeLeft, "Charging", "\(percent) · charging", "Charging")
        check(charging, .percentAndTime, percent, "Charging", "\(percent) · Charging")
        check(charging, .power, "Charging", "\(percent) · charging", "Charging")
        // Plugged in and held at 84%: not charging, and not full either (D-214).
        let held = FigureFixture.system(battery: FigureFixture.battery(source: .ac, seconds: nil, watts: 0))
        check(held, .timeLeft, "Not charging", "\(percent) · on power adapter", "Not charging")
        let estimating = FigureFixture.system(battery: FigureFixture.battery(seconds: nil, watts: nil))
        check(estimating, .timeLeft, "–", "\(percent) · on battery", "–")
        check(estimating, .power, "–", "\(percent) · on battery", "–")
        for choice in BatteryFigure.allCases {
            // A desktop: the apps' power whatever the choice (none here: the fixture has no apps).
            let power = Formatters.power(milliwatts: 0)
            check(FigureFixture.system(battery: nil), choice, power, "used by apps", power)
        }
    }

    @Test("CPU and GPU ignore the choices")
    func processors() {
        let snapshot = FigureFixture.snapshot()
        let everything = FigureChoices(memory: .pressure, network: .upload, disk: .activity, battery: .power, temperature: .hottest)
        for tab in [MetricTab.cpu, .gpu] {
            #expect(tab.headline(snapshot, choices: everything) == tab.headline(snapshot))
            #expect(tab.caption(snapshot, choices: everything) == tab.caption(snapshot))
        }
    }

    @Test("Rows never carry stray spaces, whatever the choice")
    func rowSpacing() {
        for system in FigureFixture.edgeSystems {
            let snapshot = FigureFixture.snapshot(system)
            for choices in allFigureChoices {
                for tab in MetricTab.allCases {
                    let value = tab.rowValue(snapshot, choices: choices)
                    #expect(value == value.trimmingCharacters(in: .whitespaces), "\(tab): \"\(value)\"")
                    #expect(!value.contains("  "), "\(tab): \"\(value)\"")
                    #expect(!value.isEmpty)
                }
            }
        }
    }
}

/// One combination per choice of every metric at once (their cases zipped, padded with the last).
let allFigureChoices: [FigureChoices] = {
    let count = BatteryFigure.allCases.count
    func pick<T>(_ cases: [T], _ index: Int) -> T {
        cases[min(index, cases.count - 1)]
    }
    return (0 ..< count).map {
        FigureChoices(
            memory: pick(MemoryFigure.allCases, $0),
            network: pick(NetworkFigure.allCases, $0),
            disk: pick(DiskFigure.allCases, $0),
            battery: pick(BatteryFigure.allCases, $0),
            temperature: pick(TemperatureFigure.allCases, $0)
        )
    }
}()

@MainActor
@Suite("Figure choices: the menu bar window's Overview")
struct OverviewRowTests {
    @Test("Rows off in Settings are left out; the rest keep their order")
    func hidden() {
        let snapshot = FigureFixture.snapshot()
        let all = CompactOverview.rows(snapshot, hidden: [], choices: .automatic).map(\.row)
        #expect(all == OverviewRow.allCases)
        let some = CompactOverview.rows(snapshot, hidden: [.uptime, .gpu, .temperature], choices: .automatic).map(\.row)
        #expect(some == [.cpu, .memory, .disk, .network, .battery])
        #expect(CompactOverview.rows(snapshot, hidden: Set(OverviewRow.allCases), choices: .automatic).isEmpty)
    }

    @Test("Rows show the chosen figures; temperature only with its sensor")
    func values() {
        let snapshot = FigureFixture.snapshot()
        let rows = CompactOverview.rows(snapshot, hidden: [], choices: FigureChoices(battery: .timeLeft, temperature: .hottest))
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.row, $0.value) })
        #expect(values[.battery] == Formatters.duration(.seconds(5 * 3600 + 30 * 60)))
        #expect(values[.temperature] == Formatters.temperature(celsius: 71))
        #expect(values[.uptime] == Formatters.duration(.seconds(3 * 86400)))
        let automatic = CompactOverview.rows(snapshot, hidden: [], choices: .automatic)
        #expect(automatic.last?.value == Formatters.temperature(celsius: 54))
        let noGPU = FigureFixture.snapshot(FigureFixture.system(sensors: FigureFixture.sensors(gpu: nil)))
        let rowsWithout = CompactOverview.rows(noGPU, hidden: [], choices: FigureChoices(temperature: .gpu)).map(\.row)
        #expect(!rowsWithout.contains(.temperature))
        let noSensors = FigureFixture.snapshot(FigureFixture.system(sensors: nil))
        #expect(!CompactOverview.rows(noSensors, hidden: [], choices: .automatic).map(\.row).contains(.temperature))
    }

    @Test("Hidden rows round-trip through AppStorage in row order; unknown names are dropped")
    func storage() {
        #expect(OverviewRow.encodeHidden([.temperature, .gpu]) == "gpu,temperature")
        #expect(OverviewRow.decodeHidden("gpu,bogus,temperature") == [.gpu, .temperature])
        #expect(OverviewRow.decodeHidden("").isEmpty)
    }
}
