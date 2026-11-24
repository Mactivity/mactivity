import Core
import Foundation
@testable import History
import Testing

@Suite("Persistence, alerts, lifecycle")
struct PersistenceTests {
    /// A fresh directory under the temporary directory, removed by `cleanUp`.
    private static func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MactivityHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlite")
    }

    private static func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("A damaged history file is moved aside, never deleted, and a fresh one starts")
    func damagedFile() async throws {
        let url = try Self.temporaryDatabaseURL()
        defer { Self.cleanUp(url) }
        try Data(repeating: 0x42, count: 8192).write(to: url)
        #expect(throws: (any Error).self) { try SQLiteHistoryStore(url: url) }

        let store = try SQLiteHistoryStore.openRecovering(url: url)
        try await store.record(Build.snapshot(at: 0, cpu: 10, apps: [Build.app("a", cpu: 10)]))
        try await store.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let damaged = files.filter { $0.hasPrefix("history-damaged-") && $0.hasSuffix(".sqlite") }
        #expect(damaged.count == 1)
        let kept = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(#require(damaged.first)))
        #expect(kept == Data(repeating: 0x42, count: 8192))
    }

    @Test("The command line reads a history file without its WAL files, and still writes nothing (D-202)")
    func readWithAppQuit() async throws {
        let url = try Self.temporaryDatabaseURL()
        defer { Self.cleanUp(url) }
        let now = Date()
        let app = try SQLiteHistoryStore(url: url)
        try await app.recordPowerEvent(PowerEvent(at: now.addingTimeInterval(-60), kind: .wake, reason: "lid"))
        try app.database.close()
        // Closed, then the side files gone, as in a copy or a restore of the history file alone.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        let reader = try SQLiteHistoryStore.openReadOnly(url: url)
        #expect(try await reader.powerEvents(days: 1).count == 1)
        await #expect(throws: (any Error).self) {
            try await reader.recordPowerEvent(PowerEvent(at: now, kind: .sleep))
        }
        #expect(try await reader.powerEvents(days: 1).count == 1)
        // No history at all: nothing is created.
        let missing = url.deletingLastPathComponent().appendingPathComponent("none.sqlite")
        #expect(throws: (any Error).self) { try SQLiteHistoryStore.openReadOnly(url: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("File databases flush at checkpoints, not every commit (synchronous = NORMAL)")
    func synchronousNormal() async throws {
        let url = try Self.temporaryDatabaseURL()
        defer { Self.cleanUp(url) }
        let store = try SQLiteHistoryStore(url: url)
        #expect(try await store.synchronousLevel() == 1)
    }

    @Test("History survives closing and reopening the store (relaunch)")
    func relaunch() async throws {
        let url = try Self.temporaryDatabaseURL()
        defer { Self.cleanUp(url) }
        let clock = TestClock()

        var first: SQLiteHistoryStore? = try SQLiteHistoryStore(url: url, now: { clock.now })
        try await first?.record(Build.snapshot(at: 0, cpu: 10, apps: [Build.app("a", cpu: 4)]))
        try await first?.record(Build.snapshot(at: minute, cpu: 20, apps: [Build.app("a", cpu: 6)]))
        try await first?.record(Build.snapshot(at: minute + 5, cpu: 40, apps: [Build.app("a", cpu: 6)]))
        // Quit in the middle of minute 1.
        try await first?.flush()
        #expect(await (first?.storageSizeBytes() ?? 0) > 0)
        first = nil

        // Relaunch inside minute 1, then run into the next quarter.
        clock.set(offset: 20 * minute)
        let second = try SQLiteHistoryStore(url: url, now: { clock.now })
        try await second.record(Build.snapshot(at: minute + 10, cpu: 90, apps: [Build.app("a", cpu: 6)]))
        try await second.record(Build.snapshot(at: 16 * minute, cpu: 0))
        try await second.flush()

        // Minute 1 merged both sessions: (20 + 40 + 90) / 3 = 50.
        #expect(try await second.series(metric: .cpu, app: nil, range: .h12) == [
            SeriesPoint(at: Build.base, average: 10, maximum: 10),
            SeriesPoint(at: Build.date(minute), average: 50, maximum: 90),
            SeriesPoint(at: Build.date(16 * minute), average: 0, maximum: 0),
        ])
        let week = try await second.series(metric: .cpu, app: nil, range: .d7)
        #expect(week == [
            SeriesPoint(at: Build.base, average: 30, maximum: 90),
        ])
        // Over every recorded sample (1 + 3 + 1): (4 + 6 × 3) / 5, with minute 16 counting as 0.
        let top = try await second.topApps(metric: .cpu, range: .h12, limit: 1)
        #expect(top.map(\.app.id) == ["a"])
        #expect(abs((top.first?.value ?? 0) - 4.4) < 0.0001)
    }

    @Test("A file store runs in WAL mode and reports its size")
    func walAndSize() async throws {
        let url = try Self.temporaryDatabaseURL()
        defer { Self.cleanUp(url) }
        let store = try SQLiteHistoryStore(url: url, now: { Build.base })
        let mode = try await store.database.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
        #expect(await store.storageSizeBytes() > 0)

        let memory = try SQLiteHistoryStore(url: nil)
        #expect(await memory.storageSizeBytes() == 0)
    }

    @Test("Alert state round-trips, and saving replaces every row")
    func alertStateRoundTrip() async throws {
        let store = try SQLiteHistoryStore.inMemory(clock: TestClock())
        #expect(try await store.loadAlertState() == AlertState())

        let state = AlertState(lastFired: [
            AlertKey(appID: "a", rule: .highCPU): Build.date(0.5),
            AlertKey(appID: "a", rule: .growingMemory): Build.date(120),
            AlertKey(appID: "b", rule: .heavyNetwork): Build.date(-3 * day),
        ])
        try await store.saveAlertState(state)
        #expect(try await store.loadAlertState() == state)

        let smaller = AlertState(lastFired: [AlertKey(appID: "c", rule: .heavyDisk): Build.date(60)])
        try await store.saveAlertState(smaller)
        #expect(try await store.loadAlertState() == smaller)
    }

    @Test("Alert state survives relaunch")
    func alertStatePersists() async throws {
        let url = try Self.temporaryDatabaseURL()
        defer { Self.cleanUp(url) }
        let state = AlertState(lastFired: [AlertKey(appID: "a", rule: .highCPU): Build.date(42)])
        try await SQLiteHistoryStore(url: url).saveAlertState(state)
        #expect(try await SQLiteHistoryStore(url: url).loadAlertState() == state)
    }

    @Test("The alert log round-trips every field, newest first, and keeps the newest 500")
    func alertLog() async throws {
        let store = try SQLiteHistoryStore.inMemory(clock: TestClock())
        let terminal = AppIdentity(
            id: "com.apple.Terminal", name: "Terminal", bundleID: "com.apple.Terminal", iconKey: "t", kind: .terminal
        )
        let alerts = [
            Alert(
                rule: .highCPU, app: Build.identity("a"), firedAt: Build.date(10),
                title: "A is busy", body: "Averaging 92% for 10 minutes."
            ),
            Alert(rule: .growingMemory, app: .system, firedAt: Build.date(30), title: "macOS", body: "Up 1.4 GB in an hour, now 3.3 GB."),
            Alert(rule: .heavyNetwork, app: terminal, firedAt: Build.date(20), title: "Terminal", body: "12 MB/s down."),
        ]
        for alert in alerts {
            try await store.recordAlert(alert)
        }
        #expect(try await store.recentAlerts(limit: 10) == [alerts[1], alerts[2], alerts[0]])
        #expect(try await store.recentAlerts(limit: 2) == [alerts[1], alerts[2]])
        #expect(try await store.recentAlerts(limit: 0).isEmpty)

        for index in 0 ..< 505 {
            try await store.recordAlert(Alert(
                rule: .heavyDisk, app: Build.identity("d"), firedAt: Build.date(1000 + Double(index)),
                title: "Disk \(index)", body: ""
            ))
        }
        #expect(try await store.rowCount("alert_log") == SQLiteHistoryStore.alertLogLimit)
        let recent = try await store.recentAlerts(limit: 1000)
        #expect(recent.count == 500)
        #expect(recent.first?.title == "Disk 504")
        #expect(recent.last?.title == "Disk 5")
    }

    @Test("deleteAll clears every tier, the apps, the alert tables, and the minute in progress")
    func deleteAll() async throws {
        let clock = TestClock(Build.date(20 * minute))
        let store = try SQLiteHistoryStore.inMemory(clock: clock)
        try await store.record(Build.snapshot(at: 0, cpu: 10, apps: [Build.app("a", cpu: 1)]))
        try await store.record(Build.snapshot(at: 15 * minute, cpu: 10, apps: [Build.app("a", cpu: 1)]))
        try await store.flush()
        try await store.record(Build.snapshot(at: 16 * minute, cpu: 10))
        try await store.saveAlertState(AlertState(lastFired: [AlertKey(appID: "a", rule: .highCPU): Build.base]))
        try await store.recordAlert(Alert(rule: .highCPU, app: Build.identity("a"), firedAt: Build.base, title: "t", body: "b"))
        for table in ["minute", "quarter", "app", "alert_state", "alert_log"] {
            #expect(try await store.rowCount(table) > 0)
        }

        try await store.deleteAll()
        try await store.flush()
        for table in ["minute", "quarter", "app", "alert_state", "alert_log"] {
            #expect(try await store.rowCount(table) == 0)
        }
        #expect(try await store.series(metric: .cpu, app: nil, range: .h12).isEmpty)
        #expect(try await store.recentAlerts(limit: 10).isEmpty)
    }
}
