import Core
import Foundation
@testable import History
import Testing

@Suite("Recording, rollups, retention")
struct RecordingTests {
    @Test("A minute stores the average and max of its snapshots, per app and system-wide")
    func minuteAverageAndMax() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        for (offset, cpu) in [(0.0, 10.0), (10, 20), (20, 60)] {
            try await store.record(Build.snapshot(at: offset, cpu: cpu * 2, apps: [Build.app("a", cpu: cpu, memory: 100)]))
        }
        try await store.record(Build.snapshot(at: minute, cpu: 5, apps: [Build.app("a", cpu: 1)]))
        clock.set(offset: minute + 5)

        let app = try await store.series(metric: .cpu, app: "a", range: .h12)
        #expect(app == [SeriesPoint(at: Build.base, average: 30, maximum: 60)])
        let system = try await store.series(metric: .cpu, app: nil, range: .h12)
        #expect(system == [SeriesPoint(at: Build.base, average: 60, maximum: 120)])
        let memory = try await store.series(metric: .memory, app: "a", range: .h12)
        #expect(memory == [SeriesPoint(at: Build.base, average: 100, maximum: 100)])
    }

    @Test("Nothing is written until a snapshot lands in the next minute")
    func minuteBoundaryWrites() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        try await store.record(Build.snapshot(at: 0, cpu: 10))
        try await store.record(Build.snapshot(at: 59.9, cpu: 30))
        #expect(try await store.rowCount("minute") == 0)

        try await store.record(Build.snapshot(at: 60, cpu: 50))
        #expect(try await store.rowTimes("minute") == [Int64(Build.base.timeIntervalSince1970)])
        #expect(try await store.series(metric: .cpu, app: nil, range: .h12).map(\.average) == [20])

        // A later minute, skipping some: the finished minute is written at its own start.
        try await store.record(Build.snapshot(at: 5 * minute + 3, cpu: 70))
        clock.set(offset: 6 * minute)
        let points = try await store.series(metric: .cpu, app: nil, range: .h12)
        #expect(points.map(\.at) == [Build.base, Build.date(minute)])
        #expect(points.map(\.average) == [20, 50])
    }

    @Test("flush() writes the minute in progress")
    func flushWritesPartialMinute() async throws {
        let clock = TestClock(Build.date(30))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        try await store.record(Build.snapshot(at: 0, diskWrite: 100))
        try await store.record(Build.snapshot(at: 5, diskWrite: 300))
        try await store.flush()
        try await store.flush()
        #expect(try await store.series(metric: .diskWrite, app: nil, range: .h24) == [
            SeriesPoint(at: Build.base, average: 200, maximum: 300),
        ])
    }

    @Test("The same minute written twice merges, weighted by sample count")
    func sameMinuteMerges() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        try await store.record(Build.snapshot(at: 0, cpu: 10, apps: [Build.app("a", gpu: nil)]))
        try await store.record(Build.snapshot(at: 5, cpu: 20, apps: [Build.app("a", gpu: nil)]))
        try await store.flush()
        try await store.record(Build.snapshot(at: 10, cpu: 60, apps: [Build.app("a", gpu: 40)]))
        try await store.flush()
        clock.set(offset: minute)

        #expect(try await store.series(metric: .cpu, app: nil, range: .h12) == [
            SeriesPoint(at: Build.base, average: 30, maximum: 60),
        ])
        #expect(try await store.series(metric: .gpu, app: "a", range: .h12) == [
            SeriesPoint(at: Build.base, average: 40, maximum: 40),
        ])
    }

    @Test("A finished quarter-hour rolls up as the average of minute averages and the max of maxes")
    func quarterRollup() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        // Minute 0: two samples (10, 20) → avg 15, max 20. Minute 1: one sample (60).
        // Average of averages is 37.5, not the sample average 30.
        try await store.record(Build.snapshot(at: 0, cpu: 10, apps: [Build.app("a", cpu: 1)]))
        try await store.record(Build.snapshot(at: 30, cpu: 20, apps: [Build.app("a", cpu: 3)]))
        try await store.record(Build.snapshot(at: minute, cpu: 60, apps: [Build.app("a", cpu: 5)]))
        try await store.record(Build.snapshot(at: 14 * minute, cpu: 40))
        #expect(try await store.rowCount("quarter") == 0)

        // The first snapshot of the next quarter writes minute 14 and completes the quarter.
        try await store.record(Build.snapshot(at: 15 * minute, cpu: 90))
        clock.set(offset: 16 * minute)
        #expect(try await store.rowCount("quarter") == 2)
        #expect(try await store.series(metric: .cpu, app: nil, range: .d7) == [
            SeriesPoint(at: Build.base, average: (15 + 60 + 40) / 3, maximum: 60),
        ])
        #expect(try await store.series(metric: .cpu, app: "a", range: .d30) == [
            SeriesPoint(at: Build.base, average: 3.5, maximum: 5),
        ])
    }

    @Test("Quarters that completed while the app wasn't running roll up on the next write")
    func quarterCatchUp() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        try await store.record(Build.snapshot(at: 0, cpu: 10))
        try await store.flush()

        clock.set(offset: 2 * hour)
        try await store.record(Build.snapshot(at: 2 * hour, cpu: 50))
        try await store.flush()
        #expect(try await store.rowTimes("quarter") == [Int64(Build.base.timeIntervalSince1970)])
        #expect(try await store.series(metric: .cpu, app: nil, range: .d7).map(\.average) == [10])
    }

    @Test("Optional metrics stay nil when never reported, and average over reported samples otherwise")
    func nilOptionalMetrics() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        let apps: [[AppAggregate]] = [
            [Build.app("a"), Build.app("b", energy: nil, gpu: nil)],
            [Build.app("a"), Build.app("b", energy: 100, gpu: 40)],
            [Build.app("a"), Build.app("b", energy: 300, gpu: 60)],
        ]
        for (index, apps) in apps.enumerated() {
            try await store.record(Build.snapshot(at: Double(index) * 5, gpu: nil, apps: apps))
        }
        try await store.flush()
        clock.set(offset: minute)

        for metric in [Metric.energy, .netIn, .netOut, .gpu] {
            #expect(try await store.series(metric: metric, app: "a", range: .h12).isEmpty)
        }
        #expect(try await store.series(metric: .gpu, app: nil, range: .h12).isEmpty)
        #expect(try await store.series(metric: .gpu, app: "b", range: .h12) == [
            SeriesPoint(at: Build.base, average: 50, maximum: 60),
        ])
        // System energy is the apps' sum per snapshot (nil, 100, 300) → average 200.
        #expect(try await store.series(metric: .energy, app: nil, range: .h12) == [
            SeriesPoint(at: Build.base, average: 200, maximum: 300),
        ])
        // System network always has a figure, even when every app's is nil.
        #expect(try await store.series(metric: .netIn, app: nil, range: .h12).count == 1)
        // Nil optional metrics stay nil through the quarter rollup too.
        try await store.record(Build.snapshot(at: 15 * minute))
        try await store.flush()
        clock.set(offset: 16 * minute)
        #expect(try await store.series(metric: .energy, app: "a", range: .d7).isEmpty)
        #expect(try await store.series(metric: .gpu, app: "b", range: .d7).map(\.average) == [50])
    }

    @Test("Retention drops minutes after 48 h and quarters after the retention, at most hourly")
    func retention() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 30)
        try await store.record(Build.snapshot(at: 0, cpu: 10))
        try await store.record(Build.snapshot(at: 15 * minute, cpu: 20))
        try await store.flush()
        #expect(try await store.rowCount("minute") == 2)
        #expect(try await store.rowCount("quarter") == 1)

        // 47.5 h: retention runs, nothing is old enough.
        clock.set(offset: 47.5 * hour)
        try await store.record(Build.snapshot(at: 47.5 * hour))
        #expect(try await store.rowTimes("minute").count == 2)

        // 48 h 10 min: minute 0 is old enough, but retention ran 40 minutes ago.
        clock.set(offset: 48 * hour + 10 * minute)
        try await store.record(Build.snapshot(at: 48 * hour + 10 * minute))
        #expect(try await store.rowTimes("minute").first == Int64(Build.base.timeIntervalSince1970))

        // 48 h 40 min: due again; minutes 0 and 15 are gone, the quarters stay.
        clock.set(offset: 48 * hour + 40 * minute)
        try await store.record(Build.snapshot(at: 48 * hour + 40 * minute))
        let minutes = try await store.rowTimes("minute")
        #expect(minutes.allSatisfy { $0 >= Int64(Build.date(47 * hour).timeIntervalSince1970) })
        #expect(try await store.rowTimes("quarter").first == Int64(Build.base.timeIntervalSince1970))

        // Lower the retention to 1 day: applied on the next record, even within the hour.
        await store.setRetention(days: 1)
        clock.set(offset: 48 * hour + 45 * minute)
        try await store.record(Build.snapshot(at: 48 * hour + 45 * minute))
        let quarters = try await store.rowTimes("quarter")
        #expect(!quarters.isEmpty)
        #expect(quarters.allSatisfy { $0 >= Int64(Build.date(24 * hour).timeIntervalSince1970) })
    }
}
