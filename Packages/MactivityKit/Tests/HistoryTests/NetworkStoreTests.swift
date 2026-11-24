import Core
import Foundation
@testable import History
import Testing

/// Network changes and Wi-Fi over time (D-233, D-234).
struct NetworkStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Changes in a span come with the one before it, what the span began on")
    func changes() async throws {
        let store = try SQLiteHistoryStore(url: nil)
        try await store.recordNetworkChange(NetworkChange(at: t0, kind: .wifi, interface: "en0"))
        try await store.recordNetworkChange(NetworkChange(at: t0 + 3600, kind: .vpn, interface: "utun4"))
        try await store.recordNetworkChange(NetworkChange(at: t0 + 7200, kind: .offline, interface: nil))
        let read = try await store.networkChanges(from: t0 + 4000, to: t0 + 10000)
        #expect(read.map(\.kind) == [.vpn, .offline])
        #expect(read.last?.interface == nil)
        #expect(try await store.networkChanges(from: t0 - 100, to: t0 + 10).map(\.kind) == [.wifi])
    }

    @Test("Wi-Fi readings, a row a minute")
    func wifi() async throws {
        let store = try SQLiteHistoryStore(url: nil)
        try await store.recordWiFi(WiFiReading(at: t0 + 10, rssi: -51, noise: -97, transmitRate: 864, channel: 117))
        try await store.recordWiFi(WiFiReading(at: t0 + 30, rssi: -55, noise: -96, transmitRate: 702, channel: 117))
        try await store.recordWiFi(WiFiReading(at: t0 + 70, rssi: -70, noise: -95, transmitRate: 144, channel: nil))
        let read = try await store.wifiReadings(from: t0 - 60, to: t0 + 600)
        #expect(read.count == 2)
        #expect(read.first?.rssi == -55)
        #expect(read.last?.snr == 25)
    }

    @Test("Sessions from the log: same network twice is one stretch, newest first, clipped")
    func sessions() {
        let changes = [
            NetworkChange(at: t0, kind: .wifi, interface: "en0"),
            NetworkChange(at: t0 + 100, kind: .wifi, interface: "en0"),
            NetworkChange(at: t0 + 3600, kind: .offline, interface: nil),
            NetworkChange(at: t0 + 3700, kind: .ethernet, interface: "en7"),
        ]
        let sessions = NetworkSession.sessions(changes, from: t0 + 1800, now: t0 + 5000)
        #expect(sessions.map(\.kind) == [.ethernet, .offline, .wifi])
        #expect(sessions.last?.start == t0 + 1800)
        #expect(sessions.first?.end == nil)
    }
}
