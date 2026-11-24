import Core
import Foundation

/// Network changes and Wi-Fi over time for previews and Simulated data (D-233, D-234): home
/// Wi-Fi with a weak spell in the evening, a VPN for a meeting, a hotspot on a train, a drop.
extension SimulatedHistoryStore: NetworkHistoryStore {
    public func recordNetworkChange(_: NetworkChange) async throws {}
    public func recordWiFi(_: WiFiReading) async throws {}

    public func networkChanges(from: Date, to: Date) async throws -> [NetworkChange] {
        let day: TimeInterval = 86400
        let start = Calendar.current.startOfDay(for: to)
        let changes = [
            NetworkChange(at: start - 2 * day + 8 * 3600, kind: .wifi, interface: "en0"),
            NetworkChange(at: start - day + 8 * 3600, kind: .hotspot, interface: "en0"),
            NetworkChange(at: start - day + 9 * 3600, kind: .wifi, interface: "en0"),
            NetworkChange(at: start + 10 * 3600, kind: .vpn, interface: "utun4"),
            NetworkChange(at: start + 11 * 3600, kind: .wifi, interface: "en0"),
            NetworkChange(at: start + 13 * 3600, kind: .offline, interface: nil),
            NetworkChange(at: start + 13 * 3600 + 240, kind: .wifi, interface: "en0"),
        ]
        let before = changes.last { $0.at < from }
        return (before.map { [$0] } ?? []) + changes.filter { $0.at >= from && $0.at < to }
    }

    public func wifiReadings(from: Date, to: Date) async throws -> [WiFiReading] {
        stride(from: max(from.timeIntervalSince1970, to.timeIntervalSince1970 - 7 * 86400), to: to.timeIntervalSince1970, by: 300)
            .map { t in
                let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: t))
                // Strong by day at the desk, weaker in the evening from the couch.
                let base = (18 ... 22).contains(hour) ? -73.0 : -54.0
                let wobble = 4 * sin(t / 1700)
                return WiFiReading(
                    at: Date(timeIntervalSince1970: t), rssi: Int(base + wobble), noise: -95, transmitRate: base > -60 ? 864 : 288,
                    channel: 117
                )
            }
    }
}
