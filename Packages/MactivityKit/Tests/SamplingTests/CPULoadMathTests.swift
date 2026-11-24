import Core
import Foundation
@testable import Sampling
import Testing

struct CPUTicksFixture: Decodable {
    struct PerfLevel: Decodable {
        let name: String
        let count: Int
    }

    let perfLevels: [PerfLevel]
    let previous: [CPUTicks]
    let current: [CPUTicks]

    var topology: CPUTopology {
        CPUTopology.fromPerfLevels(perfLevels.map { (name: $0.name, count: $0.count) })
    }
}

@Suite("CPU load math")
struct CPULoadMathTests {
    let fixture: CPUTicksFixture

    init() throws {
        fixture = try Fixtures.load("cpu-ticks-m5pro.json")
    }

    @Test("Totals, user, and system match the fixture's deltas")
    func totals() {
        let stats = CPULoadMath.stats(
            previous: fixture.previous, current: fixture.current,
            topology: fixture.topology, loadAverage: .zero
        )
        #expect(abs(stats.totalPercent - 30) < 0.0001)
        #expect(abs(stats.userPercent - 325.0 / 15) < 0.0001)
        #expect(abs(stats.systemPercent - 125.0 / 15) < 0.0001)
        #expect(stats.perCorePercent.count == 15)
    }

    @Test("Clusters split by perf level, most performant first")
    func clusters() {
        let stats = CPULoadMath.stats(
            previous: fixture.previous, current: fixture.current,
            topology: fixture.topology, loadAverage: .zero
        )
        #expect(stats.clusters.map(\.name) == ["Super", "Performance"])
        #expect(stats.clusters[0].coreIndexes == Array(10 ..< 15))
        #expect(stats.clusters[1].coreIndexes == Array(0 ..< 10))
        #expect(abs(stats.clusters[0].percent - 10) < 0.0001)
        #expect(abs(stats.clusters[1].percent - 40) < 0.0001)
    }

    @Test("A 32-bit counter that wrapped still gives the right delta")
    func wrappedCounter() {
        let before = CPUTicks(user: UInt64(UInt32.max) - 9, system: 100, idle: 1000, nice: 0)
        let after = CPUTicks(user: 40, system: 110, idle: 1050, nice: 0)
        let load = CPULoadMath.perCore(previous: [before], current: [after])
        // user delta 50 (10 to wrap, 40 after), system 10, idle 50.
        #expect(abs(load[0].user - 50.0 / 110 * 100) < 0.0001)
        #expect(abs(load[0].system - 10.0 / 110 * 100) < 0.0001)
    }

    @Test("No previous reading reports load since boot")
    func firstReading() {
        let load = CPULoadMath.perCore(previous: nil, current: [CPUTicks(user: 20, system: 5, idle: 75, nice: 0)])
        #expect(load[0].user == 20)
        #expect(load[0].system == 5)
    }

    @Test("A changed core count falls back to since-boot, not garbage")
    func coreCountChanged() {
        let one = [CPUTicks(user: 10, system: 10, idle: 80, nice: 0)]
        let two = one + one
        let load = CPULoadMath.perCore(previous: one, current: two)
        #expect(load.count == 2)
        #expect(load.allSatisfy { $0.user == 10 && $0.system == 10 })
    }

    @Test("An idle tick with no elapsed time reports zero, not NaN")
    func noElapsedTime() {
        let ticks = [CPUTicks(user: 10, system: 10, idle: 80, nice: 0)]
        let load = CPULoadMath.perCore(previous: ticks, current: ticks)
        #expect(load[0].user == 0)
        #expect(load[0].system == 0)
    }
}

/// Smoke test of the syscall wrapper on this Mac. The math is covered by fixtures above.
@Suite("CPU sampler (live)")
struct CPUSamplerTests {
    @Test("Reads every logical core and stays in range")
    func readsAllCores() async throws {
        let sampler = CPUSampler()
        _ = try await sampler.sample()
        try await Task.sleep(for: .milliseconds(200))
        let stats = try await sampler.sample()
        #expect(stats.perCorePercent.count == ProcessInfo.processInfo.processorCount)
        #expect((0 ... 100).contains(stats.totalPercent))
        #expect(stats.perCorePercent.allSatisfy { (0 ... 100).contains($0) })
        #expect(stats.clusters.flatMap(\.coreIndexes).sorted() == Array(0 ..< stats.perCorePercent.count))
    }
}
