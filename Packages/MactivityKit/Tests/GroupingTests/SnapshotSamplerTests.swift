import Core
@testable import Grouping
import Sampling
import Simulated
import Testing

@Suite("Snapshot sampler")
struct SnapshotSamplerTests {
    func sampler() -> SnapshotSampler {
        SnapshotSampler(sources: .init(
            cpu: SimulatedCPUSource(), memory: SimulatedMemorySource(), disk: SimulatedDiskSource(),
            network: SimulatedNetworkSource(), gpu: SimulatedGPUSource(), battery: SimulatedBatterySource(),
            processes: SimulatedProcessSource(), resolver: SimulatedAppResolver(), thermal: { .nominal }
        ))
    }

    @Test("A tick groups every process into an app, plus the system remainder")
    func groups() async throws {
        let sampler = sampler()
        _ = await sampler.tick()
        try await Task.sleep(for: .milliseconds(50))
        let snapshot = await sampler.tick()
        #expect(snapshot.processes.count == SimulatedCatalog.apps.reduce(0) { $0 + $1.processNames.count })
        #expect(snapshot.apps.contains { $0.app.kind == .system })
        let appCPU = snapshot.apps.reduce(0) { $0 + $1.cpuPercent }
        #expect(appCPU >= snapshot.system.cpu.totalPercent - 0.0001)
    }

    @Test("The stream yields snapshots and ends cleanly")
    func stream() async {
        let sampler = sampler()
        await sampler.setCadence(.visible)
        let stream = await sampler.snapshots()
        var received = 0
        for await _ in stream {
            received += 1
            if received == 2 {
                break
            }
        }
        #expect(received == 2)
    }

    @Test("While idle, processes are read on every other 5 s tick; while visible, every tick")
    func idleProcessCadence() async {
        let counter = CountingProcessSource()
        let sampler = SnapshotSampler(sources: .init(
            cpu: SimulatedCPUSource(), memory: SimulatedMemorySource(), disk: SimulatedDiskSource(),
            network: SimulatedNetworkSource(), gpu: SimulatedGPUSource(), battery: SimulatedBatterySource(),
            processes: counter, resolver: SimulatedAppResolver(), thermal: { .nominal }
        ))
        // Ticks called back to back are well under 10 s apart: only the first reads processes.
        for _ in 0 ..< 4 {
            _ = await sampler.tick()
        }
        #expect(await counter.calls == 1)
        await sampler.setCadence(.visible)
        for _ in 0 ..< 3 {
            _ = await sampler.tick()
        }
        #expect(await counter.calls == 4)
    }

    @Test("Sensors: read on the first idle tick (thermal history), with menu bar demand, and while visible")
    func sensorGating() async {
        let sampler = SnapshotSampler(sources: .init(
            cpu: SimulatedCPUSource(), memory: SimulatedMemorySource(), disk: SimulatedDiskSource(),
            network: SimulatedNetworkSource(), gpu: SimulatedGPUSource(), battery: SimulatedBatterySource(),
            processes: SimulatedProcessSource(), resolver: SimulatedAppResolver(), sensors: SimulatedSensorSource(),
            thermal: { .nominal }
        ))
        #expect(await sampler.tick().system.sensors != nil)
        #expect(SnapshotSampler.historySensorInterval > SnapshotSampler.idleSensorInterval)
        await sampler.setSensorDemand(true)
        #expect(await sampler.tick().system.sensors != nil)
        await sampler.setSensorDemand(false)
        await sampler.setCadence(.visible)
        #expect(await sampler.tick().system.sensors?.fans.isEmpty == false)
    }

    @Test("macOS's own processes: usage skipped unless their row is expanded in a visible window")
    func systemDetail() async {
        let recorder = SkipRecordingProcessSource()
        let sampler = SnapshotSampler(sources: .init(
            cpu: SimulatedCPUSource(), memory: SimulatedMemorySource(), disk: SimulatedDiskSource(),
            network: SimulatedNetworkSource(), gpu: SimulatedGPUSource(), battery: SimulatedBatterySource(),
            processes: recorder, resolver: SimulatedAppResolver(), thermal: { .nominal }
        ))
        await sampler.setCadence(.visible)
        _ = await sampler.tick() // learns which pids are macOS's
        _ = await sampler.tick()
        #expect(await recorder.lastSkipped.isEmpty == false, "visible, row collapsed: skipped")
        await sampler.setSystemDetail(true)
        _ = await sampler.tick()
        #expect(await recorder.lastSkipped.isEmpty, "visible, row expanded: read")
        await sampler.setSystemDetail(false)
        _ = await sampler.tick()
        #expect(await recorder.lastSkipped.isEmpty == false, "collapsed again: skipped")
    }

    @Test("Per-app GPU: every pass while a per-tick figure shows it, otherwise every 3 s; first pass always")
    func gpuWalkCadence() {
        let start = SuspendingClock.now
        #expect(SnapshotSampler.gpuWalkDue(detail: false, lastWalk: nil, now: start))
        #expect(!SnapshotSampler.gpuWalkDue(detail: false, lastWalk: start, now: start + .seconds(1)))
        #expect(SnapshotSampler.gpuWalkDue(detail: false, lastWalk: start, now: start + .seconds(3)))
        #expect(SnapshotSampler.gpuWalkDue(detail: true, lastWalk: start, now: start + .seconds(1)))
    }

    @Test("Low Power Mode doubles the interval, idle and visible")
    func lowPower() {
        #expect(SnapshotSampler.sleepInterval(cadence: .idle, visible: .seconds(1), lowPower: false) == .seconds(10))
        #expect(SnapshotSampler.sleepInterval(cadence: .idle, visible: .seconds(1), lowPower: true) == .seconds(20))
        #expect(SnapshotSampler.sleepInterval(cadence: .visible, visible: .seconds(2), lowPower: false) == .seconds(2))
        #expect(SnapshotSampler.sleepInterval(cadence: .visible, visible: .seconds(2), lowPower: true) == .seconds(4))
    }

    @Test("Sleep slack: a fifth of the idle interval, a tenth of a second while visible")
    func sleepTolerance() {
        #expect(SnapshotSampler.sleepTolerance(for: .idle) == .seconds(2))
        #expect(SnapshotSampler.sleepTolerance(for: .visible) == .milliseconds(100))
    }

    @Test("The live resolver resolves this test process")
    func liveResolver() async throws {
        let readings = try await Sampling.ProcessSampler().sample()
        let resolved = await LiveAppResolver().resolve(readings)
        #expect(resolved.count == readings.count)
    }
}

actor CountingProcessSource: ProcessSource {
    private let inner = SimulatedProcessSource()
    private(set) var calls = 0

    func sample() async throws -> [ProcessReading] {
        calls += 1
        return try await inner.sample()
    }
}

actor SkipRecordingProcessSource: ProcessSource {
    private let inner = SimulatedProcessSource()
    private(set) var lastSkipped: Set<Int32> = []

    func sample() async throws -> [ProcessReading] {
        try await sample(skippingUsageFor: [])
    }

    func sample(skippingUsageFor pids: Set<Int32>) async throws -> [ProcessReading] {
        lastSkipped = pids
        return try await inner.sample()
    }
}
