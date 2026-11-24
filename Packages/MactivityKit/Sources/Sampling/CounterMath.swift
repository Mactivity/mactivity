import Foundation

/// Rates from cumulative byte counters, shared by the disk and network samplers.
public enum CounterMath {
    /// Bytes per second between two readings of the same set of counters, keyed by device.
    ///
    /// Each key contributes `current - previous`. A key that is new this tick (a disk just
    /// attached, an interface just up) contributes nothing, so its whole since-boot count doesn't
    /// show up as a spike. A key that went away contributes nothing. A counter that went backwards
    /// (a device reset or replaced under the same key) contributes nothing for that tick.
    /// With no previous reading, or no elapsed time, the rate is 0.
    public static func rate<Key: Hashable>(
        previous: [Key: UInt64]?,
        current: [Key: UInt64],
        elapsedSeconds: Double
    ) -> Double {
        guard let previous, elapsedSeconds > 0 else {
            return 0
        }
        var bytes: UInt64 = 0
        for (key, now) in current {
            guard let before = previous[key], now >= before else {
                continue
            }
            bytes &+= now - before
        }
        return Double(bytes) / elapsedSeconds
    }
}
