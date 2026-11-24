import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Crowded channels, profiles, unlocks and notifications (D-286 to D-289), in each state.
extension NewFeaturesRenderTests {
    struct FixedUnlocks: UnlockHistorySource {
        let reading: UnlockReading

        func read(now _: Date) async -> UnlockReading {
            reading
        }
    }

    struct FixedProfiles: ProfilesSource {
        let reading: ProfilesReading?

        func read() async -> ProfilesReading? {
            reading
        }
    }

    struct FixedScan: WiFiScanSource {
        let reading: WiFiScanReading

        func scan() async -> WiFiScanReading {
            reading
        }
    }

    struct BadLog: NotificationLogSource {
        func deliveries(from _: Date, to _: Date) async -> NotificationLogReading {
            .unreadable
        }
    }

    @Test("Crowded channels")
    func crowdedChannels() async throws {
        let size = CGSize(width: 900, height: 480)
        let before = WiFiChannelsModel(source: SimulatedWiFiScan())
        try await write(WiFiChannelsCard(model: before).padding(), name: "wifi-channels-before", size: size)
        await before.scan()
        try await write(WiFiChannelsCard(model: before).padding(), name: "wifi-channels-crowded", size: size)
        // A real scan: nothing near its channel.
        let own = WiFiChannelInfo(channel: 149, band: .ghz5, widthMHz: 40)
        func network(_ channel: Int, _ band: NetworkDetails.Band, _ width: Int, _ rssi: Int) -> NearbyNetwork {
            NearbyNetwork(channel: WiFiChannelInfo(channel: channel, band: band, widthMHz: width), rssi: rssi)
        }
        let real = WiFiScan(at: Date(), own: own, ownRSSI: -67, heard: [
            network(1, .ghz2, 20, -78), network(52, .ghz5, 40, -62), network(56, .ghz5, 40, -85), network(6, .ghz2, 20, -91),
            network(1, .ghz2, 20, -65), network(6, .ghz2, 20, -55), network(6, .ghz2, 20, -54), network(11, .ghz2, 20, -77),
            network(52, .ghz5, 40, -60),
        ])
        let clear = WiFiChannelsModel(source: FixedScan(reading: .scanned(real)))
        await clear.scan()
        try await write(WiFiChannelsCard(model: clear).padding(), name: "wifi-channels-clear", size: size)
        let off = WiFiChannelsModel(source: FixedScan(reading: .notJoined))
        await off.scan()
        try await write(WiFiChannelsCard(model: off).padding(), name: "wifi-channels-off", size: CGSize(width: 900, height: 200))
    }

    @Test("Configuration profiles")
    func configurationProfiles() async throws {
        let size = CGSize(width: 900, height: 480)
        func card(_ source: any ProfilesSource) -> some View {
            ProfilesCard(model: ProfilesModel(source: source)).padding()
        }
        try await write(card(SimulatedProfiles()), name: "profiles", size: size)
        let none = ProfilesReading(profiles: [], enrollment: ManagementEnrollment(automated: true, managed: true))
        try await write(card(FixedProfiles(reading: none)), name: "profiles-managed", size: size)
        try await write(card(FixedProfiles(reading: nil)), name: "profiles-unreadable", size: size)
    }

    @Test("Unlocks")
    func unlocksCard() async throws {
        let size = CGSize(width: 900, height: 560)
        func card(_ source: any UnlockHistorySource) -> some View {
            UnlocksCard(model: UnlocksModel(source: source)).padding()
        }
        try await write(card(SimulatedUnlocks()), name: "unlocks", size: size)
        // As on a real Mac: Touch ID and a password, no failures found.
        let now = Date()
        let real = UnlockLogReading(
            unlocks: [
                UnlockEvent(at: now.addingTimeInterval(-3600), method: .touchID),
                UnlockEvent(at: now.addingTimeInterval(-90000), method: .password),
            ],
            failures: [],
            coveredFrom: now.addingTimeInterval(-7 * 86400)
        )
        try await write(card(FixedUnlocks(reading: .read(real))), name: "unlocks-none-failed", size: size)
        try await write(card(FixedUnlocks(reading: .unreadable)), name: "unlocks-unreadable", size: size)
        let empty = UnlockLogReading(unlocks: [], failures: [], coveredFrom: nil)
        try await write(card(FixedUnlocks(reading: .read(empty))), name: "unlocks-empty", size: size)
    }

    @Test("Notifications")
    func notificationsCard() async throws {
        let size = CGSize(width: 900, height: 440)
        let store = SimulatedHistoryStore()
        func card(_ source: any NotificationLogSource) -> some View {
            NotificationsCard(model: NotificationsModel(source: source), store: store, range: .d7, generation: 0).padding()
        }
        try await write(card(SimulatedNotificationLog()), name: "notifications", size: size)
        try await write(card(BadLog()), name: "notifications-unreadable", size: size)
    }

    @Test("The three pages with the new cards, at the window's default width")
    func pagesWithNewCards() async throws {
        let services = AppServices.preview()
        await services.wifiChannels.scan()
        try await write(SecurityView(services: services), name: "security-with-profiles", size: CGSize(width: 900, height: 1500))
    }
}
