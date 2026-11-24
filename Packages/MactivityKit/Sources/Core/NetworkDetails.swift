import Foundation

/// The connection the Mac is using now, for the Network tab (D-149): which interface, its local
/// address and the router, and for Wi-Fi the signal, the rate and the channel. Read from the
/// Mac's own state; nothing is sent anywhere.
public struct NetworkDetails: Hashable, Sendable {
    public enum Band: Hashable, Sendable {
        case ghz2, ghz5, ghz6
    }

    public struct WiFi: Hashable, Sendable {
        /// dBm, e.g. -52.
        public let rssi: Int
        public let noise: Int
        /// Mb/s the link runs at now.
        public let transmitRate: Double
        public let channel: Int?
        public let band: Band?

        public init(rssi: Int, noise: Int, transmitRate: Double, channel: Int?, band: Band?) {
            self.rssi = rssi
            self.noise = noise
            self.transmitRate = transmitRate
            self.channel = channel
            self.band = band
        }
    }

    /// "en0".
    public let interface: String
    /// "Wi-Fi", "Ethernet Adapter (en3)", "iPhone USB": the name System Settings uses.
    public let name: String
    public let localAddress: String?
    public let router: String?
    public let wifi: WiFi?

    public init(interface: String, name: String, localAddress: String?, router: String?, wifi: WiFi?) {
        self.interface = interface
        self.name = name
        self.localAddress = localAddress
        self.router = router
        self.wifi = wifi
    }

    public enum SignalQuality: Hashable, Sendable {
        case excellent, good, fair, weak
    }

    /// Pure: the usual reading of RSSI, with a poor signal-to-noise margin counting against it.
    public static func quality(rssi: Int, noise: Int) -> SignalQuality {
        let margin = noise < 0 ? rssi - noise : 40
        if rssi >= -55, margin >= 25 {
            return .excellent
        }
        if rssi >= -67, margin >= 20 {
            return .good
        }
        if rssi >= -75, margin >= 10 {
            return .fair
        }
        return .weak
    }
}

public protocol NetworkDetailsSource: Sendable {
    /// The primary connection now, or nil when there's none.
    func details() async -> NetworkDetails?
}
