import Core
import Foundation
@testable import History
import Testing

/// History's year calendar, the day it opens, and CSV export (D-093).
@Suite("Days and export")
struct DailyAndExportTests {
    /// Records `cpu` for the system and app "a" through a whole hour starting `hours` after base,
    /// then flushes, so the quarter and hour tiers have it.
    private func recordHour(_ store: SQLiteHistoryStore, at hours: Double, cpu: Double) async throws {
        for quarter in 0 ..< 4 {
            let offset = hours * hour + Double(quarter) * 15 * minute
            try await store.record(Build.snapshot(at: offset, cpu: cpu, apps: [Build.app("a", cpu: cpu / 2)]))
        }
        try await store.record(Build.snapshot(at: (hours + 1) * hour, cpu: 0))
        try await store.flush()
    }

    @Test("A day's value is the mean of its hours and the highest peak")
    func dailyValues() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        try await recordHour(store, at: 0, cpu: 20)
        try await recordHour(store, at: 2, cpu: 60)
        try await recordHour(store, at: 24, cpu: 10)
        clock.set(offset: 2 * day)
        let days = try await store.dailyValues(metric: .cpu, days: 30)
        let calendar = Calendar.current
        let first = try #require(days.first { calendar.isDate($0.day, inSameDayAs: Build.base) })
        #expect(first.maximum == 60)
        #expect(days.count >= 2)
        #expect(days == days.sorted { $0.day < $1.day })
    }

    @Test("A few recent minutes rank apps by the minute (D-169)")
    func recentMinutesTopApps() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        // Minutes 5 to 9 of an hour: "b" is busy, "a" idles. The quarter they're in isn't rolled up.
        for index in 5 ..< 10 {
            try await store.record(Build.snapshot(
                at: Double(index) * minute, cpu: 90, apps: [Build.app("a", cpu: 1), Build.app("b", cpu: 80)]
            ))
        }
        try await store.record(Build.snapshot(at: 10 * minute, cpu: 10))
        clock.set(offset: 11 * minute)
        let top = try await store.topApps(metric: .cpu, from: Build.date(5 * minute), to: Build.date(10 * minute), limit: 2)
        #expect(top.map(\.app.id) == ["b", "a"])
        // The same minutes as a series, one point each (D-171).
        let series = try await store.series(metric: .cpu, app: nil, from: Build.date(5 * minute), to: Build.date(10 * minute))
        #expect(series.count == 5)
        #expect(series.allSatisfy { $0.average == 90 })
    }

    @Test("A day inside 30 days reads quarter-hours; older days read hours")
    func dayTier() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        try await recordHour(store, at: 0, cpu: 40)
        clock.set(offset: 2 * hour)
        let recent = try await store.series(metric: .cpu, app: nil, from: Build.base, to: Build.date(day))
        #expect(recent.count == 4)
        #expect(await store.tier(covering: Int64(Build.base.timeIntervalSince1970)) == .quarter)

        clock.set(offset: 40 * day)
        try await store.record(Build.snapshot(at: 40 * day))
        #expect(await store.tier(covering: Int64(Build.base.timeIntervalSince1970)) == .hour)
        let old = try await store.series(metric: .cpu, app: nil, from: Build.base, to: Build.date(day))
        // The hour recorded, and the minute at the next hour: before D-141 that last minute was
        // deleted by retention without ever being rolled up.
        #expect(old.count == 2)
        let top = try await store.topApps(metric: .cpu, from: Build.base, to: Build.date(day), limit: 5)
        #expect(top.map(\.app.id) == ["a"])
    }

    @Test("CSV: a header with units, All apps first in each hour, and quoted names")
    func exportCSV() async throws {
        let clock = TestClock()
        let store = try SQLiteHistoryStore.inMemory(clock: clock, retentionDays: 365)
        let comma = AppIdentity(id: "c", name: "Tools, Inc.", bundleID: "com.example.c", iconKey: "/c.app", kind: .app)
        for quarter in 0 ..< 4 {
            try await store.record(Build.snapshot(
                at: Double(quarter) * 15 * minute, cpu: 30,
                apps: [Build.app("a", cpu: 12), Build.app("c", cpu: 3, identity: comma)]
            ))
        }
        try await store.record(Build.snapshot(at: hour, cpu: 0))
        try await store.flush()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = try store.exportCSV(to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(rows == 3)
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("Hour starting,App,Bundle ID,CPU (%) average,CPU (%) peak,Memory (bytes) average"))
        #expect(lines[1].contains(",All apps,,30,30,"))
        #expect(lines.contains { $0.contains(",App a,com.example.a,12,12,") })
        #expect(lines.contains { $0.contains(",\"Tools, Inc.\",com.example.c,3,3,") })
    }

    @Test("CSV numbers and fields")
    func csvFormatting() {
        #expect(SQLiteHistoryStore.csvNumber(nil) == "")
        #expect(SQLiteHistoryStore.csvNumber(42) == "42")
        #expect(SQLiteHistoryStore.csvNumber(1.23456) == "1.235")
        #expect(SQLiteHistoryStore.csvNumber(.nan) == "")
        #expect(SQLiteHistoryStore.csvField("plain") == "plain")
        #expect(SQLiteHistoryStore.csvField("a \"b\"") == "\"a \"\"b\"\"\"")
    }
}
