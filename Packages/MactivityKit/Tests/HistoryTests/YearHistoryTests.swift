import Core
import Foundation
import GRDB
@testable import History
import Testing

/// A year of history (D-089): hours rolled up from quarter-hours, quarter-hours kept 30 days,
/// hours kept for the retention setting.
@Suite("A year of history")
struct YearHistoryTests {
    @Test("A finished hour rolls up as the average of quarter averages and the max of maxes")
    func hourRollup() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        try await store.record(Build.snapshot(at: 0, cpu: 10, apps: [Build.app("a", cpu: 1)]))
        try await store.record(Build.snapshot(at: 15 * minute, cpu: 30, apps: [Build.app("a", cpu: 3)]))
        try await store.record(Build.snapshot(at: 45 * minute, cpu: 50, apps: [Build.app("a", cpu: 8)]))
        #expect(try await store.rowCount("hour") == 0)

        // The first snapshot of the next hour writes minute 45, completing its quarter and the hour.
        try await store.record(Build.snapshot(at: hour, cpu: 90))
        try await store.flush()
        clock.set(offset: hour + minute)
        #expect(try await store.rowTimes("hour") == [Int64(Build.base.timeIntervalSince1970)])
        #expect(try await store.series(metric: .cpu, app: nil, range: .d90) == [
            SeriesPoint(at: Build.base, average: 30, maximum: 50),
        ])
        #expect(try await store.series(metric: .cpu, app: "a", range: .y1) == [
            SeriesPoint(at: Build.base, average: 4, maximum: 8),
        ])
    }

    @Test("Hours missing after the upgrade fill in from the quarter-hours already kept")
    func backfill() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        for offset in stride(from: 0, through: 3 * hour, by: 15 * minute) {
            try await store.record(Build.snapshot(at: offset, cpu: 20))
        }
        try await store.flush()
        #expect(try await store.rowCount("hour") == 3)

        // As after the v4 migration: quarters, no hours.
        try await store.database.write { try $0.execute(sql: "DELETE FROM hour") }
        try await store.record(Build.snapshot(at: 3 * hour + minute, cpu: 20))
        try await store.flush()
        #expect(try await store.rowCount("hour") == 3)
    }

    @Test("Quarter-hours stop at 30 days, hours stay for the retention setting")
    func retention() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        try await store.record(Build.snapshot(at: 0, cpu: 10))
        try await store.record(Build.snapshot(at: hour, cpu: 10))
        try await store.flush()
        let base = Int64(Build.base.timeIntervalSince1970)
        #expect(try await store.rowTimes("quarter").first == base)
        #expect(try await store.rowTimes("hour") == [base])

        clock.set(offset: 31 * day)
        try await store.record(Build.snapshot(at: 31 * day, cpu: 10))
        #expect(try await store.rowTimes("quarter").allSatisfy { $0 >= base + Int64(day) })
        #expect(try await store.rowTimes("hour").first == base)

        // Down to 30 days: the hours go too.
        await store.setRetention(days: 30)
        clock.set(offset: 31 * day + minute)
        try await store.record(Build.snapshot(at: 31 * day + minute, cpu: 10))
        #expect(try await store.rowTimes("hour").allSatisfy { $0 >= base + Int64(day) })
    }

    @Test("The period before 30 days reads hours, since quarter-hours are gone by then")
    func previousPeriodReadsHours() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        try await store.record(Build.snapshot(at: 0, apps: [Build.app("a", cpu: 40)]))
        try await store.record(Build.snapshot(at: hour))
        try await store.flush()

        clock.set(offset: 45 * day)
        try await store.record(Build.snapshot(at: 45 * day))
        try await store.flush()
        #expect(try await store.rowCount("quarter") < 5)
        let before = try await store.topAppsInPreviousPeriod(metric: .cpu, range: .d30, limit: 5)
        #expect(before.map(\.app.id) == ["a"])
        // Two minutes were recorded (0 and the hour's), "a" ran in one at 40%. The hour's minute
        // was lost to the 45-day gap before it was rolled up (D-141); now it counts.
        #expect(before.first?.value == 20)
    }

    @Test("A row stamped in the future (a clock set ahead and back) doesn't stop rollups (D-141)")
    func futureRow() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        let future = Int64(Build.base.timeIntervalSince1970) + 400 * 86400
        try await store.database.write { db in
            try db.execute(sql: """
            INSERT INTO quarter (t, app, samples, minutes, cpuAvg, cpuMax, memoryAvg, memoryMax, diskReadAvg, diskReadMax,
                diskWriteAvg, diskWriteMax) VALUES (?, '*', 1, 1, 0, 0, 0, 0, 0, 0, 0, 0)
            """, arguments: [future])
            try db.execute(sql: "INSERT INTO hour (t, app, samples, minutes) VALUES (?, '*', 1, 1)", arguments: [future])
        }
        for offset in stride(from: 0, through: 2 * hour, by: 15 * minute) {
            clock.set(offset: offset)
            try await store.record(Build.snapshot(at: offset, cpu: 20))
        }
        try await store.flush()
        // Real quarters and hours rolled up, and the future rows are gone.
        #expect(try await store.rowTimes("quarter").contains(Int64(Build.base.timeIntervalSince1970)))
        #expect(try await store.rowTimes("hour").contains(Int64(Build.base.timeIntervalSince1970)))
        #expect(try await !store.rowTimes("hour").contains(future))
    }

    @Test("Ranges read the tier that fits them")
    func tiers() {
        #expect(HistoryRange.allCases.map { HistoryTier(range: $0) } == [.minute, .minute, .quarter, .quarter, .hour, .hour])
    }
}
