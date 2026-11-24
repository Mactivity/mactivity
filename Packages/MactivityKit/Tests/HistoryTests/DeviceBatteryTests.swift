import Core
import Foundation
@testable import History
import Testing

/// Accessory batteries over time (D-094).
@Suite("Accessory batteries")
struct DeviceBatteryTests {
    private func device(_ id: String, _ percent: Double, name: String? = nil) -> PeripheralBattery {
        PeripheralBattery(id: id, name: name ?? "Device \(id)", kind: .mouse, percent: percent)
    }

    @Test("A level is kept when it moves a point or an hour passes")
    func keepRule() {
        #expect(SQLiteHistoryStore.shouldKeep(percent: 80, at: 0, last: nil))
        #expect(!SQLiteHistoryStore.shouldKeep(percent: 80, at: 600, last: (80, 0)))
        #expect(!SQLiteHistoryStore.shouldKeep(percent: 80.5, at: 600, last: (80, 0)))
        #expect(SQLiteHistoryStore.shouldKeep(percent: 79, at: 600, last: (80, 0)))
        #expect(SQLiteHistoryStore.shouldKeep(percent: 80, at: 3600, last: (80, 0)))
    }

    @Test("Recorded levels come back per device, oldest first, under the latest name")
    func roundTrip() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        try await store.recordDevices([device("m", 90), device("k", 50)], at: Build.date(0))
        try await store.recordDevices([device("m", 90), device("k", 50)], at: Build.date(600))
        try await store.recordDevices([device("m", 85, name: "Renamed")], at: Build.date(1200))
        clock.set(offset: hour)
        let histories = try await store.deviceHistory(days: 7)
        #expect(histories.map(\.name) == ["Device k", "Renamed"])
        #expect(histories.first { $0.id == "m" }?.points.map(\.percent) == [90, 85])
        #expect(histories.first { $0.id == "k" }?.points.count == 1)
    }

    @Test("Device rows follow the retention setting")
    func retention() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 30)
        try await store.recordDevices([device("m", 90)], at: Build.date(0))
        clock.set(offset: 31 * day)
        try await store.record(Build.snapshot(at: 31 * day))
        #expect(try await store.rowCount("device_battery") == 0)
    }
}

@Suite("Accessory battery insight")
struct DeviceBatteryInsightTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func points(_ levels: [Double], every hours: Double = 1) -> [DeviceBatteryPoint] {
        levels.enumerated().map { DeviceBatteryPoint(at: start + Double($0.offset) * hours * 3600, percent: $0.element) }
    }

    @Test("Charged where the rise topped out; the drain since then gives the time left")
    func chargeAndDrain() {
        // 20 → 100 over four hours, then down 2 points an hour for twelve hours.
        let levels = [20.0, 50, 80, 100] + (1 ... 12).map { 100 - Double($0) * 2 }
        let insight = DeviceBatteryInsight(points: points(levels), now: start + 16 * 3600)
        #expect(insight.lastCharged == start + 3 * 3600)
        #expect(insight.drainPerDay == 48)
        #expect(insight.daysLeft == 76.0 / 48)
    }

    @Test("A plateau at the top counts from when it reached full")
    func plateau() {
        let insight = DeviceBatteryInsight(points: points([40, 100, 100, 100, 96, 92, 88, 84, 80]), now: start)
        #expect(insight.lastCharged == start + 3600)
    }

    @Test("No charge seen, too little drop, or too short: nothing to claim")
    func notEnough() {
        let steady = DeviceBatteryInsight(points: points([90, 89, 88]), now: start)
        #expect(steady.lastCharged == nil)
        #expect(steady.drainPerDay == nil)
        let short = DeviceBatteryInsight(points: points([50, 100, 95], every: 1), now: start)
        #expect(short.lastCharged != nil)
        #expect(short.drainPerDay == nil)
        let empty = DeviceBatteryInsight(points: [], now: start)
        #expect(empty.lastCharged == nil && empty.daysLeft == nil)
    }
}
