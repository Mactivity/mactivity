import Core
import Foundation

/// Turns two readings of cumulative per-process network bytes into rates (spec 6.5). Pure.
public enum ProcessNetworkMath {
    /// One process's cumulative bytes at the last pass, with the start time that identifies it.
    public struct Counter: Hashable, Sendable, Codable {
        public let startTime: Date
        public let rx: UInt64
        public let tx: UInt64

        public init(startTime: Date, rx: UInt64, tx: UInt64) {
            self.startTime = startTime
            self.rx = rx
            self.tx = tx
        }
    }

    public struct Rate: Hashable, Sendable, Codable {
        public let inBPS: Double
        public let outBPS: Double

        public init(inBPS: Double, outBPS: Double) {
            self.inBPS = inBPS
            self.outBPS = outBPS
        }
    }

    /// Rates for every process in `processes` that the source can see, and the counters to pass
    /// as `previous` next time.
    ///
    /// - A process with no bytes in `current` has no open or closed sockets: 0 B/s.
    /// - First sight of a PID, or a PID now held by a different process (another start time), is
    ///   0 B/s: its bytes include time before we looked. Unless it started after the previous
    ///   query (`previousQueryAt`): then all its bytes are this interval's (D-142). A `curl` that
    ///   downloaded 2 GB between two idle queries read as nothing.
    /// - A counter that went backwards is 0 B/s for that pass, and the new value is the baseline.
    /// - Processes of users other than `visibleUID` get no rate at all (nil in the sample), since
    ///   the source can't see their sockets.
    public static func rates(
        previous: [Int32: Counter],
        current: [Int32: (rx: UInt64, tx: UInt64)],
        processes: [ProcessReading],
        visibleUID: UInt32?,
        elapsedSeconds: Double,
        previousQueryAt: Date? = nil
    ) -> (rates: [Int32: Rate], counters: [Int32: Counter]) {
        var rates: [Int32: Rate] = [:]
        var counters: [Int32: Counter] = [:]
        for process in processes {
            if let visibleUID, process.uid != visibleUID {
                continue
            }
            let bytes = current[process.pid] ?? (0, 0)
            let counter = Counter(startTime: process.startTime, rx: bytes.rx, tx: bytes.tx)
            counters[process.pid] = counter
            let known = previous[process.pid].flatMap { $0.startTime == process.startTime ? $0 : nil }
            let young = previousQueryAt.map { process.startTime >= $0 } ?? false
            guard elapsedSeconds > 0, let before = known ?? (young ? Counter(startTime: process.startTime, rx: 0, tx: 0) : nil) else {
                rates[process.pid] = Rate(inBPS: 0, outBPS: 0)
                continue
            }
            func rate(_ now: UInt64, _ then: UInt64) -> Double {
                now >= then ? Double(now - then) / elapsedSeconds : 0
            }
            rates[process.pid] = Rate(inBPS: rate(counter.rx, before.rx), outBPS: rate(counter.tx, before.tx))
        }
        return (rates, counters)
    }

    /// The samples with their network rates filled in; samples without a rate keep nil.
    public static func applying(_ rates: [Int32: Rate], to samples: [ProcessSample]) -> [ProcessSample] {
        samples.map { sample in
            guard let rate = rates[sample.pid] else {
                return sample
            }
            return sample.withNetwork(inBPS: rate.inBPS, outBPS: rate.outBPS)
        }
    }
}
