import Core
import Simulated
import Testing

@Suite("Simulated sources")
struct SimulatedSourcesTests {
    @Test("Simulated CPU is deterministic for a seed")
    func deterministic() async throws {
        let first = SimulatedCPUSource(seed: 42)
        let second = SimulatedCPUSource(seed: 42)
        for _ in 0 ..< 50 {
            let a = try await first.sample()
            let b = try await second.sample()
            #expect(a == b)
        }
    }

    @Test("Different seeds diverge")
    func seedsDiffer() async throws {
        let first = SimulatedCPUSource(seed: 1)
        let second = SimulatedCPUSource(seed: 2)
        var differences = 0
        for _ in 0 ..< 20 where try await first.sample() != second.sample() {
            differences += 1
        }
        #expect(differences > 0)
    }

    @Test("Simulated CPU stays believable over ten minutes of ticks")
    func believable() async throws {
        let source = SimulatedCPUSource()
        var totals: [Double] = []
        for _ in 0 ..< 600 {
            let stats = try await source.sample()
            #expect((0 ... 100).contains(stats.totalPercent))
            #expect(stats.perCorePercent.count == SimulatedCatalog.topology.coreCount)
            #expect(abs(stats.userPercent + stats.systemPercent - stats.totalPercent) < 0.0001)
            totals.append(stats.totalPercent)
        }
        let mean = totals.reduce(0, +) / Double(totals.count)
        // A mostly idle developer Mac: busy sometimes, never pinned, never flat.
        #expect((8 ... 45).contains(mean))
        #expect(totals.max() ?? 0 > mean + 10)
        #expect(totals.min() ?? 100 < mean)
    }

    @Test("Snapshot app CPU adds up to the system total, and processes add up to apps")
    func snapshotTotals() async {
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 10 {
            let snapshot = await source.next()
            let appCPU = snapshot.apps.reduce(0) { $0 + $1.cpuPercent }
            #expect(abs(appCPU - snapshot.system.cpu.totalPercent) < 0.001)
            for app in snapshot.apps {
                let processes = snapshot.processes.filter { $0.app == app.id }
                #expect(processes.count == app.processCount)
                #expect(abs(processes.reduce(0) { $0 + $1.cpuPercent } - app.cpuPercent) < 0.001)
            }
        }
    }

    @Test("Resolver attributes every simulated process to a catalog app")
    func resolver() async throws {
        let readings = try await SimulatedProcessSource().sample()
        let resolved = await SimulatedAppResolver().resolve(readings)
        #expect(resolved.count == readings.count)
        #expect(resolved.values.allSatisfy { $0.kind != .other })
        #expect(Set(resolved.values.map(\.id)).count == SimulatedCatalog.apps.count)
    }

    @Test("Process counters only grow")
    func countersGrow() async throws {
        let source = SimulatedProcessSource()
        let first = try await source.sample()
        let second = try await source.sample()
        for (a, b) in zip(first, second) {
            #expect(a.pid == b.pid)
            #expect(b.cpuTime >= a.cpuTime)
            #expect(b.diskWriteBytes >= a.diskWriteBytes)
        }
    }

    @Test("History top apps are sorted and limited")
    func historyTopApps() async throws {
        let snapshots = SimulatedSnapshotSource()
        let store = SimulatedHistoryStore()
        for _ in 0 ..< 30 {
            try await store.record(snapshots.next())
        }
        let top = try await store.topApps(metric: .cpu, range: .h12, limit: 3)
        #expect(top.count == 3)
        #expect(top.map(\.value) == top.map(\.value).sorted(by: >))
    }

    @Test("Fanless and desktop Macs report no fans and no battery")
    func absentHardware() async throws {
        #expect(try await SimulatedSensorSource(hasFans: false).sample().fans.isEmpty)
        #expect(try await SimulatedBatterySource(hasBattery: false).sample() == nil)
    }
}
