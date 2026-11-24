import Core
import Foundation

extension NetworkInterfaceText {
    /// One titled group of facts.
    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let rows: [Row]
    }

    /// The facts as columns, left to right (1.9.1). Three in a normal window, with Traffic under
    /// Connection so they come out about the same height; two or one as the window narrows.
    /// Empty groups and columns are left out.
    static func columns(_ item: NetworkInterfaceInfo, count: Int = 3) -> [[Section]] {
        let addresses = Section(
            id: "addresses", title: String(
                localized: "Addresses",
                bundle: .strings,
                comment: "Network interface: its status and IP addresses"
            ),
            rows: statusRows(item) + addressRows(item)
        )
        let network = Section(id: "network", title: String(localized: "Network", bundle: .strings), rows: routingRows(item))
        let connection = Section(
            id: "connection", title: String(localized: "Connection", bundle: .strings, comment: "Network interface: its hardware and link"),
            rows: linkRows(item)
        )
        let traffic = Section(
            id: "traffic", title: String(localized: "Traffic", bundle: .strings, comment: "Network interface: data sent and received"),
            rows: counterRows(item)
        )
        let layout: [[Section]] = switch count {
        case 3: [[addresses], [network], [connection, traffic]]
        case 2: [[addresses, connection], [network, traffic]]
        default: [[addresses, network, connection, traffic]]
        }
        return layout.map { $0.filter { !$0.rows.isEmpty } }.filter { !$0.isEmpty }
    }

    /// The long sentence of abilities, which gets the card's full width under the columns.
    static func abilities(_ item: NetworkInterfaceInfo) -> Row? {
        flagRows(item).first
    }

    /// Every fact, in reading order.
    static func rows(_ item: NetworkInterfaceInfo) -> [Row] {
        columns(item, count: 1).flatMap { $0.flatMap(\.rows) } + flagRows(item)
    }

    private static func statusRows(_ item: NetworkInterfaceInfo) -> [Row] {
        var rows = [Row(
            id: "status", label: String(localized: "Status", bundle: .strings), value: status(item.status),
            note: item.isPrimary ? String(localized: "Your Mac's traffic uses this one", bundle: .strings) : nil,
            help: String(
                localized: "Whether this connection has a working link. It's what ifconfig calls active or inactive.",
                bundle: .strings
            )
        )]
        if !item.members.isEmpty {
            rows.append(Row(
                id: "members", label: String(localized: "Joins", bundle: .strings, comment: "A network bridge's member ports"),
                value: item.members.joined(separator: ", "),
                help: String(localized: "The ports this bridge connects together.", bundle: .strings), isCode: true
            ))
        }
        return rows
    }

    private static func addressRows(_ item: NetworkInterfaceInfo) -> [Row] {
        item.orderedAddresses.flatMap { address -> [Row] in
            let isIPv4 = address.family == .ipv4
            var rows = [Row(
                id: "address-\(address.value)",
                label: isIPv4 ? String(localized: "IPv4 address", bundle: .strings) : String(localized: "IPv6 address", bundle: .strings),
                value: address.value, note: reach(address.reach),
                help: isIPv4
                    ? String(localized: "This Mac's address on this connection, the older, shorter kind.", bundle: .strings)
                    : String(localized: "This Mac's address on this connection, the newer, longer kind.", bundle: .strings),
                isCode: true
            )]
            if let mask = address.netmask {
                rows.append(Row(
                    id: "mask-\(address.value)", label: String(localized: "Subnet mask", bundle: .strings), value: mask,
                    note: address.prefixLength.map { "/\($0)" },
                    help: String(
                        localized: "Which addresses count as your local network. Anything else goes through the router.",
                        bundle: .strings
                    ),
                    isCode: true
                ))
            }
            if let broadcast = address.broadcast {
                rows.append(Row(
                    id: "broadcast-\(address.value)", label: String(
                        localized: "Broadcast",
                        bundle: .strings,
                        comment: "Network broadcast address"
                    ),
                    value: broadcast, help: String(localized: "Sending here reaches every device on your local network.", bundle: .strings),
                    isCode: true
                ))
            }
            if let peer = address.peer, peer != address.value {
                rows.append(Row(
                    id: "peer-\(address.value)", label: String(
                        localized: "Other end",
                        bundle: .strings,
                        comment: "A tunnel's remote address"
                    ),
                    value: peer, help: String(localized: "The address at the far end of this link.", bundle: .strings), isCode: true
                ))
            }
            return rows
        }
    }

    private static func routingRows(_ item: NetworkInterfaceInfo) -> [Row] {
        var rows: [Row] = []
        if let router = item.router {
            rows.append(Row(
                id: "router", label: String(localized: "Router", bundle: .strings), value: router,
                help: String(localized: "Where traffic for the rest of the internet goes first.", bundle: .strings), isCode: true
            ))
        }
        if !item.dnsServers.isEmpty {
            rows.append(Row(
                id: "dns", label: String(localized: "DNS servers", bundle: .strings), value: item.dnsServers.joined(separator: ", "),
                help: String(localized: "What turns a name like apple.com into an address.", bundle: .strings), isCode: true
            ))
        }
        if !item.searchDomains.isEmpty {
            rows.append(Row(
                id: "search", label: String(localized: "Search domains", bundle: .strings),
                value: item.searchDomains.joined(separator: ", "),
                help: String(localized: "Added to short names, so \"printer\" can find printer.home.", bundle: .strings), isCode: true
            ))
        }
        if let source = item.addressSource {
            rows.append(Row(
                id: "source", label: String(localized: "Address from", bundle: .strings, comment: "How the Mac got its IP address"),
                value: addressSource(source),
                help: String(
                    localized: "DHCP means the network hands out an address automatically. That's the usual way.",
                    bundle: .strings
                )
            ))
        }
        if let server = item.dhcpServer {
            rows.append(Row(
                id: "dhcp", label: String(localized: "DHCP server", bundle: .strings), value: server,
                help: String(localized: "The device that gave this Mac its address, usually your router.", bundle: .strings), isCode: true
            ))
        }
        if let ends = item.leaseEnds {
            rows.append(Row(
                id: "lease", label: String(localized: "Address lease ends", bundle: .strings),
                value: ends.formatted(date: .abbreviated, time: .shortened),
                help: String(localized: "The address is on loan until then. Your Mac renews it well before, on its own.", bundle: .strings)
            ))
        }
        return rows
    }

    private static func addressSource(_ source: NetworkInterfaceInfo.AddressSource) -> String {
        switch source {
        case .dhcp: String(localized: "The network (DHCP)", bundle: .strings)
        case .manual: String(localized: "Set by hand", bundle: .strings, comment: "A manually configured IP address")
        case let .other(method): method
        }
    }

    private static func linkRows(_ item: NetworkInterfaceInfo) -> [Row] {
        var rows: [Row] = []
        if let mac = item.macAddress {
            rows.append(Row(
                id: "mac", label: String(localized: "Hardware address", bundle: .strings), value: mac,
                help: String(
                    localized: "This connection's ID on the local network, also called a MAC address. It never leaves your network.",
                    bundle: .strings
                ),
                isCode: true
            ))
        }
        if item.status == .connected, item.isHardware, let speed = item.linkSpeed {
            rows.append(Row(
                id: "speed", label: String(localized: "Link speed", bundle: .strings), value: Self.speed(speed),
                help: String(
                    localized: "How fast this Mac and the next device can talk, in bits. Your internet plan may be slower.",
                    bundle: .strings
                )
            ))
        }
        if let media = item.media {
            let duplex = item.isFullDuplex == true ? String(
                localized: "Sends and receives at once",
                bundle: .strings,
                comment: "Full duplex"
            ) : nil
            rows.append(Row(
                id: "media", label: String(localized: "Connection type", bundle: .strings, comment: "ifconfig's media"), value: media,
                note: duplex,
                help: String(
                    localized: "The standard the link runs at. Autoselect means it agrees on the best one with the other end.",
                    bundle: .strings
                ),
                isCode: true
            ))
        }
        if let mtu = item.mtu {
            let bytes = mtu.formatted()
            rows.append(Row(
                id: "mtu", label: String(localized: "Largest packet", bundle: .strings, comment: "A network interface's MTU"),
                value: String(localized: "\(bytes) bytes", bundle: .strings, comment: "A size in bytes"),
                help: String(localized: "The most data sent in one piece, called the MTU. Larger messages are split up.", bundle: .strings)
            ))
        }
        return rows
    }

    private static func counterRows(_ item: NetworkInterfaceInfo) -> [Row] {
        guard let counters = item.counters else {
            return []
        }
        func traffic(_ bytes: UInt64, _ packets: UInt64) -> (String, String) {
            let count = packets.formatted()
            let text = packets == 1
                ? String(localized: "1 packet", bundle: .strings, comment: "A count of network packets")
                : String(localized: "\(count) packets", bundle: .strings, comment: "A count of network packets")
            return (Formatters.bytes(bytes), text)
        }
        let received = traffic(counters.bytesIn, counters.packetsIn)
        let sent = traffic(counters.bytesOut, counters.packetsOut)
        let errorsIn = counters.errorsIn.formatted()
        let errorsOut = counters.errorsOut.formatted()
        return [
            Row(
                id: "received", label: String(localized: "Data received", bundle: .strings, comment: "Network traffic received"),
                value: received.0, note: received.1,
                help: String(localized: "Downloaded over this connection since your Mac started, in bytes.", bundle: .strings)
            ),
            Row(
                id: "sent", label: String(localized: "Data sent", bundle: .strings, comment: "Network traffic sent"), value: sent.0,
                note: sent.1,
                help: String(localized: "Uploaded over this connection since your Mac started, in bytes.", bundle: .strings)
            ),
            Row(
                id: "errors", label: String(localized: "Errors", bundle: .strings, comment: "Network packet errors"),
                value: String(
                    localized: "\(errorsIn) received, \(errorsOut) sent",
                    bundle: .strings,
                    comment: "Network packet errors, each way"
                ),
                help: String(
                    localized: """
                    Packets that arrived damaged or couldn't be sent. A few are normal; a fast-growing count points to a \
                    bad link.
                    """,
                    bundle: .strings
                )
            ),
            Row(
                id: "drops", label: String(localized: "Dropped", bundle: .strings, comment: "Network packets dropped"),
                value: counters.dropsIn.formatted(),
                help: String(localized: "Packets that arrived while the Mac was too busy to take them.", bundle: .strings)
            ),
            Row(
                id: "collisions", label: String(localized: "Collisions", bundle: .strings, comment: "Network packet collisions"),
                value: counters.collisions.formatted(),
                help: String(localized: "Two devices talking over each other. Modern links almost never have these.", bundle: .strings)
            ),
        ]
    }

    private static func flagRows(_ item: NetworkInterfaceInfo) -> [Row] {
        guard !item.flags.isEmpty else {
            return []
        }
        return [Row(
            id: "flags", label: String(localized: "Abilities", bundle: .strings, comment: "A network interface's flags, in plain words"),
            value: item.flags.map(flag).joined(separator: " · "),
            help: item.flags.map(\.rawValue).joined(separator: ", ")
        )]
    }
}
