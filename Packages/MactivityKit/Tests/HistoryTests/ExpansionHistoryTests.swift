import Core
import Foundation
@testable import History
import Testing

@Suite("History: sensors, thermal pressure, Energy Impact, battery days")
struct ExpansionHistoryTests {
    func battery(capacity: Double, cycles: Int, onBattery: Bool) -> BatteryStats {
        BatteryStats(
            percent: 80,
            isCharging: false,
            source: onBattery ? .battery : .ac,
            timeRemaining: nil,
            cycleCount: cycles,
            maxCapacityPercent: capacity,
            powerDrawWatts: 5
        )
    }

    let sensors = SensorStats(
        temperatures: [TemperatureReading(id: "cpu", name: "CPU", celsius: 50), TemperatureReading(id: "gpu", name: "GPU", celsius: 40)],
        fans: [FanReading(id: 0, rpm: 2400, minRPM: 2300, maxRPM: 7800), FanReading(id: 1, rpm: 2600, minRPM: 2300, maxRPM: 7800)],
        peripherals: []
    )

    @Test("System rows keep CPU/GPU temperature, the fastest fan, and thermal pressure")
    func sensorColumns() async throws {
        let clock = TestClock(Build.date(0))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        try await store.record(Build.snapshot(at: 0, sensors: sensors, thermal: .serious))
        try await store.record(Build.snapshot(at: 60))
        clock.set(offset: 120)
        let cpu = try await store.series(metric: .cpuTemperature, app: nil, range: .h12)
        let fan = try await store.series(metric: .fanSpeed, app: nil, range: .h12)
        let thermal = try await store.series(metric: .thermalPressure, app: nil, range: .h12)
        #expect(cpu.first?.average == 50)
        #expect(fan.first?.maximum == 2600)
        #expect(thermal.first?.maximum == Double(ThermalPressure.serious.rank))
    }

    @Test("Energy Impact is stored per app")
    func energyImpact() async throws {
        let clock = TestClock(Build.date(0))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        let app = AppAggregate(
            app: Build.identity("com.example"),
            processCount: 1,
            cpuPercent: 1,
            memoryBytes: 1,
            energyMW: 1,
            diskReadBPS: 0,
            diskWriteBPS: 0,
            netInBPS: nil,
            netOutBPS: nil,
            gpuPercent: nil,
            energyImpact: 12
        )
        try await store.record(Build.snapshot(at: 0, apps: [app]))
        try await store.record(Build.snapshot(at: 60))
        clock.set(offset: 120)
        let top = try await store.topApps(metric: .energyImpact, range: .h12, limit: 1)
        #expect(top.first?.value == 12)
    }

    @Test("Battery days keep the latest capacity and cycles, and add up time on battery across a relaunch")
    func batteryDays() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("battery-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = TestClock(Build.date(0))
        do {
            let store = try SQLiteHistoryStore(url: url, now: { clock.now })
            for step in 0 ..< 12 {
                try await store.record(Build.snapshot(at: Double(step * 5), battery: battery(capacity: 97, cycles: 210, onBattery: true)))
            }
            try await store.flush()
        }
        let reopened = try SQLiteHistoryStore(url: url, now: { clock.now })
        for step in 12 ..< 24 {
            try await reopened.record(Build.snapshot(at: Double(step * 5), battery: battery(capacity: 96, cycles: 211, onBattery: true)))
        }
        try await reopened.flush()
        let days = try await reopened.batteryHistory(days: 7)
        let today = try #require(days.last)
        #expect(today.maxCapacityPercent == 96)
        #expect(today.cycleCount == 211)
        #expect(abs(today.minutesOnBattery - 2) < 0.001)
    }

    @Test("Sleep doesn't count as time on battery: a snapshot adds at most a minute (D-133)")
    func sleepGap() async throws {
        let clock = TestClock(Build.date(0))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        // A Power Nap wake an hour after the last one, still unplugged.
        try await store.record(Build.snapshot(
            at: 0, battery: battery(capacity: 99, cycles: 1, onBattery: true), interval: .seconds(3600)
        ))
        try await store.flush()
        #expect(try await store.batteryHistory(days: 1).first?.minutesOnBattery == 1)
    }

    @Test("Upgrading caps a finished day's time on battery at the minutes sampled (D-133)")
    func boundsPastDays() async throws {
        let clock = TestClock(Build.date(0))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        try await store.database.write { db in
            // One day on a real Mac: asleep all day, 107 minutes sampled in Power Nap wakes, 24 h stored.
            try db.execute(sql: "INSERT INTO battery_day (day, secondsOnBattery) VALUES (0, 86400), (86400, 3000), (172800, 7200)")
            try db.execute(sql: """
            INSERT INTO hour (t, app, samples, minutes) VALUES (0, '*', 600, 60), (3600, '*', 280, 47), (86400, '*', 600, 60)
            """)
            try HistorySchema.boundBatteryDays(db, before: 172_800)
        }
        let seconds = try await store.database.read { db in
            try Double.fetchAll(db, sql: "SELECT secondsOnBattery FROM battery_day ORDER BY day")
        }
        // Capped to 107 minutes; already within 60 minutes; today (no hours yet) untouched.
        #expect(seconds == [6420, 3000, 7200])
    }

    @Test("Time on AC doesn't count as time on battery")
    func onAC() async throws {
        let clock = TestClock(Build.date(0))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        try await store.record(Build.snapshot(at: 0, battery: battery(capacity: 99, cycles: 1, onBattery: false)))
        try await store.flush()
        #expect(try await store.batteryHistory(days: 1).first?.minutesOnBattery == 0)
    }
}
