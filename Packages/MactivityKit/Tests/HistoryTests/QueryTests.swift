import Core
import Foundation
@testable import History
import Testing

@Suite("Queries")
struct QueryTests {
    @Test("Ranges up to 24 h read minutes, 7 d and 30 d read quarters, oldest first, within the range")
    func seriesTierSelection() async throws {
        let clock = TestClock()
        clock.set(offset: 13 * hour + 5 * minute)
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        for (offset, cpu) in [(0.0, 10.0), (minute, 20), (13 * hour, 30), (13 * hour + minute, 40)] {
            try await store.record(Build.snapshot(at: offset, cpu: cpu))
        }
        try await store.flush()

        let h12 = try await store.series(metric: .cpu, app: nil, range: .h12)
        #expect(h12.map(\.at) == [Build.date(13 * hour), Build.date(13 * hour + minute)])
        #expect(h12.map(\.average) == [30, 40])

        let h24 = try await store.series(metric: .cpu, app: nil, range: .h24)
        #expect(h24.map(\.average) == [10, 20, 30, 40])
        #expect(h24.map(\.at) == h24.map(\.at).sorted())

        // Only the first quarter is complete; the 13:00 quarter is still in progress.
        for range in [HistoryRange.d7, .d30] {
            #expect(try await store.series(metric: .cpu, app: nil, range: range) == [
                SeriesPoint(at: Build.base, average: 15, maximum: 20),
            ])
        }
        #expect(try await store.series(metric: .cpu, app: "missing", range: .h24).isEmpty)
    }

    @Test("Top apps: highest average over the whole range first, limited, never the system-wide row")
    func topApps() async throws {
        let clock = TestClock(Build.date(20 * minute))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        let terminal = AppIdentity(
            id: "com.mitchellh.ghostty", name: "Ghostty", bundleID: "com.mitchellh.ghostty", iconKey: "g", kind: .terminal
        )
        try await store.record(Build.snapshot(at: 0, cpu: 99, apps: [
            Build.app("a", cpu: 10), Build.app("b", cpu: 30, gpu: 5), Build.app("c", cpu: 20),
        ]))
        try await store.record(Build.snapshot(at: minute, cpu: 99, apps: [
            Build.app("a", cpu: 10), Build.app("b", cpu: 50, gpu: 7), Build.app("t", cpu: 1, identity: terminal),
        ]))
        try await store.flush()

        let top = try await store.topApps(metric: .cpu, range: .h12, limit: 2)
        // c ran for one of the two samples: 20% then, 10% over the range, tied with a.
        #expect(top == [AppTotal(app: Build.identity("b"), value: 40), AppTotal(app: Build.identity("a"), value: 10)])

        let all = try await store.topApps(metric: .cpu, range: .h24, limit: 10)
        #expect(all.map(\.app.id) == ["b", "a", "c", terminal.id])
        #expect(all.last?.app == terminal)
        #expect(!all.contains { $0.app.id == "*" })

        #expect(try await store.topApps(metric: .gpu, range: .h12, limit: 10).map(\.app.id) == ["b"])
        #expect(try await store.topApps(metric: .cpu, range: .h12, limit: 0).isEmpty)
        #expect(try await store.topApps(metric: .cpu, range: .d7, limit: 10).isEmpty)

        // Once the quarter is rolled up, 7 d reads it.
        try await store.record(Build.snapshot(at: 15 * minute))
        try await store.flush()
        let week = try await store.topApps(metric: .cpu, range: .d7, limit: 1)
        #expect(week == [AppTotal(app: Build.identity("b"), value: 40)])
    }

    @Test("An app's identity is the latest one recorded")
    func identityUpsert() async throws {
        let clock = TestClock(Build.date(5 * minute))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        let renamed = AppIdentity(id: "a", name: "Renamed", bundleID: nil, iconKey: "new", kind: .other)
        try await store.record(Build.snapshot(at: 0, apps: [Build.app("a", cpu: 1)]))
        try await store.record(Build.snapshot(at: minute, apps: [Build.app("a", cpu: 1, identity: renamed)]))
        try await store.flush()
        #expect(try await store.topApps(metric: .cpu, range: .h12, limit: 5).map(\.app) == [renamed])
    }

    @Test("Totals are Σ average × seconds covered over the system-wide series (D-108)")
    func total() async throws {
        let clock = TestClock(Build.date(20 * minute))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        #expect(try await store.total(metric: .diskWrite, range: .h24) == 0)

        try await store.record(Build.snapshot(at: 0, diskWrite: 500, apps: [Build.app("a", diskWrite: 1_000_000)]))
        try await store.record(Build.snapshot(at: 30, diskWrite: 1500))
        try await store.record(Build.snapshot(at: minute, diskWrite: 3000, netIn: 10))
        try await store.flush()

        #expect(try await store.total(metric: .diskWrite, range: .h24) == (1000 + 3000) * 60)
        #expect(try await store.total(metric: .netIn, range: .h12) == 10 * 60)
        #expect(try await store.total(metric: .diskWrite, range: .d7) == 0)

        try await store.record(Build.snapshot(at: 15 * minute, diskWrite: 0))
        try await store.flush()
        // The quarter's average is the average of its two minutes, and it covers those two
        // minutes, not the whole quarter-hour: the same total the minute tier gives.
        #expect(try await store.total(metric: .diskWrite, range: .d7) == 2000 * 120)
    }

    @Test("Previous period: the same-length window just before the range, and nothing inside it")
    func previousPeriod() async throws {
        let clock = TestClock(Build.date(13 * hour + 20 * minute))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        try await store.record(Build.snapshot(at: 0, cpu: 50, apps: [Build.app("a", cpu: 10), Build.app("b", cpu: 30)]))
        try await store.record(Build.snapshot(at: 13 * hour, cpu: 50, apps: [Build.app("a", cpu: 20), Build.app("c", cpu: 5)]))
        try await store.flush()

        let now = try await store.topApps(metric: .cpu, range: .h12, limit: 10)
        #expect(now.map(\.app.id) == ["a", "c"])
        let before = try await store.topAppsInPreviousPeriod(metric: .cpu, range: .h12, limit: 10)
        #expect(before == [AppTotal(app: Build.identity("b"), value: 30), AppTotal(app: Build.identity("a"), value: 10)])

        let changes = PeriodChange.changes(current: now, previous: before)
        #expect(changes["a"] == .relative(1))
        #expect(changes["c"] == .new)
    }

    @Test("Compacts only when over half the file is free and that's at least 2 MB")
    func compactThreshold() {
        #expect(SQLiteHistoryStore.shouldCompact(pages: 2000, freePages: 1500, pageSize: 4096))
        #expect(!SQLiteHistoryStore.shouldCompact(pages: 2000, freePages: 900, pageSize: 4096))
        // Mostly free but tiny: not worth rewriting the file.
        #expect(!SQLiteHistoryStore.shouldCompact(pages: 100, freePages: 90, pageSize: 4096))
        #expect(!SQLiteHistoryStore.shouldCompact(pages: 0, freePages: 0, pageSize: 4096))
    }
}
