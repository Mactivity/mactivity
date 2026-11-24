import Core
import Foundation
import Simulated
import Testing
@testable import UI

@MainActor
@Suite("Live metrics")
struct LiveMetricsTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Simulated snapshots re-stamped at chosen times.
    private func snapshots(_ count: Int, every seconds: Double, cpu: Double? = nil) async -> [Snapshot] {
        let source = SimulatedSnapshotSource()
        var result: [Snapshot] = []
        for index in 0 ..< count {
            let base = await source.next()
            var system = base.system
            if let cpu {
                system = SystemSample(
                    cpu: CPUStats(
                        totalPercent: cpu,
                        userPercent: cpu,
                        systemPercent: 0,
                        perCorePercent: [cpu],
                        clusters: [],
                        loadAverage: .zero
                    ),
                    memory: system.memory, disk: system.disk, network: system.network, gpu: system.gpu,
                    battery: system.battery, sensors: nil, thermal: .nominal, uptime: system.uptime
                )
            }
            result.append(Snapshot(
                at: Date(timeIntervalSince1970: 1_000_000 + Double(index) * seconds), interval: .seconds(seconds),
                system: system, apps: base.apps, processes: base.processes
            ))
        }
        return result
    }

    @Test("Subscribes to the stream and fills every tab's sparkline")
    func samples() async throws {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true)
        metrics.start()
        try await waitUntil { metrics.snapshot != nil }
        #expect(metrics.snapshot != nil)
        #expect(metrics.sparklines[.cpu]?.count == 1)
        #expect(metrics.sparklines[.memory]?.count == 1)
        metrics.stop()
    }

    @Test("Menu bar redraws: only shown figures, only beyond a small band; unfiltered with nothing listed")
    func menuBarRedrawFilter() {
        func reading(cpu: Double, memory: Double = 50, network: Double = 100_000) -> LiveMetrics.MenuBarReading {
            var reading = LiveMetrics.MenuBarReading()
            reading.set(.cpu, value: cpu)
            reading.set(.memory, value: memory)
            reading.set(.network, value: network)
            return reading
        }
        let shown: [MenuBarMetric] = [.cpu, .memory]
        #expect(!LiveMetrics.menuBarWorthRedrawing(from: reading(cpu: 23.4), to: reading(cpu: 24.6), shown: shown))
        #expect(LiveMetrics.menuBarWorthRedrawing(from: reading(cpu: 23), to: reading(cpu: 26), shown: shown))
        // A figure that isn't shown can change as much as it likes.
        #expect(!LiveMetrics.menuBarWorthRedrawing(from: reading(cpu: 20), to: reading(cpu: 20, network: 9e6), shown: shown))
        #expect(LiveMetrics.menuBarWorthRedrawing(from: reading(cpu: 20), to: reading(cpu: 20, network: 9e6), shown: [.network]))
        #expect(!LiveMetrics.menuBarWorthRedrawing(from: reading(cpu: 20), to: reading(cpu: 20, network: 110_000), shown: [.network]))
        // Nothing listed (icon mode): every update counts.
        #expect(LiveMetrics.menuBarWorthRedrawing(from: reading(cpu: 20), to: reading(cpu: 20.1), shown: []))
    }

    @Test("The update-interval setting reaches the source; stored values stay within 1–5 s")
    func visibleInterval() async throws {
        let source = IntervalRecordingSource()
        let metrics = LiveMetrics(source: source, isSimulated: true)
        metrics.visibleInterval = .seconds(5)
        for _ in 0 ..< 50 where await source.interval != .seconds(5) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await source.interval == .seconds(5))
        #expect(LiveMetrics.clampedVisibleSeconds(0) == 1)
        #expect(LiveMetrics.clampedVisibleSeconds(2) == 2)
        #expect(LiveMetrics.clampedVisibleSeconds(60) == 5)
    }

    @Test("Visible surfaces switch the cadence, idle when none are left")
    func cadence() {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true)
        #expect(metrics.cadence == .idle)
        metrics.setVisible(true, surface: .menuBarWindow)
        metrics.setVisible(true, surface: .mainWindow)
        #expect(metrics.cadence == .visible)
        metrics.setVisible(false, surface: .menuBarWindow)
        #expect(metrics.cadence == .visible)
        metrics.setVisible(false, surface: .mainWindow)
        #expect(metrics.cadence == .idle)
    }

    @Test("Idle ticks build no app list; becoming visible builds one from the latest snapshot")
    func appListOnlyWhileVisible() async {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true)
        for snapshot in await snapshots(3, every: 10) {
            metrics.apply(snapshot)
        }
        #expect(metrics.appList == nil)
        metrics.setVisible(true, surface: .mainWindow)
        #expect(metrics.appList?.apps.isEmpty == false)
    }

    @Test("While idle, the menu bar reading changes at most every 15 seconds")
    func menuBarThrottle() async {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true)
        var changes = 0
        var last = metrics.menuBar
        for snapshot in await snapshots(13, every: 5) {
            metrics.apply(snapshot)
            if metrics.menuBar != last {
                changes += 1
                last = metrics.menuBar
            }
        }
        // 60 s of 5 s ticks: t = 0, 15, 30, 45, 60.
        #expect(changes == 5)
    }

    @Test("While a window is visible, the menu bar follows every tick")
    func menuBarVisible() async {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true)
        metrics.setVisible(true, surface: .mainWindow)
        var updates = 0
        for snapshot in await snapshots(10, every: 1) {
            let before = metrics.menuBar
            metrics.apply(snapshot)
            if metrics.menuBar != before {
                updates += 1
            }
        }
        #expect(updates >= 9)
    }

    @Test("A minute above 85% CPU is strain, and the menu bar shows it right away")
    func strain() async {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true)
        for snapshot in await snapshots(14, every: 5, cpu: 95) {
            metrics.apply(snapshot)
        }
        #expect(metrics.menuBar.strain == .cpu)
    }

    @Test("Replacing the source clears state and flags simulated data")
    func replaceSource() async throws {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(seed: 1), isSimulated: false)
        metrics.start()
        try await waitUntil { metrics.snapshot != nil }
        metrics.replaceSource(SimulatedSnapshotSource(seed: 2), isSimulated: true)
        #expect(metrics.isSimulated)
        #expect(metrics.sparklines.isEmpty)
        try await waitUntil { metrics.snapshot != nil }
        #expect(metrics.snapshot != nil)
        metrics.stop()
    }

    @Test("Every tab reads headline, caption, and figures from a snapshot")
    func tabs() async {
        let snapshot = await SimulatedSnapshotSource().next()
        for tab in MetricTab.allCases {
            #expect(!tab.headline(snapshot).figure.isEmpty)
            #expect(!tab.caption(snapshot).isEmpty)
            // The Battery tab also carries temperatures, fans, and peripherals (spec 5.6).
            #expect((1 ... 16).contains(tab.figures(snapshot).count))
        }
    }

    @Test("Stacked metric lists round-trip through AppStorage strings")
    func stackedList() {
        #expect(MenuBarMetric.decodeList("cpu,memory,bogus") == [.cpu, .memory])
        #expect(MenuBarMetric.encodeList([.gpu, .battery]) == "gpu,battery")
    }

    @Test("Alert settings round-trip through AppStorage JSON; garbage falls back to defaults")
    func alertSettingsStorage() {
        var settings = AlertSettings.defaults
        settings.mutedAppIDs = ["com.example"]
        settings.quietHours = QuietHours(startMinute: 1320, endMinute: 420)
        #expect(AlertSettings.decode(settings.encoded()) == settings)
        #expect(AlertSettings.decode("nope") == .defaults)
    }
}

/// Records the visible interval it's given; yields no snapshots.
private actor IntervalRecordingSource: SnapshotSource {
    private(set) var interval: Duration?

    func snapshots() async -> AsyncStream<Snapshot> {
        AsyncStream { _ in }
    }

    func setCadence(_: SamplingCadence) async {}

    func setVisibleInterval(_ interval: Duration) async {
        self.interval = interval
    }
}
