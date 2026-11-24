import Core
import Foundation
@testable import History
import Testing

/// Battery level, memory pressure, swap, free space, and data totals (D-095).
@Suite("System figures and totals")
struct SystemFiguresTests {
    @Test("Memory pressure is 100 minus the available level; figures a Mac lacks stay empty")
    func pressure() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        try await store.record(Build.snapshot(at: 0))
        try await store.flush()
        clock.set(offset: minute)
        // The test snapshots report 50% available.
        #expect(try await store.series(metric: .memoryPressure, app: nil, range: .h12).map(\.average) == [50])
        #expect(try await store.series(metric: .swapUsed, app: nil, range: .h12).map(\.average) == [0])
        #expect(try await store.series(metric: .batteryLevel, app: nil, range: .h12).isEmpty)
        #expect(try await store.series(metric: .diskFree, app: nil, range: .h12).isEmpty)
    }

    @Test("Totals are average × bucket length, summed over both directions, per app and for the Mac")
    func totals() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        // One quarter-hour at 1000 B/s in and 500 B/s out for app a; 100 B/s in for app b.
        for offset in stride(from: 0.0, to: 15 * minute, by: minute) {
            try await store.record(Build.snapshot(
                at: offset, netIn: 1100, netOut: 500,
                apps: [Build.app("a", netIn: 1000, netOut: 500), Build.app("b", netIn: 100, netOut: 0)]
            ))
        }
        try await store.record(Build.snapshot(at: 15 * minute))
        try await store.flush()
        clock.set(offset: 20 * minute)
        let totals = try await store.totals(metrics: [.netIn, .netOut], from: Build.base, to: Build.date(hour), limit: 5)
        #expect(totals.map(\.app.id) == ["a", "b"])
        #expect(abs((totals.first?.value ?? 0) - 1500 * 900) < 1)
        #expect(abs((totals.last?.value ?? 0) - 100 * 900) < 1)
        let mac = try await store.systemTotal(metrics: [.netIn, .netOut], from: Build.base, to: Build.date(hour))
        #expect(abs(mac - 1600 * 900) < 1)
    }

    @Test("A bucket counts only the minutes it covers: five minutes awake in an hour is five minutes (D-108)")
    func coveredMinutes() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        // Five minutes at 1000 B/s written, then the Mac sleeps until the next hour.
        for offset in stride(from: 0.0, to: 5 * minute, by: minute) {
            try await store.record(Build.snapshot(at: offset, diskWrite: 1000))
        }
        try await store.record(Build.snapshot(at: 70 * minute))
        try await store.record(Build.snapshot(at: 71 * minute))
        try await store.flush()
        clock.set(offset: 2 * hour)
        let quarter = try await store.systemTotal(metrics: [.diskWrite], from: Build.base, to: Build.date(hour))
        #expect(abs(quarter - 1000 * 300) < 1)
        // 40 days on, the same hour is read from the hour tier.
        clock.set(offset: 40 * 86400)
        let hourTier = try await store.systemTotal(metrics: [.diskWrite], from: Build.base, to: Build.date(hour))
        #expect(abs(hourTier - 1000 * 300) < 1)
    }
}
