import Core
import Foundation
import Testing

@Suite("CPU topology and aggregation")
struct CPUTopologyTests {
    @Test("Least performant level gets the lowest core numbers")
    func ordering() {
        let topology = CPUTopology.fromPerfLevels([("Performance", 4), ("Efficiency", 6)])
        #expect(topology.coreCount == 10)
        #expect(topology.levels[0].name == "Performance")
        #expect(topology.levels[0].coreIndexes == Array(6 ..< 10))
        #expect(topology.levels[1].coreIndexes == Array(0 ..< 6))
    }

    @Test("Aggregate clamps per-core totals to 100")
    func clamps() {
        let topology = CPUTopology.fromPerfLevels([("CPU", 2)])
        let stats = CPUStats.aggregate(
            perCore: [(user: 80, system: 40), (user: 10, system: 0)], topology: topology, loadAverage: .zero
        )
        #expect(stats.perCorePercent == [100, 10])
        #expect(stats.clusters[0].percent == 55)
    }

    @Test("Aggregate of no cores is zero, not NaN")
    func empty() {
        let stats = CPUStats.aggregate(perCore: [], topology: CPUTopology(levels: []), loadAverage: .zero)
        #expect(stats.totalPercent == 0)
        #expect(stats.clusters.isEmpty)
    }

    @Test("Status words", arguments: [(10.0, MetricStatus.normal), (50, .elevated), (84.9, .elevated), (85, .critical)])
    func status(percent: Double, expected: MetricStatus) {
        #expect(MetricStatus(cpuPercent: percent) == expected)
    }
}

@Suite("CPU topology from IORegistry cluster types")
struct ClusterTypeTopologyTests {
    let levels: [(name: String, count: Int)] = [("Super", 5), ("Performance", 10)]

    @Test("M5 Pro: letter groups map to levels by count")
    func m5Pro() throws {
        var types: [Int: String] = [:]
        for cpu in 0 ..< 10 {
            types[cpu] = "M"
        }
        for cpu in 10 ..< 15 {
            types[cpu] = "P"
        }
        let topology = try #require(CPUTopology.fromClusterTypes(perfLevels: levels, clusterTypeByCPU: types))
        #expect(topology.levels[0].name == "Super")
        #expect(topology.levels[0].coreIndexes == Array(10 ..< 15))
        #expect(topology.levels[1].coreIndexes == Array(0 ..< 10))
    }

    @Test("Interleaved numbering still maps correctly")
    func interleaved() throws {
        let types = Dictionary(uniqueKeysWithValues: (0 ..< 15).map { ($0, $0 % 3 == 0 ? "P" : "M") })
        let topology = try #require(CPUTopology.fromClusterTypes(perfLevels: levels, clusterTypeByCPU: types))
        #expect(topology.levels[0].coreIndexes == [0, 3, 6, 9, 12])
    }

    @Test("Equal counts are ambiguous, so it returns nil")
    func ambiguous() {
        let types = Dictionary(uniqueKeysWithValues: (0 ..< 8).map { ($0, $0 < 4 ? "E" : "P") })
        #expect(CPUTopology.fromClusterTypes(perfLevels: [("Performance", 4), ("Efficiency", 4)], clusterTypeByCPU: types) == nil)
    }

    @Test("Counts that don't add up return nil")
    func mismatch() {
        #expect(CPUTopology.fromClusterTypes(perfLevels: levels, clusterTypeByCPU: [0: "P"]) == nil)
    }
}

@Suite("Strain")
struct StrainTests {
    let now = Date(timeIntervalSince1970: 10000)

    func cpu(_ values: [Double], every seconds: Double = 5) -> [(at: Date, percent: Double)] {
        values.enumerated().map { (now.addingTimeInterval(-Double(values.count - 1 - $0.offset) * seconds), $0.element) }
    }

    func evaluate(
        _ history: [(at: Date, percent: Double)],
        memory: MemoryPressure = .normal,
        free: Double? = 0.5,
        thermal: ThermalPressure = .nominal
    ) -> StrainReason? {
        StrainDetector.evaluate(cpuHistory: history, now: now, memoryPressure: memory, bootVolumeFreeFraction: free, thermal: thermal)
    }

    @Test("CPU at or above 85% for a full minute is strain")
    func cpuSustained() {
        #expect(evaluate(cpu(Array(repeating: 90, count: 13))) == .cpu)
    }

    @Test("One dip below 85% in the minute is not")
    func cpuDip() {
        var values = Array(repeating: 90.0, count: 13)
        values[6] = 60
        #expect(evaluate(cpu(values)) == nil)
    }

    @Test("Less than a minute of history is not")
    func cpuShort() {
        #expect(evaluate(cpu(Array(repeating: 99, count: 6))) == nil)
    }

    @Test("Memory, disk, and thermal")
    func others() {
        #expect(evaluate([], memory: .warning) == .memory)
        #expect(evaluate([], free: 0.04) == .disk)
        #expect(evaluate([], thermal: .serious) == .thermal)
        #expect(evaluate([], thermal: .fair) == nil)
    }
}
