@testable import Alerts
import Core
import Foundation
import Simulated
import Testing

private struct DeliveryFailed: Error {}

/// A deliverer whose notification center always refuses.
private struct FailingDeliverer: AlertDeliverer {
    func deliver(_: Alert) async throws {
        throw DeliveryFailed()
    }
}

@Suite("Alert monitor")
struct AlertMonitorTests {
    let t0 = Fixture.now

    func makeMonitor(
        settings: AlertSettings = .defaults,
        deliverer: any AlertDeliverer = SimulatedAlertDeliverer(),
        store: any AlertStateStore = SimulatedAlertStateStore()
    ) -> AlertMonitor {
        AlertMonitor(deliverer: deliverer, store: store, settings: settings, calendar: Fixture.calendar)
    }

    /// Feeds one snapshot every `step` seconds for offsets in `seconds` (relative to t0).
    func feed(
        _ monitor: AlertMonitor,
        _ seconds: StrideThrough<Int>,
        frontmost: AppIdentity.ID? = nil,
        apps: (Int) -> [AppAggregate] = { _ in [Fixture.aggregate(cpu: 95)] }
    ) async {
        for second in seconds {
            let snapshot = Fixture.snapshot(at: t0.addingTimeInterval(TimeInterval(second)), apps: apps(second))
            await monitor.ingest(snapshot, frontmostAppID: frontmost)
        }
    }

    @Test("A CPU hog alerts once by 10 minutes, then not again for the 60-minute cooldown")
    func cpuHogEndToEnd() async throws {
        let deliverer = SimulatedAlertDeliverer()
        let store = SimulatedAlertStateStore()
        let monitor = makeMonitor(deliverer: deliverer, store: store)
        var fired = await monitor.firedAlerts().makeAsyncIterator()

        await feed(monitor, stride(from: 0, through: 600, by: 5))
        let delivered = await deliverer.delivered
        let alert = try #require(delivered.first)
        #expect(delivered.count == 1)
        #expect(alert.rule == .highCPU)
        #expect(alert.app == Fixture.app)
        #expect(alert.firedAt <= t0.addingTimeInterval(600))
        #expect(alert.body == "Averaged \(Formatters.percent(95)) for 10 minutes.")
        let streamed = await fired.next()
        #expect(streamed == alert)
        #expect(await monitor.recentAlerts(limit: 10) == [alert])
        let key = AlertKey(appID: Fixture.app.id, rule: .highCPU)
        #expect(try await store.loadAlertState().lastFired[key] == alert.firedAt)

        // Still hogging for the next 60 minutes: nothing new until the cooldown ends.
        let firedOffset = Int(alert.firedAt.timeIntervalSince(t0))
        await feed(monitor, stride(from: 605, through: firedOffset + 3600 - 5, by: 5))
        #expect(await deliverer.delivered.count == 1)

        // The first evaluation after the cooldown fires again, which proves the cooldown did the gating.
        await feed(monitor, stride(from: firedOffset + 3600, through: firedOffset + 3600, by: 5))
        #expect(await deliverer.delivered.count == 2)
    }

    @Test("Evaluates once per completed 5 s bucket, not per snapshot")
    func oncePerBucket() async {
        let monitor = makeMonitor()
        // 1 s snapshots at t0 … t0+59 close the buckets at +5, +10, … +55.
        await feed(monitor, stride(from: 0, through: 59, by: 1))
        #expect(await monitor.evaluationCount == 11)
    }

    @Test("Memory stays bounded by the longest enabled window plus one bucket")
    func bounded() async {
        let monitor = makeMonitor()
        await feed(monitor, stride(from: 0, through: 2 * 3600, by: 5))
        #expect(await monitor.pointCount(for: Fixture.app.id) == 721)

        await monitor.updateSettings(Fixture.only(.highCPU))
        await feed(monitor, stride(from: 2 * 3600 + 5, through: 2 * 3600 + 10, by: 5))
        #expect(await monitor.pointCount(for: Fixture.app.id) == 121)
    }

    @Test("Loads cooldowns from the store on first use, so they survive a relaunch")
    func loadsState() async throws {
        let store = SimulatedAlertStateStore()
        let key = AlertKey(appID: Fixture.app.id, rule: .highCPU)
        try await store.saveAlertState(AlertState(lastFired: [key: t0]))
        let deliverer = SimulatedAlertDeliverer()
        let monitor = makeMonitor(deliverer: deliverer, store: store)
        await feed(monitor, stride(from: 0, through: 900, by: 5))
        #expect(await deliverer.delivered.isEmpty)
    }

    @Test("A delivery failure still records and publishes the alert")
    func deliveryFailure() async {
        let store = SimulatedAlertStateStore()
        let monitor = makeMonitor(deliverer: FailingDeliverer(), store: store)
        var fired = await monitor.firedAlerts().makeAsyncIterator()
        await feed(monitor, stride(from: 0, through: 600, by: 5))
        let recorded = await monitor.recentAlerts(limit: 10)
        #expect(recorded.count == 1)
        let streamed = await fired.next()
        #expect(streamed == recorded.first)
    }

    @Test("Every firedAlerts stream gets every alert")
    func severalStreams() async {
        let monitor = makeMonitor()
        var first = await monitor.firedAlerts().makeAsyncIterator()
        var second = await monitor.firedAlerts().makeAsyncIterator()
        await feed(monitor, stride(from: 0, through: 600, by: 5))
        let a = await first.next()
        let b = await second.next()
        #expect(a != nil)
        #expect(a == b)
    }

    @Test("Apps that have quit aren't alerted about")
    func quitApp() async {
        let deliverer = SimulatedAlertDeliverer()
        let monitor = makeMonitor(deliverer: deliverer)
        // The hog runs until just before coverage is reached, then quits.
        await feed(monitor, stride(from: 0, through: 900, by: 5)) { second in
            second <= 530 ? [Fixture.aggregate(cpu: 95)] : [Fixture.aggregate(Fixture.other, cpu: 1)]
        }
        #expect(await deliverer.delivered.isEmpty)
    }

    @Test("The frontmost app passed to ingest is exempt")
    func frontmost() async {
        let deliverer = SimulatedAlertDeliverer()
        let monitor = makeMonitor(deliverer: deliverer)
        await feed(monitor, stride(from: 0, through: 600, by: 5), frontmost: Fixture.app.id)
        #expect(await deliverer.delivered.isEmpty)
    }

    @Test("Updated settings take effect on the next evaluation")
    func updateSettings() async {
        let deliverer = SimulatedAlertDeliverer()
        let monitor = makeMonitor(deliverer: deliverer)
        var settings = AlertSettings.defaults
        settings.rules[.highCPU]?.isEnabled = false
        await monitor.updateSettings(settings)
        await feed(monitor, stride(from: 0, through: 600, by: 5))
        #expect(await deliverer.delivered.isEmpty)
    }

    @Test("Only apps a rule can alert about are kept: not macOS, not muted apps, none with every rule off")
    func keepsOnlyWatchedApps() async {
        var settings = AlertSettings.defaults
        settings.mutedAppIDs = [Fixture.other.id]
        let monitor = makeMonitor(settings: settings)
        await feed(monitor, stride(from: 0, through: 60, by: 5)) { _ in
            [Fixture.aggregate(cpu: 95), Fixture.aggregate(Fixture.other, cpu: 95), Fixture.aggregate(.system, cpu: 50)]
        }
        #expect(await monitor.pointCount(for: Fixture.app.id) > 0)
        #expect(await monitor.pointCount(for: Fixture.other.id) == 0)
        #expect(await monitor.pointCount(for: AppIdentity.system.id) == 0)

        for rule in AlertRule.allCases {
            settings.rules[rule]?.isEnabled = false
        }
        let off = makeMonitor(settings: settings)
        await feed(off, stride(from: 0, through: 60, by: 5))
        #expect(await off.pointCount(for: Fixture.app.id) == 0)
    }
}

@Suite("Activity recorder")
struct ActivityRecorderTests {
    let t0 = Fixture.now

    @Test("Averages the snapshots in a bucket, and closes it on the next one")
    func averages() throws {
        var recorder = ActivityRecorder(bucketLength: 5)
        let netIn: [Double?] = [nil, 10, nil, 20, nil]
        for second in 0 ..< 5 {
            let app = Fixture.aggregate(cpu: Double(second + 1) * 10, memory: UInt64(second) * 100, netIn: netIn[second])
            let closed = recorder.record(Fixture.snapshot(at: t0.addingTimeInterval(Double(second)), apps: [app]))
            #expect(!closed)
        }
        #expect(recorder.currentActivity().isEmpty)
        let closed = recorder.record(Fixture.snapshot(at: t0.addingTimeInterval(5), apps: [Fixture.aggregate()]))
        #expect(closed)

        let history = try #require(recorder.currentActivity().first)
        #expect(history.points.count == 1)
        let point = try #require(history.points.first)
        #expect(point.at == t0.addingTimeInterval(2))
        #expect(point.cpuPercent == 30)
        #expect(point.memoryBytes == 200)
        #expect(point.netInBPS == 15)
        #expect(point.netOutBPS == nil)
    }

    @Test("Trims by age and by count, and drops apps left empty")
    func trims() {
        var recorder = ActivityRecorder(bucketLength: 5)
        for second in stride(from: 0, through: 100, by: 5) {
            let apps = second < 50 ? [Fixture.aggregate(), Fixture.aggregate(Fixture.other)] : [Fixture.aggregate()]
            _ = recorder.record(Fixture.snapshot(at: t0.addingTimeInterval(Double(second)), apps: apps))
        }
        #expect(recorder.tracks[Fixture.app.id]?.points.count == 20)
        recorder.trim(olderThan: t0.addingTimeInterval(60), maxPoints: 100)
        #expect(recorder.tracks[Fixture.app.id]?.points.count == 8)
        #expect(recorder.tracks[Fixture.other.id] == nil)
        recorder.trim(olderThan: t0, maxPoints: 3)
        #expect(recorder.tracks[Fixture.app.id]?.points.map(\.at) == [85, 90, 95].map { t0.addingTimeInterval($0) })
    }

    @Test("A clock that jumps backwards drops the newer points")
    func clockBackwards() {
        var recorder = ActivityRecorder(bucketLength: 5)
        for second in stride(from: 0, through: 50, by: 5) {
            _ = recorder.record(Fixture.snapshot(at: t0.addingTimeInterval(Double(second)), apps: [Fixture.aggregate()]))
        }
        let rewound = recorder.record(Fixture.snapshot(at: t0.addingTimeInterval(20), apps: [Fixture.aggregate()]))
        #expect(!rewound)
        #expect(recorder.tracks[Fixture.app.id]?.points.map(\.at) == [0, 5, 10, 15].map { t0.addingTimeInterval($0) })
        let closed = recorder.record(Fixture.snapshot(at: t0.addingTimeInterval(25), apps: [Fixture.aggregate()]))
        #expect(closed)
        #expect(recorder.tracks[Fixture.app.id]?.points.last?.at == t0.addingTimeInterval(20))
    }
}
