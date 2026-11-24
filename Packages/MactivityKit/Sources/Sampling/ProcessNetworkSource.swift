import Darwin
import Foundation
import PrivateAPIs

/// Cumulative network bytes per process (spec 6.5). The sampler turns two readings into rates
/// with `ProcessNetworkMath`.
public protocol ProcessNetworkSource: Sendable {
    /// Bytes received and sent per PID since the source started watching, including sockets that
    /// have since closed. Nil when per-process figures are unavailable, so rates stay nil rather
    /// than reading as zero.
    func cumulativeBytes() async -> [Int32: (rx: UInt64, tx: UInt64)]?

    /// The only user whose processes this source can see, or nil if it sees every user's.
    /// Processes of other users get nil rates instead of a misleading zero.
    var visibleUID: UInt32? { get }
}

/// The live source: `NetworkStatistics.framework` through `PrivateAPIs`. Without Apple's private
/// entitlement the kernel only reports sockets of the user running the app (see
/// `NetworkStatisticsMonitor` for what was measured).
public final class ProcessNetworkSampler: ProcessNetworkSource {
    private let monitor: NetworkStatisticsMonitor

    /// Starts watching sockets right away, so bytes of connections that close before the first
    /// query still count.
    public init() {
        monitor = NetworkStatisticsMonitor()
    }

    public var isAvailable: Bool {
        monitor.isAvailable
    }

    public var visibleUID: UInt32? {
        getuid()
    }

    public func cumulativeBytes() async -> [Int32: (rx: UInt64, tx: UInt64)]? {
        await monitor.cumulativeBytes()
    }
}
