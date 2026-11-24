import Core
import Foundation
import GRDB
@testable import History
import Testing

@Suite("Battery temperature, chargers, streaks and hours in the store (D-271, D-272, D-274, D-275)")
struct ChargerAndTemperatureStoreTests {
    private func battery(
        _ percent: Double, charging: Bool = true, source: BatteryStats.PowerSource = .ac, temperature: Double? = 30, watts: Double? = 96,
        delivered: Double? = 60
    ) -> BatteryStats {
        BatteryStats(
            percent: percent, isCharging: charging, source: source, timeRemaining: nil, cycleCount: nil, maxCapacityPercent: nil,
            powerDrawWatts: 0, systemLoadWatts: 10, adapterWatts: watts, temperatureCelsius: temperature, adapterInputWatts: delivered
        )
    }

    @Test("Temperature is recorded apart while charging and in use, on the minute, quarter and hour tiers")
    func temperatureTiers() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        // 15 minutes charging at 34°, then 45 on battery at 26°, then a tick that closes the hour.
        for minute in 0 ..< 60 {
            let stats = minute < 15
                ? battery(50, temperature: 34)
                : battery(60, charging: false, source: .battery, temperature: 26, watts: nil, delivered: nil)
            try await store.record(Build.snapshot(at: Double(minute) * 60, battery: stats))
        }
        try await store.record(Build.snapshot(at: 3660, battery: battery(60, charging: false, source: .battery, temperature: 26)))
        clock.set(offset: 2 * hour)
        let charging = try await store.series(metric: .batteryTempCharging, app: nil, range: .h24)
        let inUse = try await store.series(metric: .batteryTempInUse, app: nil, range: .h24)
        #expect(charging.count == 15)
        #expect(charging.allSatisfy { $0.average == 34 })
        #expect(inUse.count == 46 - 1)
        #expect(inUse.allSatisfy { $0.average == 26 })

        let hourRow = try await store.database.read { db -> [Double?] in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT batteryTempChargingAvg AS c, batteryTempInUseAvg AS u, batteryTempChargingMax AS m FROM hour WHERE app = '*'"
            )
            return [row?["c"], row?["u"], row?["m"]]
        }
        #expect(hourRow == [34, 26, 34])
        let quarters = try await store.database.read { db -> [Double?] in
            try Row.fetchAll(db, sql: "SELECT batteryTempChargingAvg AS c FROM quarter WHERE app = '*' ORDER BY t").map { $0["c"] }
        }
        // The first quarter was all charging; the second had no charging, so no reading, not 0.
        #expect(quarters.first == 34)
        #expect(quarters.dropFirst().first == .some(nil))
    }

    @Test("A charger's use is written by rating and condition, adds up over a relaunch, and goes with Delete All")
    func chargerRows() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        for (index, percent) in [40.0, 41, 42, 43, 44, 45, 46, 47].enumerated() {
            try await store.record(Build.snapshot(at: Double(index) * 20, battery: battery(percent)))
        }
        try await store.flush()
        clock.set(offset: 3600)
        var rows = try await store.chargerUse(days: 7)
        #expect(rows.count == 1)
        let first = try #require(rows.first)
        #expect(first.ratingWatts == 96)
        #expect(first.condition == ChargeCondition(band: .low, isWarm: false, isBusy: false))
        #expect(first.percentGained == 7)
        #expect(first.seconds == 140)
        #expect(first.peakWatts == 60)
        #expect(abs(first.deliveredWattSeconds - 60 * 140) < 1e-6)

        // More of the same day: added to the row, with a higher peak.
        try await store.record(Build.snapshot(at: 160, battery: battery(47)))
        try await store.record(Build.snapshot(at: 180, battery: battery(48, delivered: 80)))
        try await store.flush()
        rows = try await store.chargerUse(days: 7)
        #expect(rows.count == 1)
        #expect(rows.first?.seconds == 180)
        #expect(rows.first?.percentGained == 8)
        #expect(rows.first?.peakWatts == 80)

        try await store.deleteAll()
        #expect(try await store.chargerUse(days: 7).isEmpty)
    }

    @Test("Nothing about chargers on battery, or from a Mac whose charger reports no rating")
    func noCharger() async throws {
        let store = try SQLiteHistoryStore.inMemory(clock: TestClock(), retentionDays: 365)
        for index in 0 ..< 10 {
            try await store.record(Build.snapshot(
                at: Double(index) * 20, battery: battery(50, charging: false, source: .battery, watts: nil, delivered: nil)
            ))
            try await store.record(Build.snapshot(at: Double(index) * 20 + 10, battery: battery(50, watts: nil)))
        }
        try await store.flush()
        #expect(try await store.chargerUse(days: 7).isEmpty)
    }

    @Test("Stretches come back oldest first, with their app, from when they began")
    func stretches() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        try await store.recordFocus(Build.identity("safari"), from: Build.date(3600), to: Build.date(5400))
        try await store.recordFocus(Build.identity("xcode"), from: Build.date(600), to: Build.date(1200))
        try await store.recordFocus(Build.identity("mail"), from: Build.date(9000), to: Build.date(9100))
        let found = try await store.focusStretches(from: Build.date(0), to: Build.date(9000))
        #expect(found.map(\.app.id) == ["xcode", "safari"])
        #expect(found.first?.start == Build.date(600))
        #expect(found.first?.end == Build.date(1200))
    }

    @Test("Whole-Mac hours say how much of the hour they cover, and leave the hours asleep out")
    func hours() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        // 20 minutes of one hour at 40%, then nothing until the next hour but one.
        for minute in 0 ..< 20 {
            try await store.record(Build.snapshot(at: Double(minute) * 60, cpu: 40))
        }
        try await store.record(Build.snapshot(at: 2 * hour, cpu: 10))
        try await store.record(Build.snapshot(at: 2 * hour + 60, cpu: 10))
        clock.set(offset: 3 * hour)
        let found = try await store.wholeMacHours(from: Build.date(-3600), to: Build.date(4 * hour))
        #expect(found.count == 1)
        #expect(found.first?.cpu == 40)
        #expect(found.first?.coveredMinutes == 20)
    }
}
