import Core
import Foundation

/// The list on a made-up Mac (D-264): Wi-Fi in use, a VPN's tunnel, and ports with nothing in them.
public struct SimulatedNetworkInterfaces: NetworkInterfacesSource {
    public init() {}

    private static let up: [NetworkInterfaceInfo.Flag] = [.up, .broadcast, .smart, .running, .simplex, .multicast]

    public func interfaces() async -> [NetworkInterfaceInfo] {
        NetworkInterfaceInfo.sorted(Self.wifi + Self.ports + Self.macOSOwn)
    }

    private static let wifi = [
        NetworkInterfaceInfo(
            name: "en0", displayName: "Wi-Fi", kind: .wifi, status: .connected, isPrimary: true, flags: up, mtu: 1500,
            macAddress: "a4:83:e7:00:00:10", linkSpeed: 866_000_000,
            addresses: [
                .init(
                    family: .ipv4,
                    value: "192.168.1.24",
                    netmask: "255.255.255.0",
                    prefixLength: 24,
                    broadcast: "192.168.1.255",
                    peer: nil
                ),
                .init(family: .ipv6, value: "fe80::1c8f:0:0:10", netmask: nil, prefixLength: 64, broadcast: nil, peer: nil),
                .init(family: .ipv6, value: "2001:db8:a180:42::1b", netmask: nil, prefixLength: 64, broadcast: nil, peer: nil),
            ],
            router: "192.168.1.1", dnsServers: ["192.168.1.1", "2001:db8:a180:42::1"], searchDomains: ["home"], addressSource: .dhcp,
            dhcpServer: "192.168.1.1", leaseEnds: Date(timeIntervalSinceNow: 14 * 3600),
            counters: .init(
                bytesIn: 48_210_000_000, bytesOut: 6_940_000_000, packetsIn: 41_200_000, packetsOut: 12_800_000, errorsIn: 0,
                errorsOut: 3,
                dropsIn: 12, collisions: 0
            )
        ),
    ]

    private static let ports = [
        NetworkInterfaceInfo(
            name: "en1", displayName: "Thunderbolt 1", kind: .thunderbolt, status: .notConnected,
            flags: up + [.promiscuous], mtu: 1500, macAddress: "36:00:00:00:e2:01", media: "autoselect", isFullDuplex: true
        ),
        NetworkInterfaceInfo(
            name: "en3", displayName: "Ethernet Adapter (en3)", kind: .ethernet, status: .notConnected, flags: up, mtu: 1500,
            macAddress: "36:00:00:00:e2:44"
        ),
        NetworkInterfaceInfo(
            name: "bridge0", displayName: "Thunderbolt Bridge", kind: .bridge, status: .notConnected, flags: up, mtu: 1500,
            macAddress: "36:00:00:00:e2:00", members: ["en1"]
        ),
    ]

    private static let macOSOwn = [
        NetworkInterfaceInfo(
            name: "utun3", displayName: nil, kind: .tunnel, status: .connected,
            flags: [.up, .pointToPoint, .running, .multicast], mtu: 1380,
            addresses: [.init(
                family: .ipv4,
                value: "100.64.0.6",
                netmask: "255.255.255.255",
                prefixLength: 32,
                broadcast: nil,
                peer: "100.64.0.6"
            )],
            counters: .init(
                bytesIn: 182_000_000, bytesOut: 41_000_000, packetsIn: 201_000, packetsOut: 96000, errorsIn: 0, errorsOut: 0,
                dropsIn: 0,
                collisions: 0
            )
        ),
        NetworkInterfaceInfo(
            name: "awdl0", displayName: nil, kind: .airDrop, status: .connected, flags: up + [.promiscuous], mtu: 1500,
            macAddress: "de:00:00:00:7b:2c",
            addresses: [.init(
                family: .ipv6,
                value: "fe80::dc00:ff:fe00:7b2c",
                netmask: nil,
                prefixLength: 64,
                broadcast: nil,
                peer: nil
            )]
        ),
        NetworkInterfaceInfo(
            name: "lo0", displayName: nil, kind: .loopback, status: .connected, flags: [.up, .loopback, .running, .multicast],
            mtu: 16384,
            addresses: [
                .init(family: .ipv4, value: "127.0.0.1", netmask: "255.0.0.0", prefixLength: 8, broadcast: nil, peer: nil),
                .init(family: .ipv6, value: "::1", netmask: nil, prefixLength: 128, broadcast: nil, peer: nil),
            ],
            counters: .init(
                bytesIn: 3_100_000_000, bytesOut: 3_100_000_000, packetsIn: 2_400_000, packetsOut: 2_400_000, errorsIn: 0, errorsOut: 0,
                dropsIn: 0, collisions: 0
            )
        ),
    ]
}
