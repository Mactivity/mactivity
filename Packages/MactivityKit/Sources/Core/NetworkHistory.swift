import Foundation

/// What the Mac is connected through (1.5, D-233).
public enum NetworkKind: String, Sendable, Hashable, Codable, CaseIterable {
    case wifi, ethernet
    /// An iPhone's Personal Hotspot, or another link macOS marks expensive.
    case hotspot
    /// A tunnel carries the traffic.
    case vpn
    case cellular, other
    /// No usable connection.
    case offline
    /// The Mac slept, or Mactivity quit: not recorded until it's back. Never shown (D-236).
    case asleep

    public var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .hotspot: String(localized: "Personal Hotspot", bundle: .strings, comment: "Network kind: an iPhone's hotspot")
        case .vpn: "VPN"
        case .cellular: String(localized: "Cellular", bundle: .strings, comment: "Network kind")
        case .other: String(localized: "Other network", bundle: .strings, comment: "Network kind")
        case .offline: String(localized: "Offline", bundle: .strings, comment: "Network kind: no connection")
        case .asleep: String(localized: "Asleep", bundle: .strings, comment: "Network kind: the Mac slept, nothing recorded")
        }
    }
}

/// The Mac joined a network, switched, or lost its connection (D-233).
public struct NetworkChange: Sendable, Hashable, Codable {
    public let at: Date
    public let kind: NetworkKind
    /// The BSD name: en0, utun4. Nil when offline.
    public let interface: String?

    public init(at: Date, kind: NetworkKind, interface: String?) {
        self.at = at
        self.kind = kind
        self.interface = interface
    }
}

/// One minute's Wi-Fi signal (D-234).
public struct WiFiReading: Sendable, Hashable, Codable {
    public let at: Date
    /// dBm: -50 is strong, -80 weak.
    public let rssi: Int
    public let noise: Int
    /// Mbit/s.
    public let transmitRate: Double
    public let channel: Int?

    public init(at: Date, rssi: Int, noise: Int, transmitRate: Double, channel: Int?) {
        self.at = at
        self.rssi = rssi
        self.noise = noise
        self.transmitRate = transmitRate
        self.channel = channel
    }

    /// Signal over noise, in dB: 25 or more is good, under 15 poor.
    public var snr: Int {
        rssi - noise
    }
}

public protocol NetworkHistoryStore: Sendable {
    func recordNetworkChange(_ change: NetworkChange) async throws
    /// Changes in the span, oldest first, plus the last one before it: what the span began on.
    func networkChanges(from: Date, to: Date) async throws -> [NetworkChange]
    func recordWiFi(_ reading: WiFiReading) async throws
    func wifiReadings(from: Date, to: Date) async throws -> [WiFiReading]
}

/// A stretch on one network, from the change log (D-233).
public struct NetworkSession: Sendable, Hashable, Identifiable {
    public let kind: NetworkKind
    public let interface: String?
    public let start: Date
    /// Nil while it's still the current one.
    public let end: Date?

    public var id: Date {
        start
    }

    public init(kind: NetworkKind, interface: String?, start: Date, end: Date?) {
        self.kind = kind
        self.interface = interface
        self.start = start
        self.end = end
    }

    /// For the list (D-236): sleep isn't shown, the same network either side of a sleep is one
    /// stretch, and a drop shorter than a minute is left out, so a week of a laptop's sleeps
    /// still reads as the networks it was on. Newest first.
    public static func listed(_ sessions: [NetworkSession], now: Date) -> [NetworkSession] {
        var merged: [NetworkSession] = []
        for session in sessions.reversed() {
            let length = (session.end ?? now).timeIntervalSince(session.start)
            if session.kind == .asleep || (session.kind == .offline && length < 60) {
                continue
            }
            if let last = merged.last, last.kind == session.kind, last.interface == session.interface {
                merged[merged.count - 1] = NetworkSession(kind: last.kind, interface: last.interface, start: last.start, end: session.end)
            } else {
                merged.append(session)
            }
        }
        return merged.reversed()
    }

    /// Pure: the log as stretches, newest first, clipped to `from`. A change to the same
    /// network as before isn't a new stretch.
    public static func sessions(_ changes: [NetworkChange], from: Date, now: Date) -> [NetworkSession] {
        var merged: [NetworkChange] = []
        for change in changes.sorted(by: { $0.at < $1.at }) {
            if let last = merged.last, last.kind == change.kind, last.interface == change.interface {
                continue
            }
            merged.append(change)
        }
        var sessions: [NetworkSession] = []
        for (index, change) in merged.enumerated() {
            let end = index + 1 < merged.count ? merged[index + 1].at : nil
            if let end, end <= from {
                continue
            }
            sessions.append(NetworkSession(kind: change.kind, interface: change.interface, start: max(change.at, from), end: end))
        }
        return sessions.reversed()
    }
}
