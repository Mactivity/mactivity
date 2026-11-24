import Core
import Foundation
import Simulated
import Testing
@testable import UI

/// A Mac without a battery (Mac mini, Studio, Pro): the Battery tab becomes Energy, and nothing
/// waits forever for a battery or a fan that isn't there.
@MainActor
@Suite("Desktop Macs: no battery, no fans")
struct DesktopMacTests {
    private static func app(_ id: String, milliwatts: Double?, impact: Double?) -> AppAggregate {
        AppAggregate(
            app: AppIdentity(id: id, name: id, bundleID: id, iconKey: id, kind: .app),
            processCount: 1, cpuPercent: 1, memoryBytes: 1, energyMW: milliwatts,
            diskReadBPS: 0, diskWriteBPS: 0, netInBPS: nil, netOutBPS: nil, gpuPercent: nil, energyImpact: impact
        )
    }

    private static func desktop(sensors: SensorStats? = nil) -> Snapshot {
        Snapshot(
            at: Date(timeIntervalSince1970: 1_000_000), interval: .seconds(1),
            system: FigureFixture.system(battery: nil, sensors: sensors),
            apps: [app("a", milliwatts: 1500, impact: 12), app("b", milliwatts: 500, impact: 3), app("c", milliwatts: nil, impact: nil)],
            processes: []
        )
    }

    @Test("The Battery tab is called Energy, with a bolt, only without a battery; its raw value stays")
    func naming() {
        #expect(SidebarItem.battery.title(hasBattery: false) == "Energy")
        #expect(SidebarItem.battery.symbol(hasBattery: false) == "bolt")
        #expect(SidebarItem.battery.title(hasBattery: true) == SidebarItem.battery.title)
        #expect(SidebarItem.battery.symbol(hasBattery: true) == SidebarItem.battery.symbol)
        #expect(MetricTab.battery.title(hasBattery: false) == "Energy")
        #expect(CompactTab.battery.title(hasBattery: false) == "Energy")
        #expect(SidebarItem.battery.rawValue == "battery")
        for item in SidebarItem.allCases where item != .battery {
            #expect(item.title(hasBattery: false) == item.title)
            #expect(item.symbol(hasBattery: false) == item.symbol)
        }
    }

    @Test("Per-app volume's tab is called Sound; its raw value stays volume")
    func sound() {
        #expect(SidebarItem.volume.title == "Sound")
        #expect(SidebarItem.volume.rawValue == "volume")
    }

    @Test("Hardware: no battery after the first snapshot without one; a battery once seen stays")
    func hardware() {
        var hardware = LiveMetrics.Hardware()
        #expect(hardware.hasBattery)
        #expect(hardware.hasFans == nil)
        hardware.observe(FigureFixture.system(battery: nil, sensors: nil))
        #expect(!hardware.hasBattery)
        #expect(hardware.hasFans == nil)
        #expect(hardware.hasTemperatureSensors == nil)
        hardware.observe(FigureFixture.system(battery: nil, sensors: FigureFixture.sensors()))
        #expect(hardware.hasFans == false)
        #expect(hardware.hasTemperatureSensors == true)

        var laptop = LiveMetrics.Hardware()
        laptop.observe(FigureFixture.system())
        laptop.observe(FigureFixture.system(battery: nil))
        #expect(laptop.hasBattery, "a failed battery read isn't a desktop")
    }

    @Test("The simulated desktop has no battery, and LiveMetrics notices")
    func simulated() async {
        let source = SimulatedSnapshotSource(hasBattery: false)
        let snapshot = await source.next()
        #expect(snapshot.system.battery == nil)
        let metrics = LiveMetrics(source: source, isSimulated: true)
        metrics.apply(snapshot)
        #expect(!metrics.hardware.hasBattery)
        let laptop = await SimulatedSnapshotSource().next()
        #expect(laptop.system.battery != nil)
    }

    @Test("Energy leads with the apps' power, then their Energy Impact; its sparkline scales to the data")
    func energyTab() {
        let snapshot = Self.desktop()
        let power = Formatters.power(milliwatts: 2000)
        for choice in BatteryFigure.allCases {
            let headline = MetricTab.battery.headline(snapshot, choices: FigureChoices(battery: choice))
            #expect(headline.figure == power)
            #expect(headline.value == 2000)
        }
        #expect(MetricTab.battery.caption(snapshot) == "used by apps")
        #expect(MetricTab.battery.sparklineValue(snapshot) == 2000)
        #expect(MetricTab.battery.sparklineDomain(hasBattery: false) == nil)
        #expect(MetricTab.battery.sparklineDomain(hasBattery: true) == 0 ... 100)
        #expect(MetricTab.battery.status(snapshot) == nil)
        let figures = MetricTab.battery.figures(snapshot)
        #expect(figures.map(\.label) == [Metric.energyImpact.title])
        #expect(figures.first?.value == Formatters.metric(15, .energyImpact))
    }

    @Test("The menu bar window's Overview leaves out Battery without one")
    func overviewRows() {
        let snapshot = Self.desktop()
        let rows = CompactOverview.rows(snapshot, hidden: [], choices: .automatic, hasBattery: false).map(\.row)
        #expect(!rows.contains(.battery))
        #expect(rows.contains(.cpu))
        let laptop = CompactOverview.rows(FigureFixture.snapshot(), hidden: [], choices: .automatic).map(\.row)
        #expect(laptop.contains(.battery))
    }

    @Test("History drops Fan speed on a fanless Mac and Temperature without sensors, keeps both until read")
    func sensorStrips() {
        let ids = { (hardware: LiveMetrics.Hardware) in HistoryView.sensorSpecs(for: hardware).map(\.id) }
        #expect(ids(LiveMetrics.Hardware()) == ["temperature", "fans"])
        var fanless = LiveMetrics.Hardware()
        fanless.observe(FigureFixture.system(sensors: FigureFixture.sensors()))
        #expect(ids(fanless) == ["temperature"])
        var bare = LiveMetrics.Hardware()
        bare.observe(FigureFixture.system(sensors: SensorStats(temperatures: [], fans: [], peripherals: [])))
        #expect(ids(bare).isEmpty)
        var fans = LiveMetrics.Hardware()
        fans.observe(FigureFixture.system(sensors: SensorStats(
            temperatures: [], fans: [FanReading(id: 0, rpm: 1200, minRPM: 0, maxRPM: 5000)], peripherals: []
        )))
        #expect(ids(fans) == ["fans"])
    }
}
