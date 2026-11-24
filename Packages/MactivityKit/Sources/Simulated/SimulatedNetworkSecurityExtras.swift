import Core
import Foundation

/// Crowded Wi-Fi channels for previews and Simulated data (D-286): a busy apartment building.
public struct SimulatedWiFiScan: WiFiScanSource {
    public init() {}

    public func scan() async -> WiFiScanReading {
        func network(_ channel: Int, _ band: NetworkDetails.Band, _ width: Int, _ rssi: Int) -> NearbyNetwork {
            NearbyNetwork(channel: WiFiChannelInfo(channel: channel, band: band, widthMHz: width), rssi: rssi)
        }
        return .scanned(WiFiScan(
            at: Date(), own: WiFiChannelInfo(channel: 36, band: .ghz5, widthMHz: 80), ownRSSI: -54,
            heard: [
                network(36, .ghz5, 80, -54), network(36, .ghz5, 80, -61), network(44, .ghz5, 80, -64), network(40, .ghz5, 40, -72),
                network(52, .ghz5, 80, -81), network(1, .ghz2, 20, -66), network(6, .ghz2, 20, -58), network(6, .ghz2, 20, -74),
                network(11, .ghz2, 20, -83),
            ],
            allowed: Set([36, 40, 44, 48, 52, 56, 60, 64, 149, 153, 157, 161, 165].map { WiFiChannelInfo(channel: $0, band: .ghz5) })
        ))
    }
}

/// Configuration profiles for previews and Simulated data (D-287): one from macOS's Screen Time
/// and one someone installed by hand.
public struct SimulatedProfiles: ProfilesSource {
    public init() {}

    public func read() async -> ProfilesReading? {
        let now = Date()
        return ProfilesReading(
            profiles: [
                ConfigurationProfile(
                    identifier: "com.apple.ManagedSettings.macOS.00000000-0000-4000-8000-000000000001",
                    name: "ManagedSettings User Settings", installed: now.addingTimeInterval(-5 * 86400), isInternal: true,
                    payloads: [ProfilePayload(type: "com.apple.familycontrols.contentfilter", name: nil)]
                ),
                ConfigurationProfile(
                    identifier: "com.example.office-wifi", name: "Office Wi-Fi", organization: "Example Inc.",
                    installed: now.addingTimeInterval(-120 * 86400),
                    payloads: [
                        ProfilePayload(type: "com.apple.wifi.managed", name: "Office"),
                        ProfilePayload(type: "com.apple.security.root", name: "Example Root CA"),
                    ]
                ),
            ],
            enrollment: ManagementEnrollment(automated: false, managed: false)
        )
    }
}

/// Unlocks for previews and Simulated data (D-288).
public struct SimulatedUnlocks: UnlockHistorySource {
    public init() {}

    public func read(now: Date) async -> UnlockReading {
        let hours: [(Double, UnlockMethod)] = [
            (1, .touchID), (4, .touchID), (9, .appleWatch), (22, .touchID), (27, .password), (30, .touchID), (50, .touchID),
            (76, .touchID), (100, .unknown), (140, .touchID),
        ]
        return .read(UnlockLogReading(
            unlocks: hours.map { UnlockEvent(at: now.addingTimeInterval(-$0.0 * 3600), method: $0.1) },
            failures: [FailedUnlock(at: now.addingTimeInterval(-27.1 * 3600), kind: .password)],
            coveredFrom: now.addingTimeInterval(-7 * 86400)
        ))
    }
}

/// Notifications by app for previews and Simulated data (D-289): nothing to read, as the
/// simulated histories already hold them.
public struct SimulatedNotificationLog: NotificationLogSource {
    public init() {}

    public func deliveries(from _: Date, to _: Date) async -> NotificationLogReading {
        .read([])
    }
}

enum SimulatedNotifications {
    /// Three weeks of a chat app through the workday, mail in the morning, a calendar's reminders.
    static func events(from: Date, to: Date) -> [NotificationEvent] {
        let today = Calendar.current.startOfDay(for: to)
        var events: [NotificationEvent] = []
        for back in 0 ..< 21 {
            let day = today.addingTimeInterval(-Double(back) * 86400)
            for (app, hours) in [
                ("com.apple.MobileSMS", [9, 10, 10, 11, 12, 13, 14, 15, 17, 18, 19, 20]),
                ("com.apple.mail", [8, 8, 9, 11, 16]),
                ("com.apple.iCal", [9, 13]),
                ("com.apple.stocks", [7]),
            ] {
                for (index, hour) in hours.enumerated() {
                    events.append(NotificationEvent(at: day.addingTimeInterval(Double(hour) * 3600 + Double(index * 97)), app: app))
                }
            }
        }
        return events.filter { $0.at >= from && $0.at < to }.sorted { $0.at < $1.at }
    }
}

extension SimulatedHistoryStore: NotificationHistoryStore {
    public func recordNotifications(_: [NotificationEvent]) async throws {}

    public func notifications(from: Date, to: Date) async throws -> [NotificationEvent] {
        SimulatedNotifications.events(from: from, to: to)
    }

    public func notificationSpan() async throws -> ClosedRange<Date>? {
        let now = Date()
        return now.addingTimeInterval(-21 * 86400) ... now
    }
}

extension SimulatedThirtyDayHistory: NotificationHistoryStore {
    public func recordNotifications(_: [NotificationEvent]) async throws {}

    public func notifications(from: Date, to: Date) async throws -> [NotificationEvent] {
        SimulatedNotifications.events(from: from, to: to)
    }

    public func notificationSpan() async throws -> ClosedRange<Date>? {
        let now = Date()
        return now.addingTimeInterval(-21 * 86400) ... now
    }
}
