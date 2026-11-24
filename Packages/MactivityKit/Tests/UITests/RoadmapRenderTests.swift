import AppKit
import Core
import Docker
import Projects
import Simulated
import Storage
import SwiftUI
import Testing
@testable import UI

/// The next update's new views (D-205 on), from made-up figures. Renders into `MACTIVITY_SNAPSHOT_DIR`.
@MainActor
@Suite("Roadmap renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct RoadmapRenderTests {
    @Test("Battery health by month")
    func batteryMonths() throws {
        let calendar = Calendar.current
        let months = (0 ..< 6).reversed().compactMap { back -> BatteryMonth? in
            guard let month = calendar.date(byAdding: .month, value: -back, to: calendar.startOfDay(for: Date())) else {
                return nil
            }
            let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
            return BatteryMonth(month: start, capacityPercent: 94 - Double(5 - back) * 0.6, cycles: 18 + back)
        }
        try write(
            BatteryMonthsTable(months: months.reversed(), forecast: BatteryHealthLine.forecast(26)),
            name: "battery-months", width: 360
        )
    }

    @Test("After updates")
    func afterUpdates() throws {
        func app(_ name: String, _ id: String) -> AppIdentity {
            AppIdentity(id: id, name: name, bundleID: id, iconKey: "other", kind: .app)
        }
        let day: TimeInterval = 86400
        let now = Date()
        let chrome = InstalledUpdate(
            app: app("Google Chrome", "com.google.Chrome"),
            name: "Google Chrome",
            version: "155.0.8059.40",
            installedAt: now - 9 * day
        )
        let macOS = InstalledUpdate(app: nil, name: "macOS", version: "27.0.1", installedAt: now - 16 * day)
        let onePassword = InstalledUpdate(
            app: app("1Password", "com.1password.1password"),
            name: "1Password",
            version: "8.12.40",
            installedAt: now - 6 * day
        )
        let claude = InstalledUpdate(
            app: app("Claude", "com.anthropic.claudefordesktop"),
            name: "Claude",
            version: "2.42304.0",
            installedAt: now
        )
        let model = UpdatesModel(
            impacts: [
                UpdateImpact(update: chrome, daysBefore: 6, daysAfter: 5, changes: [.init(metric: .memory, before: 1.2e9, after: 1.6e9)]),
                UpdateImpact(update: macOS, daysBefore: 4, daysAfter: 5, changes: [.init(metric: .energy, before: 3400, after: 2600)]),
                UpdateImpact(
                    update: onePassword,
                    daysBefore: 7,
                    daysAfter: 4,
                    changes: [.init(metric: .memory, before: 3.4e8, after: 2.9e8)]
                ),
            ],
            waiting: [claude]
        )
        try write(AfterUpdatesCard(services: .preview(), model: model).padding(Tokens.Spacing.l), name: "after-updates", width: 760)
    }

    @Test("Compare two days")
    func compare() async throws {
        func app(_ name: String, _ id: String) -> AppIdentity {
            AppIdentity(id: id, name: name, bundleID: id, iconKey: "other", kind: .app)
        }
        let xcode = app("Xcode", "com.apple.dt.Xcode"), safari = app("Safari", "com.apple.Safari"), docker = app(
            "Docker",
            "com.docker.docker"
        )
        var first = CompareModel.Side(
            inUse: 6.2 * 3600, slowdowns: 2, alerts: 3, cpu: 14.2, memory: 21e9, power: 6400, received: 3.1e9, sent: 4.2e8, written: 1.8e10
        )
        first.apps = [
            .cpu: [AppTotal(app: xcode, value: 22), AppTotal(app: docker, value: 9)],
            .memory: [AppTotal(app: safari, value: 5.5e9)],
        ]
        var second = CompareModel.Side(
            inUse: 4.8 * 3600, slowdowns: 0, alerts: 1, cpu: 8.1, memory: 17e9, power: 4100, received: 1.2e9, sent: 3e8, written: 6e9
        )
        second.apps = [.cpu: [AppTotal(app: xcode, value: 6)], .memory: [AppTotal(app: safari, value: 1.4e9)]]
        let today = Calendar.current.startOfDay(for: Date())
        let model = CompareModel(first: today, second: today - 86400, sides: (first, second))
        try await writeInWindow(CompareSheet(services: .preview(), model: model), name: "compare", size: CGSize(width: 720, height: 620))
    }

    @Test("What grew, on Storage")
    func whatGrew() async throws {
        let scanner = SimulatedStorageScanner()
        let model = StorageModel(scanner: scanner)
        let scan = scanner.makeScan()
        model.finish(scan)
        let home = scan.root.path
        model.show(growth: [
            FolderGrowth(
                path: home + "/Library/Developer/Xcode/DerivedData",
                before: 10_000_000_000,
                after: 19_200_000_000,
                grew: 9_200_000_000
            ),
            FolderGrowth(path: home + "/Downloads", before: 5_000_000_000, after: 8_100_000_000, grew: 3_100_000_000),
            FolderGrowth(path: home + "/Movies/Final Cut Projects", before: nil, after: 1_400_000_000, grew: 1_400_000_000),
        ], since: Date().addingTimeInterval(-6 * 86400))
        let view = StorageView(model: model, confirmedAction: ConfirmedAction(terminator: SimulatedDevServers()))
        try await writeInWindow(view, name: "what-grew", size: CGSize(width: 960, height: 760))
        try await writeInWindow(view.frame(width: 640), name: "what-grew-narrow", size: CGSize(width: 640, height: 760))
    }

    @Test("Build times")
    func buildTimes() throws {
        let now = Date()
        func last(_ seconds: Double, ago: Double, _ project: String, _ tool: String) -> BuildRun {
            BuildRun(start: now - ago - seconds, end: now - ago, project: project, tool: tool, averageCPU: 60, peakMemory: 1)
        }
        let model = BuildsModel(projects: [
            ProjectBuilds(
                project: "Mactivity",
                tool: "Swift",
                count: 46,
                last: last(95, ago: 1200, "Mactivity", "Swift"),
                recentMedian: 92,
                earlierMedian: 58
            ),
            ProjectBuilds(
                project: "engine",
                tool: "Rust",
                count: 18,
                last: last(212, ago: 7200, "engine", "Rust"),
                recentMedian: 205,
                earlierMedian: 210
            ),
            ProjectBuilds(
                project: "storefront-web",
                tool: "C and C++",
                count: 9,
                last: last(14, ago: 86400 * 2, "storefront-web", "C and C++"),
                recentMedian: 12,
                earlierMedian: 31
            ),
            ProjectBuilds(
                project: "pipeline",
                tool: "Go",
                count: 2,
                last: last(41, ago: 86400 * 5, "pipeline", "Go"),
                recentMedian: nil,
                earlierMedian: nil
            ),
        ])
        try write(BuildTimesCard(services: .preview(), model: model).padding(Tokens.Spacing.l), name: "build-times", width: 760)
    }

    @Test("Flagged by macOS")
    func flagged() throws {
        let now = Date()
        let reports = [
            MacReport(
                id: "a",
                at: now - 3 * 86400,
                kind: .diskWrites(bytes: 137.44e9, seconds: 11410),
                process: "Google Chrome Helper",
                ownerBundleID: nil,
                path: "/a"
            ),
            MacReport(
                id: "b",
                at: now - 4 * 86400,
                kind: .diskWrites(bytes: 34.36e9, seconds: 5217),
                process: "node",
                ownerBundleID: nil,
                path: "/b"
            ),
            MacReport(id: "c", at: now - 5 * 86400, kind: .memoryKill, process: "Safari", ownerBundleID: nil, path: "/c"),
            MacReport(id: "d", at: now - 6 * 86400, kind: .panic(summary: "panic(cpu 3)"), process: nil, ownerBundleID: nil, path: "/d"),
        ]
        try write(FlaggedCard(services: .preview(), generation: 0, sample: reports).padding(Tokens.Spacing.l), name: "flagged", width: 860)
    }

    private static func spinRunLoop(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Through a window, for views ImageRenderer leaves blank: scroll views, segmented pickers.
    func writeInWindow(_ view: some View, name: String, size: CGSize) async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
        for dark in [false, true] {
            let framed = view
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: framed)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(600))
            Self.spinRunLoop(seconds: 0.4)
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            window.close()
        }
    }

    func write(_ content: some View, name: String, width: CGFloat) throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
        for scheme in [ColorScheme.light, .dark] {
            let view = content
                .frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
