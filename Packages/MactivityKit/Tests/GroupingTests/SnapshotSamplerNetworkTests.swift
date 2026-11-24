import Core
@testable import Grouping
import Sampling
import Simulated
import Testing

@Suite("Snapshot sampler: per-app network")
struct SnapshotSamplerNetworkTests {
    func sampler(network: (any ProcessNetworkSource)?) -> SnapshotSampler {
        SnapshotSampler(sources: .init(
            cpu: SimulatedCPUSource(), memory: SimulatedMemorySource(), disk: SimulatedDiskSource(),
            network: SimulatedNetworkSource(), gpu: SimulatedGPUSource(), battery: SimulatedBatterySource(),
            processes: SimulatedProcessSource(), resolver: SimulatedAppResolver(), processNetwork: network,
            thermal: { .nominal }
        ), networkIntervals: (.zero, .zero))
    }

    @Test("Visible-user processes get rates, other users' stay nil, and apps sum them")
    func rates() async throws {
        let pids = try await SimulatedProcessSource().sample().map(\.pid)
        let network = SteadyProcessNetworkSource(pids: pids, bytesPerCall: 1000, visibleUID: 501)
        let sampler = sampler(network: network)
        await sampler.setCadence(.visible)
        let first = await sampler.tick()
        #expect(first.processes.filter { $0.netInBPS != nil }.allSatisfy { $0.netInBPS == 0 })
        try await Task.sleep(for: .milliseconds(50))
        let second = await sampler.tick()

        // The simulated catalog runs apps as 501 and macOS processes as root.
        let systemIDs = Set(second.apps.filter { $0.app.kind == .system }.map(\.app.id))
        let appProcesses = second.processes.filter { !systemIDs.contains($0.app) }
        #expect(!appProcesses.isEmpty)
        #expect(appProcesses.allSatisfy { ($0.netInBPS ?? 0) > 0 && ($0.netOutBPS ?? 0) > 0 })
        let systemProcesses = second.processes.filter { systemIDs.contains($0.app) }
        #expect(!systemProcesses.isEmpty)
        #expect(systemProcesses.allSatisfy { $0.netInBPS == nil })
        let apps = second.apps.filter { $0.app.kind != .system }
        #expect(apps.allSatisfy { ($0.netInBPS ?? 0) > 0 })
    }

    @Test("An unavailable source leaves every rate nil")
    func unavailable() async {
        let sampler = sampler(network: UnavailableProcessNetworkSource())
        await sampler.setCadence(.visible)
        _ = await sampler.tick()
        let snapshot = await sampler.tick()
        #expect(snapshot.processes.allSatisfy { $0.netInBPS == nil && $0.netOutBPS == nil })
        #expect(snapshot.apps.allSatisfy { $0.netInBPS == nil })
    }

    @Test("Idle: queried every 60 s; visible: every 3 s, with the app lists; first pass always")
    func queryCadence() {
        let start = SuspendingClock.now
        #expect(SnapshotSampler.networkQueryDue(cadence: .idle, lastQuery: nil, now: start))
        #expect(!SnapshotSampler.networkQueryDue(cadence: .idle, lastQuery: start, now: start + .seconds(20)))
        #expect(SnapshotSampler.networkQueryDue(cadence: .idle, lastQuery: start, now: start + .seconds(60)))
        #expect(!SnapshotSampler.networkQueryDue(cadence: .visible, lastQuery: start, now: start + .seconds(1)))
        #expect(SnapshotSampler.networkQueryDue(cadence: .visible, lastQuery: start, now: start + .seconds(3)))
    }

    @Test("No source: rates stay nil, as before")
    func noSource() async {
        let sampler = sampler(network: nil)
        _ = await sampler.tick()
        #expect(await sampler.tick().processes.allSatisfy { $0.netInBPS == nil })
    }
}

/// Every PID in `pids` gains `bytesPerCall` in and half that out per call.
actor SteadyProcessNetworkSource: ProcessNetworkSource {
    private let pids: [Int32]
    private let bytesPerCall: UInt64
    private var calls: UInt64 = 0
    nonisolated let visibleUID: UInt32?

    init(pids: [Int32], bytesPerCall: UInt64, visibleUID: UInt32?) {
        self.pids = pids
        self.bytesPerCall = bytesPerCall
        self.visibleUID = visibleUID
    }

    func cumulativeBytes() async -> [Int32: (rx: UInt64, tx: UInt64)]? {
        calls += 1
        var bytes: [Int32: (rx: UInt64, tx: UInt64)] = [:]
        for pid in pids {
            bytes[pid] = (calls * bytesPerCall, calls * bytesPerCall / 2)
        }
        return bytes
    }
}

struct UnavailableProcessNetworkSource: ProcessNetworkSource {
    var visibleUID: UInt32? {
        nil
    }

    func cumulativeBytes() async -> [Int32: (rx: UInt64, tx: UInt64)]? {
        nil
    }
}
