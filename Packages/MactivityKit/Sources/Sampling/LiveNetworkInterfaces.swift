import Core
import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// What `ifconfig` shows, read directly (D-264), all public API: `getifaddrs` for flags and
/// addresses, the routing sysctl for 64-bit counters, the `SIOCGIFMEDIA` ioctl for the link,
/// SystemConfiguration for names, routers, DNS and DHCP. No command runs and nothing is sent.
public struct LiveNetworkInterfaces: NetworkInterfacesSource {
    public init() {}

    public func interfaces() async -> [NetworkInterfaceInfo] {
        let parts = Self.addressesAndFlags()
        guard !parts.isEmpty else {
            return []
        }
        let names = Self.systemNames()
        let services = Self.services()
        let links = Self.linkData()
        let wifi = CWWiFiClient.shared().interface()
        let primary = services.primary
        return NetworkInterfaceInfo.sorted(parts.map { name, part in
            let isWiFi = names[name]?.isWiFi == true
            let media = Self.media(name)
            let service = services.byInterface[name]
            let link = links[name]
            // A joined Wi-Fi's rate is CoreWLAN's; the kernel's figure for it stays at a fixed value.
            let wifiRate = isWiFi && wifi?.interfaceName == name ? wifi?.transmitRate() : nil
            return NetworkInterfaceInfo(
                name: name, displayName: names[name]?.title,
                kind: .of(name: name, displayName: names[name]?.title, isWiFi: isWiFi),
                status: .of(
                    isUp: part.flags & NetworkInterfaceInfo.Flag.up.bit != 0,
                    isRunning: part.flags & NetworkInterfaceInfo.Flag.running.bit != 0,
                    linkActive: media?.isActive, hasAddress: !part.addresses.isEmpty
                ),
                isPrimary: name == primary, flags: NetworkInterfaceInfo.Flag.from(part.flags), mtu: link?.mtu, macAddress: part.mac,
                media: media?.name, isFullDuplex: media?.isFullDuplex,
                linkSpeed: wifiRate.flatMap { $0 > 0 ? UInt64($0 * 1_000_000) : nil } ?? (isWiFi ? nil : link?.speed),
                addresses: part.addresses, router: service?.router, dnsServers: service?.dns ?? [],
                searchDomains: service?.searchDomains ?? [],
                addressSource: .of(service?.configMethod), dhcpServer: service?.dhcpServer, leaseEnds: service?.leaseEnds,
                members: names[name]?.members ?? [], counters: link?.counters
            )
        })
    }

    // MARK: getifaddrs

    struct Part {
        var flags: UInt32 = 0
        var mac: String?
        var addresses: [NetworkInterfaceInfo.Address] = []
    }

    static func addressesAndFlags() -> [String: Part] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else {
            return [:]
        }
        defer { freeifaddrs(list) }
        var parts: [String: Part] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            let name = String(cString: item.ifa_name)
            parts[name, default: Part()].flags = item.ifa_flags
            guard let socket = item.ifa_addr else {
                continue
            }
            switch Int32(socket.pointee.sa_family) {
            case AF_LINK:
                parts[name, default: Part()].mac = mac(socket)
            case AF_INET, AF_INET6:
                if let address = address(item, socket) {
                    parts[name, default: Part()].addresses.append(address)
                }
            default:
                break
            }
        }
        return parts
    }

    private static func address(_ item: ifaddrs, _ socket: UnsafeMutablePointer<sockaddr>) -> NetworkInterfaceInfo.Address? {
        guard let text = numeric(socket) else {
            return nil
        }
        let isIPv4 = Int32(socket.pointee.sa_family) == AF_INET
        let isPointToPoint = item.ifa_flags & NetworkInterfaceInfo.Flag.pointToPoint.bit != 0
        let other = item.ifa_dstaddr.flatMap(numeric)
        return NetworkInterfaceInfo.Address(
            family: isIPv4 ? .ipv4 : .ipv6, value: text,
            netmask: isIPv4 ? item.ifa_netmask.flatMap(numeric) : nil,
            prefixLength: item.ifa_netmask.map { prefixLength($0) },
            broadcast: isIPv4 && !isPointToPoint ? other : nil,
            peer: isPointToPoint ? other : nil
        )
    }

    /// The address as text, without a "%en0" zone.
    private static func numeric(_ socket: UnsafeMutablePointer<sockaddr>) -> String? {
        guard Int32(socket.pointee.sa_family) == AF_INET || Int32(socket.pointee.sa_family) == AF_INET6, socket.pointee.sa_len > 0 else {
            return nil
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        let text = String(bytes: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
        return text?.split(separator: "%").first.map(String.init)
    }

    /// The mask's set bits. A kernel mask can be shorter than its family's address, so this
    /// counts what `sa_len` says is there: a mask of 0.0.0.0 has no bytes at all.
    private static func prefixLength(_ mask: UnsafeMutablePointer<sockaddr>) -> Int {
        let isIPv4 = Int32(mask.pointee.sa_family) == AF_INET || mask.pointee.sa_family == 0 && mask.pointee.sa_len <= 8
        let offset = isIPv4 ? 4 : 8
        let length = Int(mask.pointee.sa_len)
        guard length > offset else {
            return 0
        }
        let bytes = UnsafeRawBufferPointer(start: mask, count: length).dropFirst(offset).prefix(isIPv4 ? 4 : 16)
        return bytes.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    private static func mac(_ socket: UnsafeMutablePointer<sockaddr>) -> String? {
        socket.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link -> String? in
            let length = Int(link.pointee.sdl_alen)
            guard length == 6 else {
                return nil
            }
            let start = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data).map { $0 + Int(link.pointee.sdl_nlen) } ?? 0
            let bytes = UnsafeRawBufferPointer(start: link, count: Int(link.pointee.sdl_len))
            guard start + length <= bytes.count else {
                return nil
            }
            return bytes[start ..< start + length].map { String(format: "%02x", $0) }.joined(separator: ":")
        }
    }

    // MARK: The link

    struct Media {
        let name: String?
        let isActive: Bool?
        let isFullDuplex: Bool?
    }

    /// `_IOWR('i', 56, struct ifmediareq)` from `sys/sockio.h`, a macro Swift doesn't import.
    static let getMedia = UInt(0xC000_0000) | (UInt(MemoryLayout<ifmediareq>.size & 0x1FFF) << 16) | (UInt(UInt8(ascii: "i")) << 8) | 56

    static func media(_ name: String) -> Media? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }
        var request = ifmediareq()
        withUnsafeMutableBytes(of: &request.ifm_name) { buffer in
            _ = name.utf8CString.prefix(buffer.count - 1).withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        guard ioctl(descriptor, getMedia, &request) == 0 else {
            return nil
        }
        return mediaFrom(current: request.ifm_current, active: request.ifm_active, status: request.ifm_status)
    }

    /// Pure: `net/if_media.h`'s words as what they mean.
    static func mediaFrom(current: Int32, active: Int32, status: Int32) -> Media {
        let valid = status & 0x1 != 0 // IFM_AVALID
        let word = valid && active != 0 ? active : current
        let isEthernet = word & 0xE0 == 0x20 // IFM_ETHER
        let name: String? = isEthernet ? ethernetMedia[Int(word & 0x1F)] : nil
        return Media(
            name: name,
            isActive: valid ? status & 0x2 != 0 : nil, // IFM_ACTIVE
            isFullDuplex: word & 0x0010_0000 != 0 ? true : nil // IFM_FDX
        )
    }

    /// `IFM_` Ethernet subtypes. 2 is "none", which says nothing, so it isn't here.
    static let ethernetMedia: [Int: String] = [
        0: "autoselect", 3: "10baseT", 6: "100baseTX", 11: "1000baseSX", 16: "1000baseT", 18: "10GbaseSR", 21: "10GbaseT", 22: "2500baseT",
        23: "5000baseT",
    ]

    /// MTU, speed and 64-bit counters, from `NET_RT_IFLIST2`: `getifaddrs`'s wrap at 4 GB.
    struct Link {
        let mtu: Int
        let speed: UInt64?
        let counters: NetworkInterfaceInfo.Counters
    }

    static func linkData() -> [String: Link] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
            return [:]
        }
        // Room for an interface or two appearing between the two calls.
        size += size / 4 + 1024
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else {
            return [:]
        }
        return buffer.withUnsafeBytes { parseLinks(UnsafeRawBufferPointer(rebasing: $0.prefix(size))) }
    }

    private static func parseLinks(_ raw: UnsafeRawBufferPointer) -> [String: Link] {
        var links: [String: Link] = [:]
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= raw.count {
            let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            let length = Int(header.ifm_msglen)
            guard length > 0, offset + length <= raw.count else {
                break
            }
            if Int32(header.ifm_type) == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                    let data = message.ifm_data
                    let text = String(bytes: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
                    links[text] = Link(
                        mtu: Int(data.ifi_mtu), speed: data.ifi_baudrate > 0 ? data.ifi_baudrate : nil,
                        counters: .init(
                            bytesIn: data.ifi_ibytes, bytesOut: data.ifi_obytes, packetsIn: data.ifi_ipackets,
                            packetsOut: data.ifi_opackets,
                            errorsIn: data.ifi_ierrors, errorsOut: data.ifi_oerrors, dropsIn: data.ifi_iqdrops,
                            collisions: data.ifi_collisions
                        )
                    )
                }
            }
            offset += length
        }
        return links
    }

    // MARK: SystemConfiguration

    struct SystemName {
        let title: String?
        let isWiFi: Bool
        var members: [String] = []
    }

    private static func systemNames() -> [String: SystemName] {
        var names: [String: SystemName] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else {
                continue
            }
            names[name] = SystemName(
                title: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?,
                isWiFi: SCNetworkInterfaceGetInterfaceType(interface) == kSCNetworkInterfaceTypeIEEE80211
            )
        }
        if let preferences = SCPreferencesCreate(nil, "app.mactivity.network" as CFString, nil),
           let virtual = SCPreferencesGetValue(preferences, "VirtualNetworkInterfaces" as CFString) as? [String: Any] {
            for (name, members) in bridgeMembers(virtual) {
                names[name, default: SystemName(title: nil, isWiFi: false)].members = members
            }
        }
        return names
    }

    /// Pure: SystemConfiguration's `VirtualNetworkInterfaces` as each bridge's members.
    static func bridgeMembers(_ virtual: [String: Any]) -> [String: [String]] {
        let bridges = virtual["Bridge"] as? [String: [String: Any]] ?? [:]
        return bridges.compactMapValues { $0["Interfaces"] as? [String] }
    }

    /// Pure: a service's DHCP entry as the server that answered and when the lease ends. Option
    /// 54 is the server's address, 51 the lease's length in seconds, both big-endian.
    static func lease(_ entry: [String: Any]) -> (server: String?, ends: Date?) {
        let server = (entry["Option_54"] as? Data).flatMap { $0.count == 4 ? $0.map(String.init).joined(separator: ".") : nil }
        var ends: Date?
        if let start = entry["LeaseStartTime"] as? Date, let length = entry["Option_51"] as? Data, length.count == 4 {
            let seconds = length.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            // All ones means the lease never ends.
            ends = seconds == .max ? nil : start.addingTimeInterval(TimeInterval(seconds))
        }
        return (server, ends)
    }

    struct Service {
        var router: String?
        var dns: [String] = []
        var searchDomains: [String] = []
        var configMethod: String?
        var dhcpServer: String?
        var leaseEnds: Date?
    }

    private static func services() -> (byInterface: [String: Service], primary: String?) {
        guard let store = SCDynamicStoreCreate(nil, "app.mactivity.network" as CFString, nil, nil) else {
            return ([:], nil)
        }
        let state = SCDynamicStoreCopyMultiple(
            store,
            nil,
            ["State:/Network/Service/.*/(IPv4|IPv6|DNS)" as CFString] as CFArray
        ) as? [String: Any] ?? [:]
        func value(_ key: String) -> [String: Any]? {
            SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        }
        var found: [String: Service] = [:]
        for (key, entry) in state where key.hasSuffix("/IPv4") || key.hasSuffix("/IPv6") {
            guard let entry = entry as? [String: Any], let interface = entry["InterfaceName"] as? String else {
                continue
            }
            let id = key.split(separator: "/")[3]
            var service = found[interface] ?? Service()
            // IPv4's router when there is one.
            if key.hasSuffix("/IPv4") || service.router == nil {
                service.router = entry["Router"] as? String ?? service.router
            }
            if let dns = state["State:/Network/Service/\(id)/DNS"] as? [String: Any] {
                service.dns = dns["ServerAddresses"] as? [String] ?? []
                service.searchDomains = dns["SearchDomains"] as? [String] ?? []
            }
            service.configMethod = value("Setup:/Network/Service/\(id)/IPv4")?["ConfigMethod"] as? String ?? service.configMethod
            if let entry = value("State:/Network/Service/\(id)/DHCP") {
                (service.dhcpServer, service.leaseEnds) = lease(entry)
            }
            found[interface] = service
        }
        let global = ["IPv4", "IPv6"].lazy.compactMap { value("State:/Network/Global/\($0)")?["PrimaryInterface"] as? String }.first
        // The Mac's own DNS when the service doesn't list any: often the case on a VPN.
        if let global, found[global, default: Service()].dns.isEmpty, let dns = value("State:/Network/Global/DNS") {
            found[global, default: Service()].dns = dns["ServerAddresses"] as? [String] ?? []
            found[global, default: Service()].searchDomains = dns["SearchDomains"] as? [String] ?? []
        }
        return (found, global)
    }
}
