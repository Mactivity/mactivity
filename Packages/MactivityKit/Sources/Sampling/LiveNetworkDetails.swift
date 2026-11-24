import Core
import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// The primary connection (D-149), all public API: SystemConfiguration's global IPv4 state for
/// the interface and router, `getifaddrs` for the address, CoreWLAN for Wi-Fi's signal, rate and
/// channel. No Location permission needed: the network's name, which would need it, isn't read.
/// Read only while the Network tab shows.
public struct LiveNetworkDetails: NetworkDetailsSource {
    public init() {}

    public func details() async -> NetworkDetails? {
        let store = SCDynamicStoreCreate(nil, "app.mactivity.network" as CFString, nil, nil)
        // IPv4's primary, else IPv6's: an IPv6-only network is still connected (D-221).
        let global = ["IPv4", "IPv6"].lazy
            .compactMap { SCDynamicStoreCopyValue(store, "State:/Network/Global/\($0)" as CFString) as? [String: Any] }
            .first { $0["PrimaryInterface"] is String }
        guard let global, let interface = global["PrimaryInterface"] as? String else {
            return nil
        }
        // A VPN's tunnel carries the traffic but has no name or signal of its own: name it, and
        // show the Wi-Fi underneath when that's what it runs over.
        let tunnel = Self.isTunnel(interface)
        return NetworkDetails(
            interface: interface, name: tunnel ? "VPN" : Self.displayName(interface) ?? interface,
            localAddress: Self.address(of: interface), router: global["Router"] as? String,
            wifi: tunnel ? Self.wifiUnderneath() : Self.wifi(interface)
        )
    }

    static func isTunnel(_ interface: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap"].contains { interface.hasPrefix($0) }
    }

    /// The Mac's Wi-Fi now, when it's on and joined to a network, whatever carries the traffic
    /// (a VPN over Wi-Fi too): for Wi-Fi over time (D-234). About 0.2 ms of processor.
    public static func currentWiFi() -> NetworkDetails.WiFi? {
        wifiUnderneath()
    }

    /// The Wi-Fi interface, when it's on and joined to a network (a signal reads 0 otherwise).
    static func wifiUnderneath() -> NetworkDetails.WiFi? {
        guard let name = CWWiFiClient.shared().interface()?.interfaceName, let wifi = wifi(name), wifi.rssi != 0 else {
            return nil
        }
        return wifi
    }

    static func displayName(_ interface: String) -> String? {
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        guard let match = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == interface }) else {
            return nil
        }
        return SCNetworkInterfaceGetLocalizedDisplayName(match) as String?
    }

    /// The interface's IPv4 address, else its first global IPv6 one (not link-local fe80::).
    static func address(of interface: String) -> String? {
        address(of: interface, family: AF_INET) ?? address(of: interface, family: AF_INET6)
    }

    private static func address(of interface: String, family: Int32) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else {
            return nil
        }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard let socket = item.ifa_addr, socket.pointee.sa_family == UInt8(family),
                  String(cString: item.ifa_name) == interface else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            )
            // The address up to its terminating zero (String(cString:) on an array is deprecated).
            let text = String(bytes: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
            if status == 0, !text.lowercased().hasPrefix("fe80") {
                return text
            }
        }
        return nil
    }

    static func wifi(_ interface: String) -> NetworkDetails.WiFi? {
        guard let wifi = CWWiFiClient.shared().interface(withName: interface), wifi.powerOn() else {
            return nil
        }
        let channel = wifi.wlanChannel()
        let band: NetworkDetails.Band? = switch channel?.channelBand {
        case .band2GHz: .ghz2
        case .band5GHz: .ghz5
        case .band6GHz: .ghz6
        default: nil
        }
        return NetworkDetails.WiFi(
            rssi: wifi.rssiValue(), noise: wifi.noiseMeasurement(), transmitRate: wifi.transmitRate(),
            channel: channel.map(\.channelNumber), band: band
        )
    }
}
