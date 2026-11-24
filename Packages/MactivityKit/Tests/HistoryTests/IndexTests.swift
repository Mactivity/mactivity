import Core
import Foundation
import GRDB
@testable import History
import Testing

@Suite("History: series indexes, app upserts, battery with the minute (D-086)")
struct IndexTests {
    private let minute: TimeInterval = 60

    @Test("One app's series reads the (app, t) index in order, for every tier")
    func seriesUsesIndex() async throws {
        let store = try SQLiteHistoryStore.inMemory(clock: TestClock())
        for tier in HistoryTier.allCases {
            let sql = SQLiteHistoryStore.seriesSQL(metric: .cpu, tier: tier)
            let plan = try await store.database.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: ["*", 0])
                    .map { $0["detail"] as String }
            }
            #expect(plan.contains { $0.contains("USING INDEX \(tier.table)_app_t (app=? AND t>?)") }, "\(plan)")
            #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
        }
    }

    @Test("Only apps that are new or changed are upserted")
    func changedApps() {
        let a = Build.identity("a")
        let b = Build.identity("b")
        let renamed = AppIdentity(id: "a", name: "Renamed", bundleID: nil, iconKey: "new", kind: .other)
        #expect(SQLiteHistoryStore.changedApps(["a": a, "b": b], written: [:]).count == 2)
        #expect(SQLiteHistoryStore.changedApps(["a": a, "b": b], written: ["a": a, "b": b]).isEmpty)
        #expect(SQLiteHistoryStore.changedApps(["a": renamed, "b": b], written: ["a": a, "b": b]) == [renamed])
    }

    @Test("An app whose identity changes back is written again, and deleteAll forgets what was written")
    func upsertAfterChanges() async throws {
        let clock = TestClock(Build.date(10 * minute))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        let renamed = AppIdentity(id: "a", name: "Renamed", bundleID: nil, iconKey: "new", kind: .other)
        try await store.record(Build.snapshot(at: 0, apps: [Build.app("a", cpu: 1)]))
        try await store.record(Build.snapshot(at: minute, apps: [Build.app("a", cpu: 1, identity: renamed)]))
        try await store.record(Build.snapshot(at: 2 * minute, apps: [Build.app("a", cpu: 1)]))
        try await store.flush()
        #expect(try await store.topApps(metric: .cpu, range: .h12, limit: 5).map(\.app) == [Build.identity("a")])

        try await store.deleteAll()
        try await store.record(Build.snapshot(at: 3 * minute, apps: [Build.app("a", cpu: 1)]))
        try await store.flush()
        #expect(try await store.rowCount("app") == 1)
    }

    @Test("Battery health is written with each finished minute, without a flush")
    func batteryWithMinute() async throws {
        let clock = TestClock(Build.date(5 * minute))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        let battery = BatteryStats(
            percent: 80, isCharging: false, source: .battery, timeRemaining: nil,
            cycleCount: 12, maxCapacityPercent: 98, powerDrawWatts: 5
        )
        for step in 0 ..< 13 {
            try await store.record(Build.snapshot(at: Double(step * 5), battery: battery))
        }
        let day = try #require(try await store.batteryHistory(days: 1).last)
        #expect(day.maxCapacityPercent == 98)
        #expect(day.cycleCount == 12)
        #expect(day.minutesOnBattery > 0.9)
    }
}
