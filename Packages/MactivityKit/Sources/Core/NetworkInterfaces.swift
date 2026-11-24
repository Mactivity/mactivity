import Foundation

/// Every network interface on the Mac, as `ifconfig` lists them, in plain words (1.9, D-264).
public struct NetworkInterfaceInfo: Hashable, Sendable, Identifiable {
    /// What kind of connection it is.
    public enum Kind: String, Hashable, Sendable {
        case wifi, ethernet, thunderbolt, bridge, loopback, tunnel, airDrop, lowLatency, wifiAware, accessPoint, privateLink,
             virtualMachine, other

        /// Pure: from the name macOS gives it, and whether SystemConfiguration calls it Wi-Fi.
        /// "en" alone says nothing about the hardware, so its display name decides.
        public static func of(name: String, displayName: String?, isWiFi: Bool) -> Kind {
            if isWiFi {
                return .wifi
            }
            let prefixes: [(String, Kind)] = [
                ("lo", .loopback), ("utun", .tunnel), ("ipsec", .tunnel), ("ppp", .tunnel), ("tun", .tunnel), ("tap", .tunnel),
                ("gif", .tunnel), ("stf", .tunnel), ("awdl", .airDrop), ("llw", .lowLatency), ("nan", .wifiAware),
                ("ap", .accessPoint), ("anpi", .privateLink), ("vmenet", .virtualMachine), ("vmnet", .virtualMachine),
                ("bridge", .bridge),
            ]
            let letters = name.prefix { !$0.isNumber }
            if let kind = prefixes.first(where: { $0.0 == letters })?.1 {
                return kind
            }
            guard letters == "en" else {
                return .other
            }
            return displayName?.localizedCaseInsensitiveContains("Thunderbolt") == true ? .thunderbolt : .ethernet
        }
    }

    public enum Status: Int, Hashable, Sendable, Comparable {
        case connected, notConnected, off

        /// Pure: whether it's working. `RUNNING` alone only says the driver is loaded: on a Mac
        /// with nothing plugged in, Ethernet ports are `RUNNING` and `status: inactive`. So the
        /// link's own report decides; an interface with none (a tunnel, loopback) needs an address.
        public static func of(isUp: Bool, isRunning: Bool, linkActive: Bool?, hasAddress: Bool) -> Status {
            guard isUp else {
                return .off
            }
            if let linkActive {
                return linkActive ? .connected : .notConnected
            }
            return isRunning && hasAddress ? .connected : .notConnected
        }

        public static func < (lhs: Status, rhs: Status) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// An address on the interface.
    public struct Address: Hashable, Sendable, Identifiable {
        public let family: NetworkAddressFamily
        /// Without a "%en0" zone.
        public let value: String
        /// IPv4 only: "255.255.255.0".
        public let netmask: String?
        /// 24 from 255.255.255.0, 64 from an IPv6 mask.
        public let prefixLength: Int?
        public let broadcast: String?
        /// A tunnel's other end.
        public let peer: String?

        public var reach: NetworkAddressReach {
            NetworkAddressReach.of(value, family: family)
        }

        public var id: String {
            value
        }

        public init(family: NetworkAddressFamily, value: String, netmask: String?, prefixLength: Int?, broadcast: String?, peer: String?) {
            self.family = family
            self.value = value
            self.netmask = netmask
            self.prefixLength = prefixLength
            self.broadcast = broadcast
            self.peer = peer
        }
    }

    /// Counted since the Mac started, or since the interface appeared.
    public struct Counters: Hashable, Sendable {
        public let bytesIn: UInt64
        public let bytesOut: UInt64
        public let packetsIn: UInt64
        public let packetsOut: UInt64
        public let errorsIn: UInt64
        public let errorsOut: UInt64
        public let dropsIn: UInt64
        public let collisions: UInt64

        public init(
            bytesIn: UInt64, bytesOut: UInt64, packetsIn: UInt64, packetsOut: UInt64, errorsIn: UInt64, errorsOut: UInt64,
            dropsIn: UInt64, collisions: UInt64
        ) {
            self.bytesIn = bytesIn
            self.bytesOut = bytesOut
            self.packetsIn = packetsIn
            self.packetsOut = packetsOut
            self.errorsIn = errorsIn
            self.errorsOut = errorsOut
            self.dropsIn = dropsIn
            self.collisions = collisions
        }
    }

    /// `ifconfig`'s flags, each with its own plain words in the UI.
    public enum Flag: String, CaseIterable, Hashable, Sendable {
        case up = "UP", broadcast = "BROADCAST", loopback = "LOOPBACK", pointToPoint = "POINTOPOINT", smart = "SMART",
             running = "RUNNING", noARP = "NOARP", promiscuous = "PROMISC", simplex = "SIMPLEX", multicast = "MULTICAST"

        /// Its bit in `ifa_flags` (`net/if.h`).
        public var bit: UInt32 {
            switch self {
            case .up: 0x1
            case .broadcast: 0x2
            case .loopback: 0x8
            case .pointToPoint: 0x10
            case .smart: 0x20
            case .running: 0x40
            case .noARP: 0x80
            case .promiscuous: 0x100
            case .simplex: 0x800
            case .multicast: 0x8000
            }
        }

        public static func from(_ bits: UInt32) -> [Flag] {
            allCases.filter { bits & $0.bit != 0 }
        }
    }

    /// How the Mac got its address.
    public enum AddressSource: Hashable, Sendable {
        case dhcp, manual, other(String)

        /// Pure: from SystemConfiguration's `ConfigMethod`.
        public static func of(_ method: String?) -> AddressSource? {
            switch method {
            case nil: nil
            case "DHCP"?, "BOOTP"?: .dhcp
            case "Manual"?, "INFORM"?: .manual
            case let other?: .other(other)
            }
        }
    }

    /// "en0".
    public let name: String
    /// "Wi-Fi", "Thunderbolt 1": System Settings' name, when it has one.
    public let displayName: String?
    public let kind: Kind
    public let status: Status
    /// The one the Mac's traffic uses now.
    public let isPrimary: Bool
    public let flags: [Flag]
    /// Largest packet, in bytes.
    public let mtu: Int?
    public let macAddress: String?
    /// "1000baseT", "autoselect": what `ifconfig` calls media.
    public let media: String?
    public let isFullDuplex: Bool?
    /// Bits per second.
    public let linkSpeed: UInt64?
    public let addresses: [Address]
    public let router: String?
    public let dnsServers: [String]
    public let searchDomains: [String]
    public let addressSource: AddressSource?
    public let dhcpServer: String?
    public let leaseEnds: Date?
    /// A bridge's members: "en1", "en2".
    public let members: [String]
    public let counters: Counters?

    public var id: String {
        name
    }

    public init(
        name: String, displayName: String?, kind: Kind, status: Status, isPrimary: Bool = false, flags: [Flag] = [], mtu: Int? = nil,
        macAddress: String? = nil, media: String? = nil, isFullDuplex: Bool? = nil, linkSpeed: UInt64? = nil, addresses: [Address] = [],
        router: String? = nil, dnsServers: [String] = [], searchDomains: [String] = [], addressSource: AddressSource? = nil,
        dhcpServer: String? = nil, leaseEnds: Date? = nil, members: [String] = [], counters: Counters? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.kind = kind
        self.status = status
        self.isPrimary = isPrimary
        self.flags = flags
        self.mtu = mtu
        self.macAddress = macAddress
        self.media = media
        self.isFullDuplex = isFullDuplex
        self.linkSpeed = linkSpeed
        self.addresses = addresses
        self.router = router
        self.dnsServers = dnsServers
        self.searchDomains = searchDomains
        self.addressSource = addressSource
        self.dhcpServer = dhcpServer
        self.leaseEnds = leaseEnds
        self.members = members
        self.counters = counters
    }

    /// The address to show on its row: IPv4 first, then one that reaches beyond the link.
    public var mainAddress: Address? {
        addresses.first { $0.family == .ipv4 } ?? addresses.first { $0.reach == .internet || $0.reach == .privateNetwork } ?? addresses
            .first
    }

    /// The addresses to read down: IPv4 first, then the ones that reach furthest. The kernel lists
    /// IPv6's link-local one first, which is the one people need least.
    public var orderedAddresses: [Address] {
        func rank(_ address: Address) -> (Int, Int) {
            let reach = switch address.reach {
            case .internet: 0
            case .privateNetwork: 1
            case .localLink: 2
            case .thisMac: 3
            }
            return (address.family == .ipv4 ? 0 : 1, reach)
        }
        return addresses.enumerated()
            .sorted { first, second in
                let lhs = rank(first.element)
                let rhs = rank(second.element)
                return (lhs.0, lhs.1, first.offset) < (rhs.0, rhs.1, second.offset)
            }
            .map(\.element)
    }

    /// Pure: the order to list them in. The connection in use, then working hardware, then
    /// macOS's own (AirDrop, tunnels), then the rest, each by name with en2 before en10.
    public static func sorted(_ interfaces: [NetworkInterfaceInfo]) -> [NetworkInterfaceInfo] {
        interfaces.sorted { first, second in
            let lhs = (first.isPrimary ? 0 : 1, first.status, first.isHardware ? 0 : 1)
            let rhs = (second.isPrimary ? 0 : 1, second.status, second.isHardware ? 0 : 1)
            if lhs != rhs {
                return lhs < rhs
            }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    /// A connection someone chose: Wi-Fi or a port, not one of macOS's own.
    public var isHardware: Bool {
        [.wifi, .ethernet, .thunderbolt, .bridge].contains(kind)
    }
}

public enum NetworkAddressFamily: Hashable, Sendable {
    case ipv4, ipv6
}

/// How far an address reaches.
public enum NetworkAddressReach: Hashable, Sendable {
    case internet, privateNetwork, localLink, thisMac

    /// Pure: from the address's first digits. A home network's 192.168.x.x reaches the
    /// internet only through the router, so it reads as private.
    public static func of(_ value: String, family: NetworkAddressFamily) -> NetworkAddressReach {
        let text = value.lowercased()
        switch family {
        case .ipv4:
            let parts = text.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else {
                return .internet
            }
            if parts[0] == 127 {
                return .thisMac
            }
            if parts[0] == 169, parts[1] == 254 {
                return .localLink
            }
            let isPrivate = parts[0] == 10 || (parts[0] == 172 && (16 ... 31).contains(parts[1]))
                || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 100 && (64 ... 127).contains(parts[1]))
            return isPrivate ? .privateNetwork : .internet
        case .ipv6:
            if text == "::1" {
                return .thisMac
            }
            if text.hasPrefix("fe8") || text.hasPrefix("fe9") || text.hasPrefix("fea") || text.hasPrefix("feb") {
                return .localLink
            }
            return text.hasPrefix("fc") || text.hasPrefix("fd") ? .privateNetwork : .internet
        }
    }
}

public protocol NetworkInterfacesSource: Sendable {
    /// Every interface now. Read only while the list shows.
    func interfaces() async -> [NetworkInterfaceInfo]
}
