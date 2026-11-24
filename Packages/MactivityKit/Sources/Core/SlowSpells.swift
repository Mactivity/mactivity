import Foundation

/// A stretch when the whole Mac struggled (D-169): its processor near full, memory short, or
/// slowed to stay cool. Found in History afterwards, so "Why is my Mac slow?" can answer for a
/// slowdown that has already passed.
public struct SlowSpell: Hashable, Sendable, Identifiable {
    /// Most telling first: a full processor names its apps most clearly.
    public enum Cause: Int, Hashable, Sendable, Comparable, CaseIterable {
        case cpu, memory, heat

        public static func < (lhs: Cause, rhs: Cause) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// What to rank apps by for this cause.
        public var metric: Metric {
            self == .memory ? .memory : .cpu
        }
    }

    public var id: Date {
        start
    }

    public let start: Date
    public let end: Date
    /// Every cause that held at some point, most telling first.
    public let causes: [Cause]
    /// The highest bucket average of the whole Mac's CPU, in percent.
    public let peakCPU: Double
    /// The highest bucket average of memory pressure, in percent.
    public let peakMemoryPressure: Double

    public init(start: Date, end: Date, causes: [Cause], peakCPU: Double, peakMemoryPressure: Double) {
        self.start = start
        self.end = end
        self.causes = causes
        self.peakCPU = peakCPU
        self.peakMemoryPressure = peakMemoryPressure
    }

    public var duration: TimeInterval {
        end.timeIntervalSince(start)
    }
}

public enum SlowSpells {
    /// A bucket's average CPU at or over this is a struggling Mac. Under the live warning's 85%,
    /// because an average over minutes hides the peaks a person feels.
    public static let cpuPercent = 80.0
    /// Memory pressure (100 − `kern.memorystatus_level`) at which macOS is compressing and swapping hard.
    public static let memoryPressurePercent = 80.0
    /// Thermal rank averaged over a bucket: halfway between fair and serious means it throttled
    /// for a good part of it.
    public static let thermalRank = 1.5
    /// Shorter than this is a blip, not a slowdown anyone would remember.
    public static let minimumLength: TimeInterval = 3 * 60

    /// The spells in one run of evenly spaced buckets, oldest first.
    ///
    /// - Parameters:
    ///   - cpu, memoryPressure, thermal: the whole Mac's series, each point at its bucket's start.
    ///   - bucket: the series' spacing (60 for minutes, 900 for quarter-hours).
    public static func find(
        cpu: [SeriesPoint], memoryPressure: [SeriesPoint], thermal: [SeriesPoint], bucket: TimeInterval
    ) -> [SlowSpell] {
        var strained: [Date: Set<SlowSpell.Cause>] = [:]
        func mark(_ points: [SeriesPoint], _ cause: SlowSpell.Cause, over line: Double) {
            for point in points where point.average >= line {
                strained[point.at, default: []].insert(cause)
            }
        }
        mark(cpu, .cpu, over: cpuPercent)
        mark(memoryPressure, .memory, over: memoryPressurePercent)
        mark(thermal, .heat, over: thermalRank)
        let cpuAt = Dictionary(cpu.map { ($0.at, $0.average) }, uniquingKeysWith: max)
        let memoryAt = Dictionary(memoryPressure.map { ($0.at, $0.average) }, uniquingKeysWith: max)

        var spells: [SlowSpell] = []
        var current: Draft?
        func close() {
            if let spell = current, spell.end.timeIntervalSince(spell.start) >= minimumLength {
                spells.append(SlowSpell(
                    start: spell.start, end: spell.end, causes: spell.causes.sorted(),
                    peakCPU: spell.cpu, peakMemoryPressure: spell.memory
                ))
            }
            current = nil
        }
        for at in strained.keys.sorted() {
            let causes = strained[at] ?? []
            let cpu = cpuAt[at] ?? 0
            let memory = memoryAt[at] ?? 0
            // The next bucket, give or take a few seconds of clock drift, continues the spell.
            if var spell = current, at.timeIntervalSince(spell.end) <= bucket * 0.25 {
                spell.end = at.addingTimeInterval(bucket)
                spell.causes.formUnion(causes)
                spell.cpu = max(spell.cpu, cpu)
                spell.memory = max(spell.memory, memory)
                current = spell
            } else {
                close()
                current = Draft(start: at, end: at.addingTimeInterval(bucket), causes: causes, cpu: cpu, memory: memory)
            }
        }
        close()
        return spells
    }

    /// A spell while it's being joined up.
    private struct Draft {
        var start: Date
        var end: Date
        var causes: Set<SlowSpell.Cause>
        var cpu: Double
        var memory: Double
    }

    /// The most recent spells first, at most `limit`, from minutes (recent) and quarter-hours
    /// (older). A quarter-hour spell that overlaps a minute one is the same slowdown seen
    /// coarser, so the finer one wins.
    public static func recent(minutes: [SlowSpell], quarters: [SlowSpell], limit: Int) -> [SlowSpell] {
        let older = quarters.filter { quarter in
            !minutes.contains { $0.start < quarter.end && quarter.start < $0.end }
        }
        return Array((minutes + older).sorted { $0.start > $1.start }.prefix(limit))
    }
}
