import Core
import Foundation
import Network
import os
import Synchronization

/// Whether the Mac is connected (D-149) and on an expensive connection: an iPhone's Personal Hotspot or another
/// cellular link (D-136). `NWPathMonitor` reports changes as they happen, on its own queue, so
/// nothing is polled; and it only reads the Mac's own network state, it sends nothing.
public final class ExpensiveNetworkWatcher: Sendable {
    private static let log = Logger(subsystem: "app.mactivity.sampling", category: "network")

    public struct State: Hashable, Sendable {
        /// macOS marks the path expensive: Personal Hotspot, cellular, or a network the person
        /// marked as such.
        public let isExpensive: Bool
        /// Low Data Mode is on for the network.
        public let isConstrained: Bool
        /// There's a usable connection at all (D-149).
        public let isConnected: Bool
        /// What carries it, and its interface (D-233).
        public let kind: NetworkKind
        public let interface: String?

        public init(
            isExpensive: Bool, isConstrained: Bool, isConnected: Bool = true, kind: NetworkKind = .other, interface: String? = nil
        ) {
            self.isExpensive = isExpensive
            self.isConstrained = isConstrained
            self.isConnected = isConnected
            self.kind = isConnected ? kind : .offline
            self.interface = isConnected ? interface : nil
        }

        public static let unknown = State(isExpensive: false, isConstrained: false, kind: .other)

        /// Pure: the kind from the path's first interface. A tunnel is a VPN; an expensive link
        /// is a hotspot (an iPhone's, over Wi-Fi or USB); otherwise its type.
        public static func kind(connected: Bool, expensive: Bool, interface: String?, type: String?) -> NetworkKind {
            guard connected else {
                return .offline
            }
            if let interface, ["utun", "ipsec", "ppp", "tun", "tap"].contains(where: interface.hasPrefix) {
                return .vpn
            }
            if expensive, type != "cellular" {
                return .hotspot
            }
            return switch type {
            case "wifi": .wifi
            case "wiredEthernet": .ethernet
            case "cellular": .cellular
            default: .other
            }
        }
    }

    /// The state and the handlers behind locks; the monitor's callback holds this, not `self`.
    private final class Storage: Sendable {
        let current = Mutex(State.unknown)
        let handlers = Mutex<[@Sendable (State) -> Void]>([])
    }

    private let monitor = NWPathMonitor()
    private let storage = Storage()

    public init() {
        monitor.pathUpdateHandler = { [storage] path in
            let primary = path.availableInterfaces.first
            let type: String? = switch primary?.type {
            case .wifi: "wifi"
            case .wiredEthernet: "wiredEthernet"
            case .cellular: "cellular"
            case .other, .loopback, nil: nil
            @unknown default: nil
            }
            let connected = path.status == .satisfied
            let state = State(
                isExpensive: path.isExpensive, isConstrained: path.isConstrained, isConnected: connected,
                kind: State.kind(connected: connected, expensive: path.isExpensive, interface: primary?.name, type: type),
                interface: primary?.name
            )
            let changed = storage.current.withLock { old in
                defer { old = state }
                return old != state
            }
            guard changed else {
                return
            }
            Self.log.info(
                "Network: connected \(state.isConnected), expensive \(state.isExpensive), constrained \(state.isConstrained)"
            )
            for handler in storage.handlers.withLock({ $0 }) {
                handler(state)
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.mactivity.sampling.path", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    public var state: State {
        storage.current.withLock { $0 }
    }

    /// Called on the monitor's queue whenever the state changes.
    public func onChange(_ handler: @escaping @Sendable (State) -> Void) {
        storage.handlers.withLock { $0.append(handler) }
    }
}
