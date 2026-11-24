import Core
import Foundation

/// `ifconfig`'s words, as plain ones (D-264): each interface's name, what it's for, and a row for
/// every fact, whose hover says what the fact means.
@MainActor
enum NetworkInterfaceText {
    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String
        var note: String?
        let help: String
        /// An address or name someone might copy: monospaced and selectable.
        var isCode = false
    }

    static func title(_ item: NetworkInterfaceInfo) -> String {
        if let name = item.displayName {
            return name
        }
        switch item.kind {
        case .wifi: return String(localized: "Wi-Fi", bundle: .strings)
        case .ethernet: return String(localized: "Ethernet", bundle: .strings)
        case .thunderbolt: return String(localized: "Thunderbolt", bundle: .strings)
        case .bridge: return String(localized: "Bridge", bundle: .strings, comment: "Network interface joining other ports")
        case .loopback: return String(localized: "This Mac", bundle: .strings, comment: "The loopback network interface")
        case .tunnel: return String(localized: "Tunnel", bundle: .strings, comment: "Network interface used by VPNs")
        case .airDrop: return String(localized: "AirDrop and AirPlay", bundle: .strings, comment: "The awdl network interface")
        case .lowLatency: return String(localized: "Low-latency Wi-Fi", bundle: .strings, comment: "The llw network interface")
        case .wifiAware: return String(
                localized: "Wi-Fi Aware",
                bundle: .strings,
                comment: "The nan network interface; Apple's feature name"
            )
        case .accessPoint: return String(localized: "Wi-Fi sharing", bundle: .strings, comment: "The ap network interface")
        case .privateLink: return String(localized: "Private link", bundle: .strings, comment: "The anpi network interface")
        case .virtualMachine: return String(
                localized: "Virtual machine",
                bundle: .strings,
                comment: "A virtual machine's network interface"
            )
        case .other: return String(localized: "Other", bundle: .strings, comment: "A network interface of another kind")
        }
    }

    /// What it's for, in a sentence.
    static func purpose(_ kind: NetworkInterfaceInfo.Kind) -> String {
        switch kind {
        case .wifi: String(localized: "This Mac's Wi-Fi.", bundle: .strings)
        case .ethernet: String(localized: "A wired connection, through an Ethernet port or adapter.", bundle: .strings)
        case .thunderbolt: String(localized: "A Thunderbolt port. It carries a network when it's cabled to another Mac.", bundle: .strings)
        case .bridge: String(
                localized: "Joins other ports into one network. Thunderbolt Bridge links Macs with a Thunderbolt cable.",
                bundle: .strings
            )
        case .loopback: String(
                localized: "This Mac talking to itself. Apps use it to reach servers running on the same Mac.",
                bundle: .strings
            )
        case .tunnel: String(
                localized: "Carries traffic wrapped inside another connection. VPNs use these, and so does macOS itself.",
                bundle: .strings
            )
        case .airDrop: String(
                localized: "How AirDrop, AirPlay and Handoff reach nearby Apple devices directly, without a network.",
                bundle: .strings
            )
        case .lowLatency: String(
                localized: "A Wi-Fi link macOS keeps for things that can't wait, like AirPlay and Sidecar.",
                bundle: .strings
            )
        case .wifiAware: String(localized: "Lets nearby devices find each other and connect directly, without a network.", bundle: .strings)
        case .accessPoint: String(localized: "Used when this Mac shares its connection with other devices over Wi-Fi.", bundle: .strings)
        case .privateLink: String(localized: "A private link macOS uses with a device connected over USB or Thunderbolt.", bundle: .strings)
        case .virtualMachine: String(localized: "The network of a virtual machine or container on this Mac.", bundle: .strings)
        case .other: String(localized: "A network connection of another kind.", bundle: .strings)
        }
    }

    static func symbol(_ kind: NetworkInterfaceInfo.Kind) -> String {
        switch kind {
        case .wifi, .wifiAware: "wifi"
        case .ethernet: "cable.connector"
        case .thunderbolt: "bolt"
        case .bridge: "point.3.connected.trianglepath.dotted"
        case .loopback: "arrow.triangle.2.circlepath"
        case .tunnel: "lock.shield"
        case .airDrop, .lowLatency: "dot.radiowaves.left.and.right"
        case .accessPoint: "personalhotspot"
        case .privateLink: "link"
        case .virtualMachine: "desktopcomputer"
        case .other: "network"
        }
    }

    static func status(_ status: NetworkInterfaceInfo.Status) -> String {
        switch status {
        case .connected: String(localized: "Connected", bundle: .strings, comment: "Network interface status: ifconfig's active")
        case .notConnected: String(localized: "Not connected", bundle: .strings)
        case .off: String(localized: "Off", bundle: .strings, comment: "Security page: a protection is off")
        }
    }

    static func reach(_ reach: NetworkAddressReach) -> String {
        switch reach {
        case .internet: String(localized: "Reaches the internet", bundle: .strings, comment: "A public IP address")
        case .privateNetwork: String(localized: "Your network only", bundle: .strings, comment: "A private IP address")
        case .localLink: String(localized: "This link only", bundle: .strings, comment: "A link-local IP address")
        case .thisMac: String(localized: "This Mac only", bundle: .strings, comment: "A loopback IP address")
        }
    }

    static func flag(_ flag: NetworkInterfaceInfo.Flag) -> String {
        switch flag {
        case .up: String(localized: "Switched on", bundle: .strings, comment: "ifconfig flag UP")
        case .broadcast: String(localized: "Can message its whole network", bundle: .strings, comment: "ifconfig flag BROADCAST")
        case .loopback: String(localized: "Talks only to this Mac", bundle: .strings, comment: "ifconfig flag LOOPBACK")
        case .pointToPoint: String(localized: "Has one other end", bundle: .strings, comment: "ifconfig flag POINTOPOINT")
        case .smart: String(localized: "Manages its own routes", bundle: .strings, comment: "ifconfig flag SMART")
        case .running: String(localized: "Ready to use", bundle: .strings, comment: "ifconfig flag RUNNING")
        case .noARP: String(localized: "Doesn't look up its neighbors", bundle: .strings, comment: "ifconfig flag NOARP")
        case .promiscuous: String(localized: "Sees all traffic on its link", bundle: .strings, comment: "ifconfig flag PROMISC")
        case .simplex: String(localized: "Doesn't hear its own broadcasts", bundle: .strings, comment: "ifconfig flag SIMPLEX")
        case .multicast: String(localized: "Can message groups of devices", bundle: .strings, comment: "ifconfig flag MULTICAST")
        }
    }

    static func speed(_ bitsPerSecond: UInt64) -> String {
        let megabits = Double(bitsPerSecond) / 1_000_000
        if megabits >= 1000 {
            let rate = (megabits / 1000).formatted(.number.precision(.fractionLength(0 ... 1)))
            return String(localized: "\(rate) Gb/s", bundle: .strings, comment: "A network link's speed in gigabits per second")
        }
        let rate = Int(megabits.rounded()).formatted()
        return String(localized: "\(rate) Mb/s", bundle: .strings, comment: "Wi-Fi link rate in megabits per second")
    }
}
