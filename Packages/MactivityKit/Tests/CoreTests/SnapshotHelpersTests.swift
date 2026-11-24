import Core
import Foundation
import Simulated
import Testing

@Suite("Snapshot helpers shared by UI, History, Readouts, and the CLI")
struct SnapshotHelpersTests {
    private func app(_ id: String, _ name: String, cpu: Double, energy: Double? = nil) -> AppAggregate {
        AppAggregate(
            app: AppIdentity(id: id, name: name, bundleID: id, iconKey: "", kind: .app),
            processCount: 1, cpuPercent: cpu, memoryBytes: 0, energyMW: energy, diskReadBPS: 0, diskWriteBPS: 0,
            netInBPS: nil, netOutBPS: nil, gpuPercent: nil
        )
    }

    @Test("Top apps: figure descending, no figure last, then name in Finder order, then id")
    func ranking() {
        let apps = [
            app("c", "App 10", cpu: 5),
            app("b", "App 2", cpu: 5),
            app("z", "Same", cpu: 1),
            app("a", "Same", cpu: 1),
            app("top", "Zed", cpu: 40),
        ]
        #expect(AppAggregate.ranked(apps) { $0.cpuPercent }.map(\.id) == ["top", "b", "c", "a", "z"])
        // Energy: only "top" reports one, so the rest sort by name after it.
        let energy = apps.map { $0.id == "top" ? app("top", "Zed", cpu: 40, energy: 900) : $0 }
        #expect(AppAggregate.ranked(energy) { $0.energyMW }.map(\.id) == ["top", "b", "c", "a", "z"])
    }

    @Test("Disk and battery status use the strain thresholds")
    func statuses() {
        #expect(MetricStatus(diskFreeFraction: 0.049) == .critical)
        #expect(MetricStatus(diskFreeFraction: StrainDetector.diskFreeThreshold) == .elevated)
        #expect(MetricStatus(diskFreeFraction: 0.099) == .elevated)
        #expect(MetricStatus(diskFreeFraction: 0.1) == .normal)
        func battery(_ percent: Double, _ source: BatteryStats.PowerSource) -> MetricStatus {
            BatteryStats(
                percent: percent, isCharging: false, source: source, timeRemaining: nil, cycleCount: nil,
                maxCapacityPercent: nil, powerDrawWatts: nil
            ).status
        }
        #expect(battery(10, .battery) == .critical)
        #expect(battery(20, .battery) == .elevated)
        #expect(battery(21, .battery) == .normal)
        #expect(battery(5, .ac) == .normal)
    }

    @Test("Temperatures by sensor group")
    func temperature() {
        let sensors = SensorStats(
            temperatures: [TemperatureReading(id: "cpu", name: "CPU", celsius: 54)], fans: [], peripherals: []
        )
        #expect(sensors.temperature(id: "cpu") == 54)
        #expect(sensors.temperature(id: "gpu") == nil)
    }

    @Test("History records the whole Mac's draw in milliwatts; nothing on a Mac without a battery (D-258)")
    func powerDraw() async {
        let base = await SimulatedSnapshotSource(hasBattery: true).next()
        func laptop(_ source: BatteryStats.PowerSource, battery: Double, whole: Double?) -> Snapshot {
            let system = base.system
            let stats = BatteryStats(
                percent: 80, isCharging: false, source: source, timeRemaining: nil, cycleCount: nil, maxCapacityPercent: nil,
                powerDrawWatts: battery, systemLoadWatts: whole, adapterWatts: source == .ac ? 96 : nil
            )
            return Snapshot(
                at: base.at, interval: base.interval,
                system: SystemSample(
                    cpu: system.cpu, memory: system.memory, disk: system.disk, network: system.network, gpu: system.gpu,
                    battery: stats, sensors: system.sensors, thermal: system.thermal, uptime: system.uptime
                ),
                apps: base.apps, processes: []
            )
        }
        // Plugged in, the battery powers nothing: the whole Mac's 12.5 W comes from the charger.
        #expect(laptop(.ac, battery: 0, whole: 12.5).systemValue(for: .powerDraw) == 12500)
        // Without the whole-Mac reading: on battery, what leaves it is the whole Mac...
        #expect(laptop(.battery, battery: 9, whole: nil).systemValue(for: .powerDraw) == 9000)
        // ...but plugged in its 0 means "not known", so nothing is recorded.
        #expect(laptop(.ac, battery: 0, whole: nil).systemValue(for: .powerDraw) == nil)
        let desktop = await SimulatedSnapshotSource(hasBattery: false).next()
        #expect(desktop.systemValue(for: .powerDraw) == nil)
    }

    @Test("Energy totals are nil when no app reports any")
    func totals() async {
        let snapshot = await SimulatedSnapshotSource().next()
        let expected = snapshot.apps.compactMap(\.energyMW).reduce(0, +)
        #expect(snapshot.totalEnergyMW == expected)
        let none = Snapshot(
            at: snapshot.at, interval: snapshot.interval, system: snapshot.system,
            apps: [app("a", "A", cpu: 1)], processes: []
        )
        #expect(none.totalEnergyMW == nil)
        #expect(none.totalEnergyImpact == nil)
    }
}
