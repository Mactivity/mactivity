import Core
import Foundation

/// Cumulative tick counters for one logical core, as `host_processor_info` reports them.
public struct CPUTicks: Hashable, Sendable, Codable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Pure CPU load math over tick counters, kept apart from the syscalls so it runs on fixtures.
public enum CPULoadMath {
    /// Per-core user/system percentages between two readings.
    ///
    /// With no previous reading (or a different core count), reports load since boot. The
    /// kernel's counters are 32-bit and wrap, so deltas are taken modulo 2^32.
    public static func perCore(previous: [CPUTicks]?, current: [CPUTicks]) -> [(user: Double, system: Double)] {
        current.enumerated().map { index, now in
            let before = previous.flatMap { $0.count == current.count ? $0[index] : nil }
                ?? CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
            let user = Double(delta(before.user, now.user) + delta(before.nice, now.nice))
            let system = Double(delta(before.system, now.system))
            let idle = Double(delta(before.idle, now.idle))
            let total = user + system + idle
            guard total > 0 else {
                return (0, 0)
            }
            return (user / total * 100, system / total * 100)
        }
    }

    /// `now - before` for a 32-bit counter that may have wrapped once.
    static func delta(_ before: UInt64, _ now: UInt64) -> UInt64 {
        UInt64(UInt32(truncatingIfNeeded: now) &- UInt32(truncatingIfNeeded: before))
    }

    public static func stats(
        previous: [CPUTicks]?,
        current: [CPUTicks],
        topology: CPUTopology,
        loadAverage: LoadAverage
    ) -> CPUStats {
        CPUStats.aggregate(
            perCore: perCore(previous: previous, current: current),
            topology: topology,
            loadAverage: loadAverage
        )
    }
}
