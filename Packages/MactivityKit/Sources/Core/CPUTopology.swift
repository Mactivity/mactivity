import Foundation

/// Which logical cores belong to which performance level. Real samplers read it from the
/// kernel; simulated ones make one up.
public struct CPUTopology: Hashable, Sendable, Codable {
    public struct Level: Hashable, Sendable, Codable {
        public let name: String
        /// 0 is the most performant level.
        public let level: Int
        public let coreIndexes: [Int]

        public init(name: String, level: Int, coreIndexes: [Int]) {
            self.name = name
            self.level = level
            self.coreIndexes = coreIndexes
        }
    }

    public let levels: [Level]

    public init(levels: [Level]) {
        self.levels = levels
    }

    public var coreCount: Int {
        levels.reduce(0) { $0 + $1.coreIndexes.count }
    }

    /// Builds a topology from per-level core counts, most performant first (`hw.perflevel0`
    /// first), assuming the kernel numbers the least performant level's cores first.
    ///
    /// That ordering holds on M1–M4 (E cores first) and on the M5 Pro ("Performance" cores 0–9,
    /// "Super" cores 10–14, per IORegistry `cluster-type`). M1 verifies it against IORegistry;
    /// see D-005.
    public static func fromPerfLevels(_ levels: [(name: String, count: Int)]) -> CPUTopology {
        var next = 0
        var built: [Level] = []
        for (index, level) in levels.enumerated().reversed() {
            built.append(Level(name: level.name, level: index, coreIndexes: Array(next ..< next + level.count)))
            next += level.count
        }
        return CPUTopology(levels: built.sorted { $0.level < $1.level })
    }

    /// Builds a topology from the kernel's per-level counts plus IORegistry's `cluster-type`
    /// letter for each logical CPU. A letter group maps to the level with the same core count.
    /// Returns nil when that's ambiguous (two levels with the same count) or doesn't add up, so
    /// the caller can fall back to `fromPerfLevels`.
    public static func fromClusterTypes(
        perfLevels: [(name: String, count: Int)],
        clusterTypeByCPU: [Int: String]
    ) -> CPUTopology? {
        let counts = perfLevels.map(\.count)
        guard Set(counts).count == counts.count,
              clusterTypeByCPU.count == counts.reduce(0, +)
        else {
            return nil
        }
        let groups = Dictionary(grouping: clusterTypeByCPU.keys, by: { clusterTypeByCPU[$0] ?? "" })
        var levels: [Level] = []
        for (index, level) in perfLevels.enumerated() {
            guard let cores = groups.values.first(where: { $0.count == level.count }) else {
                return nil
            }
            levels.append(Level(name: level.name, level: index, coreIndexes: cores.sorted()))
        }
        return CPUTopology(levels: levels)
    }
}

extension CPUStats {
    /// Aggregates per-core user/system percentages into totals and clusters.
    ///
    /// - Parameter perCore: one entry per logical core, each value 0...100.
    public static func aggregate(
        perCore: [(user: Double, system: Double)],
        topology: CPUTopology,
        loadAverage: LoadAverage
    ) -> CPUStats {
        let perCoreTotal = perCore.map { min(100, max(0, $0.user + $0.system)) }
        let count = Double(max(1, perCore.count))
        let user = perCore.reduce(0) { $0 + $1.user } / count
        let system = perCore.reduce(0) { $0 + $1.system } / count
        let clusters = topology.levels.map { level in
            let loads = level.coreIndexes.compactMap { perCoreTotal.indices.contains($0) ? perCoreTotal[$0] : nil }
            let average = loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count)
            return CoreCluster(name: level.name, level: level.level, coreIndexes: level.coreIndexes, percent: average)
        }
        return CPUStats(
            totalPercent: min(100, max(0, user + system)),
            userPercent: user,
            systemPercent: system,
            perCorePercent: perCoreTotal,
            clusters: clusters,
            loadAverage: loadAverage
        )
    }
}
