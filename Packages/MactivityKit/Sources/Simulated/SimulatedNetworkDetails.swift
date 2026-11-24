import Core
import Foundation

/// A Wi-Fi connection with a good signal (D-149), for previews, tests and simulated data.
public struct SimulatedNetworkDetails: NetworkDetailsSource {
    public init() {}

    public func details() async -> NetworkDetails? {
        NetworkDetails(
            interface: "en0", name: "Wi-Fi", localAddress: "192.168.1.24", router: "192.168.1.1",
            wifi: NetworkDetails.WiFi(rssi: -58, noise: -94, transmitRate: 866, channel: 149, band: .ghz5)
        )
    }
}
