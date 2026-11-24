import Core
import Testing

@Suite("Network interfaces in plain words (D-264)")
struct NetworkInterfacesTests {
    typealias Info = NetworkInterfaceInfo

    @Test("Kinds, from the name and what System Settings calls it")
    func kinds() {
        #expect(Info.Kind.of(name: "en0", displayName: "Wi-Fi", isWiFi: true) == .wifi)
        #expect(Info.Kind.of(name: "en1", displayName: "Thunderbolt 1", isWiFi: false) == .thunderbolt)
        #expect(Info.Kind.of(name: "en3", displayName: "Ethernet Adapter (en3)", isWiFi: false) == .ethernet)
        #expect(Info.Kind.of(name: "bridge0", displayName: "Thunderbolt Bridge", isWiFi: false) == .bridge)
        let names: [(String, Info.Kind)] = [
            ("lo0", .loopback), ("utun3", .tunnel), ("gif0", .tunnel), ("stf0", .tunnel), ("awdl0", .airDrop), ("llw0", .lowLatency),
            ("nan0", .wifiAware), ("ap1", .accessPoint), ("anpi0", .privateLink), ("vmenet2", .virtualMachine), ("xyz0", .other),
        ]
        for (name, kind) in names {
            #expect(Info.Kind.of(name: name, displayName: nil, isWiFi: false) == kind)
        }
    }

    @Test("RUNNING with nothing plugged in isn't connected: the link's own report decides")
    func status() {
        #expect(Info.Status.of(isUp: true, isRunning: true, linkActive: false, hasAddress: false) == .notConnected)
        #expect(Info.Status.of(isUp: true, isRunning: true, linkActive: true, hasAddress: true) == .connected)
        #expect(Info.Status.of(isUp: true, isRunning: true, linkActive: nil, hasAddress: true) == .connected)
        #expect(Info.Status.of(isUp: true, isRunning: true, linkActive: nil, hasAddress: false) == .notConnected)
        #expect(Info.Status.of(isUp: false, isRunning: false, linkActive: true, hasAddress: true) == .off)
    }

    @Test("How far an address reaches")
    func reach() {
        let cases: [(String, NetworkAddressFamily, NetworkAddressReach)] = [
            ("192.168.1.24", .ipv4, .privateNetwork), ("10.0.0.4", .ipv4, .privateNetwork), ("172.16.0.1", .ipv4, .privateNetwork),
            ("172.32.0.1", .ipv4, .internet), ("100.64.0.6", .ipv4, .privateNetwork), ("8.8.8.8", .ipv4, .internet),
            ("127.0.0.1", .ipv4, .thisMac), ("169.254.3.4", .ipv4, .localLink), ("::1", .ipv6, .thisMac),
            ("fe80::1", .ipv6, .localLink), ("febf::1", .ipv6, .localLink), ("fd12::1", .ipv6, .privateNetwork),
            ("2601:600::1b", .ipv6, .internet),
        ]
        for (value, family, reach) in cases {
            #expect(NetworkAddressReach.of(value, family: family) == reach, "\(value)")
        }
    }

    @Test("Flags come from the bits ifconfig prints")
    func flags() {
        // lo0's flags=8049, en0's flags=8863, as ifconfig shows them.
        #expect(Info.Flag.from(0x8049) == [.up, .loopback, .running, .multicast])
        #expect(Info.Flag.from(0x8863) == [.up, .broadcast, .smart, .running, .simplex, .multicast])
        #expect(Info.Flag.from(0).isEmpty)
    }

    @Test("Where the address came from")
    func source() {
        #expect(Info.AddressSource.of("DHCP") == .dhcp)
        #expect(Info.AddressSource.of("Manual") == .manual)
        #expect(Info.AddressSource.of("Automatic") == .other("Automatic"))
        #expect(Info.AddressSource.of(nil) == nil)
    }

    @Test("The connection in use first, then working ports, macOS's own, then the rest; en2 before en10")
    func order() {
        let items = [
            Info(name: "en10", displayName: nil, kind: .ethernet, status: .notConnected),
            Info(name: "awdl0", displayName: nil, kind: .airDrop, status: .connected),
            Info(name: "en2", displayName: nil, kind: .ethernet, status: .notConnected),
            Info(name: "en5", displayName: nil, kind: .ethernet, status: .connected),
            Info(name: "utun3", displayName: nil, kind: .tunnel, status: .connected, isPrimary: true),
        ]
        #expect(Info.sorted(items).map(\.name) == ["utun3", "en5", "awdl0", "en2", "en10"])
    }

    @Test("Addresses read IPv4 first, then the ones that reach furthest, as found on a real Mac")
    func addressOrder() {
        func address(_ value: String, _ family: NetworkAddressFamily) -> Info.Address {
            Info.Address(family: family, value: value, netmask: nil, prefixLength: nil, broadcast: nil, peer: nil)
        }
        let item = Info(name: "en0", displayName: nil, kind: .wifi, status: .connected, addresses: [
            address("fe80::1", .ipv6), address("192.168.1.166", .ipv4), address("fd12::1", .ipv6), address("2601::1", .ipv6), address(
                "2601::2",
                .ipv6
            ),
        ])
        #expect(item.orderedAddresses.map(\.value) == ["192.168.1.166", "2601::1", "2601::2", "fd12::1", "fe80::1"])
    }

    @Test("The row's address: IPv4, else one that reaches past the link")
    func mainAddress() {
        func address(_ value: String, _ family: NetworkAddressFamily) -> Info.Address {
            Info.Address(family: family, value: value, netmask: nil, prefixLength: nil, broadcast: nil, peer: nil)
        }
        let local = address("fe80::1", .ipv6)
        let global = address("2601::1", .ipv6)
        let four = address("10.0.0.2", .ipv4)
        #expect(Info(name: "a", displayName: nil, kind: .wifi, status: .connected, addresses: [local, global, four]).mainAddress == four)
        #expect(Info(name: "a", displayName: nil, kind: .wifi, status: .connected, addresses: [local, global]).mainAddress == global)
        #expect(Info(name: "a", displayName: nil, kind: .wifi, status: .connected, addresses: [local]).mainAddress == local)
        #expect(Info(name: "a", displayName: nil, kind: .wifi, status: .connected).mainAddress == nil)
    }
}
