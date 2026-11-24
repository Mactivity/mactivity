import AppKit
import Core
import Export
import Simulated
import SwiftUI
import Testing
@testable import UI

@Suite("Year calendar (D-093)")
struct YearCalendarTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        calendar.firstWeekday = 1
        return calendar
    }()

    @Test("A year of days, one each, ending today, in week columns")
    func layout() throws {
        let today = Date(timeIntervalSince1970: 1_790_600_000)
        let layout = YearCalendarLayout(today: today, calendar: calendar, width: 800)
        #expect(layout.cells.count == 365)
        #expect(Set(layout.cells.map(\.day)).count == 365)
        let last = try #require(layout.cells.max { $0.day < $1.day })
        #expect(calendar.isDate(last.day, inSameDayAs: today))
        #expect(last.column == YearCalendarLayout.columns - 1)
        #expect(last.row == calendar.component(.weekday, from: today) - 1)
        #expect(layout.cells.allSatisfy { (0 ..< 7).contains($0.row) && (0 ..< YearCalendarLayout.columns).contains($0.column) })
        #expect(layout.monthLabels.count >= 11)
    }

    @Test("Hit testing finds the square under the pointer, and nothing in the gaps' margins")
    func hitTesting() throws {
        let layout = YearCalendarLayout(today: Date(timeIntervalSince1970: 1_790_600_000), calendar: calendar, width: 800)
        let cell = try #require(layout.cells.first { $0.column == 10 && $0.row == 3 })
        let rect = layout.rect(cell)
        #expect(layout.day(at: CGPoint(x: rect.midX, y: rect.midY)) == cell.day)
        #expect(layout.day(at: CGPoint(x: 2, y: 2)) == nil)
    }

    @Test("Squares top out at 14 points, and the year always fits the width, ring included")
    func sizing() {
        let today = Date(timeIntervalSince1970: 1_790_600_000)
        #expect(YearCalendarLayout(today: today, calendar: calendar, width: 5000).side == 14)
        for width in [420.0, 480, 560, 800] {
            let layout = YearCalendarLayout(today: today, calendar: calendar, width: width)
            let right = layout.cells.map { layout.rect($0).maxX }.max() ?? 0
            #expect(right + 1 <= width, "width \(width): last square ends at \(right)")
        }
    }

    @Test("Four levels by quarters of the busiest day")
    func levels() {
        #expect(YearCalendarCard.level(0, maximum: 100) == 1)
        #expect(YearCalendarCard.level(25, maximum: 100) == 1)
        #expect(YearCalendarCard.level(26, maximum: 100) == 2)
        #expect(YearCalendarCard.level(75, maximum: 100) == 3)
        #expect(YearCalendarCard.level(100, maximum: 100) == 4)
        #expect(YearCalendarCard.level(5, maximum: 0) == 1)
    }

    @Test("Disk and Network add both directions at each time")
    func sums() {
        let at = Date(timeIntervalSince1970: 1_790_600_000)
        let read = [SeriesPoint(at: at, average: 1, maximum: 2), SeriesPoint(at: at + 900, average: 3, maximum: 4)]
        let write = [SeriesPoint(at: at, average: 10, maximum: 20)]
        #expect(YearCalendarCard.sum([read, write]) == [
            SeriesPoint(at: at, average: 11, maximum: 22),
            SeriesPoint(at: at + 900, average: 3, maximum: 4),
        ])
        #expect(YearCalendarCard.sum([read]) == read)
    }
}

/// `make snapshots M=calendar FILTER=YearCalendarRenderTests`.
@MainActor
@Suite("Year calendar renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct YearCalendarRenderTests {
    private static func spinRunLoop(seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test("The card with a simulated year, light and dark")
    func render() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
        let store = SimulatedThirtyDayHistory(apps: SimulatedHistoryStore())
        let size = CGSize(width: 880, height: 420)
        for dark in [false, true] {
            let view = YearCalendarCard(store: store, generation: 0)
                .padding(Tokens.Spacing.l)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            for _ in 0 ..< 4 {
                try await Task.sleep(for: .milliseconds(300))
                Self.spinRunLoop(seconds: 0.3)
                hosting.layoutSubtreeIfNeeded()
            }
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("year-calendar-\(dark ? "dark" : "light").png"))
            window.close()
        }
    }
}

/// `make snapshots M=devices FILTER=DeviceBatteryRenderTests`.
@MainActor
@Suite("Accessory renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct DeviceBatteryRenderTests {
    private static func spinRunLoop(seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test("The Accessories card over 7 days, dark")
    func render() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
        let store = SimulatedThirtyDayHistory(apps: SimulatedHistoryStore())
        let size = CGSize(width: 880, height: 300)
        let view = DeviceBatteryCard(store: store, range: .d7, generation: 0)
            .padding(Tokens.Spacing.l)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        for _ in 0 ..< 4 {
            try await Task.sleep(for: .milliseconds(300))
            Self.spinRunLoop(seconds: 0.3)
            hosting.layoutSubtreeIfNeeded()
        }
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("accessories-dark.png"))
        window.close()
    }
}

@MainActor
@Suite("Sleep renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct SleepRenderTests {
    private static func spinRunLoop(seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test("The Sleep card with a simulated week, dark")
    func render() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
        let store = SimulatedThirtyDayHistory(apps: SimulatedHistoryStore())
        let size = CGSize(width: 880, height: 520)
        let view = SleepCard(store: store, blockers: SimulatedSleepBlockers(), generation: 0)
            .padding(Tokens.Spacing.l)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        for _ in 0 ..< 4 {
            try await Task.sleep(for: .milliseconds(300))
            Self.spinRunLoop(seconds: 0.3)
            hosting.layoutSubtreeIfNeeded()
        }
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("sleep-dark.png"))
        window.close()
    }
}

@MainActor
@Suite("Disk activity renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct DiskActivityRenderTests {
    private static func spinRunLoop(seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test("The Disk tab's totals card, dark")
    func render() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
        let services = AppServices.preview()
        let apps = SimulatedHistoryStore()
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 5 {
            let snapshot = await source.next()
            await services.metrics.apply(snapshot)
            try await apps.record(snapshot)
        }
        services.replaceStores(history: SimulatedThirtyDayHistory(apps: apps), alertLog: SimulatedAlertStateStore())
        let size = CGSize(width: 900, height: 200)
        let view = DiskActivityCard(services: services)
            .padding(Tokens.Spacing.l)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        for _ in 0 ..< 4 {
            try await Task.sleep(for: .milliseconds(300))
            Self.spinRunLoop(seconds: 0.3)
            hosting.layoutSubtreeIfNeeded()
        }
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("disk-activity-dark.png"))
        window.close()
    }
}

@Suite("Crashes card")
struct CrashesCardTests {
    @Test("Grouped by app, most first, with the latest report's time and file")
    func grouping() {
        let now = Date(timeIntervalSince1970: 1_790_600_000)
        let reports = [
            CrashReport(id: "a", at: now, appName: "Safari", bundleID: nil, kind: .hang, path: "/safari-latest"),
            CrashReport(id: "b", at: now - 60, appName: "Xcode", bundleID: nil, kind: .crash, path: "/xcode-latest"),
            CrashReport(id: "c", at: now - 120, appName: "Xcode", bundleID: nil, kind: .crash, path: "/xcode-old"),
            CrashReport(id: "d", at: now - 180, appName: "Xcode", bundleID: nil, kind: .hang, path: "/xcode-older"),
        ]
        let apps = CrashesCard.byApp(reports)
        #expect(apps.map(\.name) == ["Xcode", "Safari"])
        #expect(apps.first?.crashes == 2)
        #expect(apps.first?.hangs == 1)
        #expect(apps.first?.path == "/xcode-latest")
    }
}

@MainActor
@Suite("Battery use renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct BatteryUseRenderTests {
    private static func spinRunLoop(seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test("The Battery tab's use card, dark")
    func render() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
        let services = AppServices.preview()
        let apps = SimulatedHistoryStore()
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 5 {
            let snapshot = await source.next()
            await services.metrics.apply(snapshot)
            try await apps.record(snapshot)
        }
        services.replaceStores(history: SimulatedThirtyDayHistory(apps: apps), alertLog: SimulatedAlertStateStore())
        let size = CGSize(width: 900, height: 260)
        let view = BatteryUseList(services: services, span: .range, range: .h24)
            .padding(Tokens.Spacing.l)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        for _ in 0 ..< 4 {
            try await Task.sleep(for: .milliseconds(300))
            Self.spinRunLoop(seconds: 0.3)
            hosting.layoutSubtreeIfNeeded()
        }
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("battery-use-dark.png"))
        window.close()
    }
}

@MainActor
@Suite("Checkup renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct CheckupRenderTests {
    private static func spinRunLoop(seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test("Checkup with simulated data, dark")
    func render() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
        let services = AppServices.preview()
        let apps = SimulatedHistoryStore()
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 5 {
            let snapshot = await source.next()
            await services.metrics.apply(snapshot)
            try await apps.record(snapshot)
        }
        services.replaceStores(history: SimulatedThirtyDayHistory(apps: apps), alertLog: SimulatedAlertStateStore())
        let size = CGSize(width: 880, height: 640)
        let view = CheckupView(services: services)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        for _ in 0 ..< 6 {
            try await Task.sleep(for: .milliseconds(300))
            Self.spinRunLoop(seconds: 0.3)
            hosting.layoutSubtreeIfNeeded()
        }
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("checkup-dark.png"))
        window.close()
    }
}

@MainActor
@Suite("Your week renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct YourWeekRenderTests {
    @Test("The shared image of a week, light and dark")
    func render() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
        let end = Date(timeIntervalSince1970: 1_790_553_600)
        func app(_ id: String, _ name: String, _ path: String) -> AppIdentity {
            AppIdentity(id: id, name: name, bundleID: id, iconKey: path, kind: .app)
        }
        let report = WeeklyReport(
            start: end - 7 * 86400, end: end, activeSeconds: 38.5 * 3600, previousActiveSeconds: 34 * 3600,
            topApps: [
                AppTotal(app: app("com.apple.dt.Xcode", "Xcode", "/Applications/Xcode.app"), value: 16 * 3600),
                AppTotal(app: app("com.apple.Safari", "Safari", "/Applications/Safari.app"), value: 9 * 3600),
                AppTotal(app: app("com.apple.Terminal", "Terminal", "/System/Applications/Utilities/Terminal.app"), value: 5 * 3600),
            ],
            averageSleepSeconds: 7.2 * 3600, dataBytes: 42e9, writtenBytes: 380e9, crashes: 3,
            busiestDay: end - 5 * 86400, charges: 6
        )
        for scheme in [ColorScheme.light, .dark] {
            let png = try #require(ImageExport.pngData(
                of: WeeklyImageView(report: report),
                width: WeeklyImageView.width,
                colorScheme: scheme
            ))
            try png.write(to: directory.appendingPathComponent("your-week-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}

@Suite("Energy shares (D-105)")
struct EnergySharesTests {
    @Test("Each app's share of the total, in percent")
    func shares() {
        let apps = [("a", 30.0), ("b", 10.0), ("c", 0.0)].map {
            AppTotal(app: AppIdentity(id: $0.0, name: $0.0, bundleID: nil, iconKey: "other", kind: .other), value: $0.1)
        }
        #expect(HistoryStrip.shares(apps).map(\.value) == [75, 25, 0])
        #expect(HistoryStrip.shares([]).isEmpty)
    }
}
