import Foundation

/// Cumulative 64-bit byte counters for one interface (`if_data64`).
public struct InterfaceCounters: Hashable, Sendable, Codable {
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(bytesIn: UInt64, bytesOut: UInt64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// Pure network math (spec 6.5, system-wide), kept apart from sysctl so it runs on fixtures.
public enum NetworkMath {
    /// Virtual and peer-to-peer interfaces that would double-count or aren't the Mac's own traffic:
    /// loopback, VPN tunnels, AirDrop/AWDL, low-latency WLAN, bridges, the Wi-Fi hotspot, the
    /// Apple-internal `anpi` links, and the IPv6 tunnels.
    public static let excludedPrefixes = ["lo", "utun", "awdl", "llw", "bridge", "ap", "anpi", "gif", "stf"]

    /// Only physical Ethernet-class interfaces count: `en*` (Wi-Fi, Ethernet, Thunderbolt, USB).
    public static func isCounted(_ name: String) -> Bool {
        name.hasPrefix("en") && !excludedPrefixes.contains { name.hasPrefix($0) }
    }

    /// In and out throughput between two readings, keyed by BSD name. Interfaces that aren't
    /// counted are ignored, and see `CounterMath.rate` for new, vanished, and reset interfaces.
    public static func throughput(
        previous: [String: InterfaceCounters]?,
        current: [String: InterfaceCounters],
        elapsedSeconds: Double
    ) -> (inBPS: Double, outBPS: Double) {
        let previous = previous?.filter { isCounted($0.key) }
        let current = current.filter { isCounted($0.key) }
        return (
            CounterMath.rate(
                previous: previous?.mapValues(\.bytesIn),
                current: current.mapValues(\.bytesIn),
                elapsedSeconds: elapsedSeconds
            ),
            CounterMath.rate(
                previous: previous?.mapValues(\.bytesOut),
                current: current.mapValues(\.bytesOut),
                elapsedSeconds: elapsedSeconds
            )
        )
    }
}
