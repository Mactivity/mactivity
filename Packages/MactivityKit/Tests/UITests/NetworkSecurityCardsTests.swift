import Core
import Foundation
import Simulated
import Testing
@testable import UI

private actor Counter {
    private(set) var count = 0

    func add() {
        count += 1
    }
}

private struct CountingScan: WiFiScanSource {
    let counter = Counter()

    func scan() async -> WiFiScanReading {
        await counter.add()
        return .failed
    }
}

private struct CountingUnlocks: UnlockHistorySource {
    let counter = Counter()

    func read(now _: Date) async -> UnlockReading {
        await counter.add()
        return .unreadable
    }
}

private actor FakeLog: NotificationLogSource {
    var answer: NotificationLogReading = .read([])
    private(set) var asked: [(from: Date, to: Date)] = []

    func set(_ answer: NotificationLogReading) {
        self.answer = answer
    }

    func deliveries(from: Date, to: Date) async -> NotificationLogReading {
        asked.append((from, to))
        return answer
    }
}

private actor MemoryStore: NotificationHistoryStore {
    var events: [NotificationEvent] = []

    func recordNotifications(_ new: [NotificationEvent]) async throws {
        events += new
    }

    func notifications(from: Date, to: Date) async throws -> [NotificationEvent] {
        events.filter { $0.at >= from && $0.at < to }
    }

    func notificationSpan() async throws -> ClosedRange<Date>? {
        guard let first = events.map(\.at).min(), let last = events.map(\.at).max() else {
            return nil
        }
        return first ... last
    }
}

@MainActor
@Suite("Crowded channels, unlocks and notifications: when each reads")
struct NetworkSecurityCardsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A scan runs when asked, at most once a minute, and failing counts as a scan")
    func scanLimit() async {
        let source = CountingScan()
        let model = WiFiChannelsModel(source: source)
        #expect(model.reading == nil)
        await model.scan(now: now)
        await model.scan(now: now.addingTimeInterval(59))
        #expect(await source.counter.count == 1)
        #expect(model.reading == .failed)
        #expect(!model.mayScan(now: now.addingTimeInterval(59)))
        await model.scan(now: now.addingTimeInterval(60))
        #expect(await source.counter.count == 2)
    }

    @Test("A clock set back doesn't lock the button")
    func clockBack() {
        #expect(WiFiChannelsModel.gapOver(now, now: now.addingTimeInterval(-3600)))
        #expect(WiFiChannelsModel.gapOver(nil, now: now))
    }

    @Test("Unlocks read once in five minutes")
    func unlocksCache() async {
        let source = CountingUnlocks()
        let model = UnlocksModel(source: source)
        await model.load(now: now)
        await model.load(now: now.addingTimeInterval(299))
        #expect(await source.counter.count == 1)
        #expect(model.reading == .unreadable)
        await model.load(now: now.addingTimeInterval(300))
        #expect(await source.counter.count == 2)
    }

    @Test("The recording read waits five minutes after launch, then comes every three hours")
    func due() {
        #expect(!NotificationsModel.isDue(started: now, lastAttempt: nil, now: now.addingTimeInterval(299)))
        #expect(NotificationsModel.isDue(started: now, lastAttempt: nil, now: now.addingTimeInterval(300)))
        #expect(!NotificationsModel.isDue(started: now, lastAttempt: now, now: now.addingTimeInterval(3 * 3600 - 1)))
        #expect(NotificationsModel.isDue(started: now, lastAttempt: now, now: now.addingTimeInterval(3 * 3600)))
    }

    @Test("Reads start from the last good one, overlapping; a bad read says so and loses nothing")
    func reads() async {
        let log = FakeLog()
        let store = MemoryStore()
        let model = NotificationsModel(source: log)
        let event = NotificationEvent(at: now, app: "com.apple.mail")
        await log.set(.read([event]))

        await model.read(now: now, store: store)
        // First ever read: as far back as it goes.
        #expect(await log.asked.last?.from == now.addingTimeInterval(-2 * 86400))
        #expect(await store.events == [event])

        let later = now.addingTimeInterval(3 * 3600)
        await log.set(.unreadable)
        await model.read(now: later, store: store)
        #expect(model.unreadable)
        #expect(await log.asked.last?.from == now.addingTimeInterval(-120))
        #expect(await store.events == [event])

        // After that bad read, the next still starts from the good one, and the warning clears.
        let later2 = later.addingTimeInterval(3 * 3600)
        await log.set(.read([]))
        await model.read(now: later2, store: store)
        #expect(!model.unreadable)
        #expect(await log.asked.last?.from == now.addingTimeInterval(-120))

        // A new launch knows only what's stored.
        let fresh = NotificationsModel(source: log)
        await fresh.read(now: later2, store: store)
        #expect(await log.asked.last?.from == now.addingTimeInterval(-120))
    }

    @Test("Opening the card reads at most once in five minutes")
    func cardRead() async {
        let log = FakeLog()
        let store = MemoryStore()
        let model = NotificationsModel(source: log)
        await model.refresh(now: now, store: store)
        await model.refresh(now: now.addingTimeInterval(299), store: store)
        #expect(await log.asked.count == 1)
        await model.refresh(now: now.addingTimeInterval(300), store: store)
        #expect(await log.asked.count == 2)
    }

    @Test("Wi-Fi's words: what it found, and advice only when there's a quieter channel")
    func wifiWords() {
        let own = WiFiChannelInfo(channel: 6, band: .ghz2)
        let clear = WiFiCrowding.analyze(WiFiScan(at: now, own: own, ownRSSI: -50, heard: []))
        #expect(WiFiChannelsText.advice(clear) == nil)
        let busy = WiFiCrowding.analyze(WiFiScan(at: now, own: own, ownRSSI: -40, heard: [
            NearbyNetwork(channel: own, rssi: -60),
        ]))
        #expect(busy.level == .crowded)
        #expect(WiFiChannelsText.advice(busy)?.contains("1") == true)
        #expect(WiFiChannelsText.own(own).contains("2.4 GHz"))
    }

    @Test("A kind of setting Mactivity doesn't know keeps macOS's own name")
    func payloadWords() {
        #expect(ProfileText.payload(type: "com.example.unknown") == "com.example.unknown")
        #expect(ProfileText.payload(type: "com.apple.wifi.managed") != "com.apple.wifi.managed")
        #expect(ProfileText.changes([]).isEmpty == false)
    }
}
