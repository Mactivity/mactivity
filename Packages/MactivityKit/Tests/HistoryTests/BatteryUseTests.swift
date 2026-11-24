import Core
import Foundation
@testable import History
import Testing

@Suite("Battery use by app (D-100)")
struct BatteryUseTests {
    private func battery(_ percent: Double, onBattery: Bool) -> BatteryStats {
        BatteryStats(
            percent: percent, isCharging: !onBattery, source: onBattery ? .battery : .ac, timeRemaining: nil,
            cycleCount: nil, maxCapacityPercent: nil, powerDrawWatts: nil
        )
    }

    @Test("Shares of Energy Impact while on battery; time on battery; the fall in charge")
    func use() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        // A quarter-hour on battery, falling from 80 to 70, then a quarter-hour on power.
        for minute in 0 ..< 15 {
            var a = Build.app("a")
            var b = Build.app("b")
            a = AppAggregate(
                app: a.app,
                processCount: 1,
                cpuPercent: 0,
                memoryBytes: 0,
                energyMW: nil,
                diskReadBPS: 0,
                diskWriteBPS: 0,
                netInBPS: nil,
                netOutBPS: nil,
                gpuPercent: nil,
                energyImpact: 30
            )
            b = AppAggregate(
                app: b.app,
                processCount: 1,
                cpuPercent: 0,
                memoryBytes: 0,
                energyMW: nil,
                diskReadBPS: 0,
                diskWriteBPS: 0,
                netInBPS: nil,
                netOutBPS: nil,
                gpuPercent: nil,
                energyImpact: 10
            )
            try await store.record(Build.snapshot(
                at: Double(minute) * 60, apps: [a, b], battery: battery(80 - Double(minute) * 10 / 14, onBattery: true)
            ))
        }
        for minute in 15 ..< 30 {
            try await store.record(Build.snapshot(at: Double(minute) * 60, battery: battery(70, onBattery: false)))
        }
        try await store.record(Build.snapshot(at: 30 * 60))
        try await store.flush()
        clock.set(offset: 40 * 60)
        let use = try await store.batteryUse(from: Build.base, to: Build.date(3600), limit: 5)
        #expect(use.apps.map(\.app.id) == ["a", "b"])
        #expect(abs((use.apps.first?.value ?? 0) - 0.75) < 0.001)
        #expect(abs(use.onBatterySeconds - 900) < 1)
    }

    @Test("Unplugged at: the first minute on battery after the last one plugged in (D-150)")
    func unplugged() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        // On battery, plugged in for 10 minutes, then unplugged at minute 20.
        for minute in 0 ..< 40 {
            let onBattery = !(10 ..< 20).contains(minute)
            try await store.record(Build.snapshot(at: Double(minute) * 60, battery: battery(60, onBattery: onBattery)))
        }
        try await store.record(Build.snapshot(at: 40 * 60, battery: battery(60, onBattery: true)))
        try await store.flush()
        let now = Build.date(41 * 60)
        #expect(try await store.unpluggedAt(now: now) == Build.date(20 * 60))
        // Plugged in at the last minute recorded: not unplugged.
        let plugged = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        for minute in 0 ..< 5 {
            try await plugged.record(Build.snapshot(at: Double(minute) * 60, battery: battery(60, onBattery: minute < 3)))
        }
        try await plugged.record(Build.snapshot(at: 5 * 60))
        try await plugged.flush()
        #expect(try await plugged.unpluggedAt(now: Build.date(6 * 60)) == nil)
    }

    @Test("On battery for more than the minute rows' two days: found in the quarter-hours, to within one")
    func unpluggedLongAgo() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        for minute in 0 ..< 5 {
            try await store.record(Build.snapshot(at: Double(minute) * 60, battery: battery(90, onBattery: false)))
        }
        // Every 10 minutes on battery for 50 hours, the Mac mostly asleep.
        for minute in stride(from: 5, through: 50 * 60, by: 10) {
            clock.set(offset: Double(minute) * 60)
            try await store.record(Build.snapshot(at: Double(minute) * 60, battery: battery(60, onBattery: true)))
        }
        try await store.flush()
        let found = try #require(try await store.unpluggedAt(now: Build.date(50 * 3600 + 60)))
        #expect(abs(found.timeIntervalSince(Build.date(5 * 60))) <= 900)
    }
}
