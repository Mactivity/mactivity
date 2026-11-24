import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Renders 0.9.8's new screens, light and dark, into `MACTIVITY_SNAPSHOT_DIR`
/// (`make snapshots M=features FILTER=NewFeaturesRenderTests`): the diagnosis (D-134), apps open
/// but unused (D-135), the hotspot card (D-136) and Quick Search (D-137).
@MainActor
@Suite("New features render", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct NewFeaturesRenderTests {
    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    private static func app(_ name: String, id: String) -> AppIdentity {
        AppIdentity(id: id, name: name, bundleID: id, iconKey: "other", kind: .app)
    }

    @Test("Why is my Mac slow?")
    func diagnosis() async throws {
        let chrome = Self.app("Google Chrome", id: "com.google.Chrome")
        let causes = [
            SlowdownCause(
                kind: .busyCPU, severity: .major, title: "The processor is 86% busy",
                detail: "Using the most: Google Chrome, Xcode and Spotlight.", action: .show(.cpu)
            ),
            SlowdownCause(
                kind: .busyApp, severity: .major, title: "Google Chrome is using 4.2 cores",
                detail: "If it isn't doing something you asked for, quitting it frees them.", app: chrome, action: .quit(chrome)
            ),
            SlowdownCause(
                kind: .memory, severity: .major, title: "Memory is running short",
                detail: "macOS is compressing memory and using the disk instead. Using the most: Google Chrome, Xcode and Docker.",
                action: .show(.memory)
            ),
            SlowdownCause(
                kind: .spotlight, severity: .minor, title: "Spotlight is indexing",
                detail: "It catches up after updates and new files, then stops on its own."
            ),
        ]
        try await write(
            SlowdownSheet(services: .preview(), model: SlowdownModel(causes: causes)), name: "diagnosis", size: CGSize(
                width: 560,
                height: 470
            )
        )
        try await write(
            SlowdownSheet(services: .preview(), model: SlowdownModel(causes: [])), name: "diagnosis-clear", size: CGSize(
                width: 560,
                height: 330
            )
        )
    }

    @Test("Slowdowns in the last 7 days (D-169)")
    func earlierSlowdowns() async throws {
        let calendar = Calendar.current
        let today = calendar.date(bySettingHour: 14, minute: 10, second: 0, of: Date()) ?? Date()
        let xcode = Self.app("Xcode", id: "com.apple.dt.Xcode")
        let safari = Self.app("Safari", id: "com.apple.Safari")
        let docker = Self.app("Docker", id: "com.docker.docker")
        let earlier = [
            EarlierSlowdown(
                spell: SlowSpell(
                    start: today,
                    end: today.addingTimeInterval(35 * 60),
                    causes: [.cpu, .memory],
                    peakCPU: 96,
                    peakMemoryPressure: 84
                ),
                apps: [xcode, safari, docker]
            ),
            EarlierSlowdown(
                spell: SlowSpell(
                    start: today.addingTimeInterval(-2 * 86400), end: today.addingTimeInterval(-2 * 86400 + 45 * 60),
                    causes: [.memory], peakCPU: 40, peakMemoryPressure: 88
                ),
                apps: [docker, safari]
            ),
        ]
        try await write(
            SlowdownSheet(services: .preview(), model: SlowdownModel(causes: [], earlier: earlier)),
            name: "diagnosis-earlier", size: CGSize(width: 560, height: 470)
        )
    }

    @Test("A donut's total stays inside the hole, however wide (Power by app at 888 mW)")
    func donutTotals() async throws {
        func app(_ name: String, _ milliwatts: Double, memory: UInt64) -> AppAggregate {
            AppAggregate(
                app: Self.app(name, id: name), processCount: 1, cpuPercent: 1, memoryBytes: memory, energyMW: milliwatts,
                diskReadBPS: 0, diskWriteBPS: 0, netInBPS: 0, netOutBPS: 0, gpuPercent: 0, energyImpact: 1
            )
        }
        let apps = [
            app("Mactivity", 388, memory: 9_800_000_000), app("Safari", 268, memory: 17_800_000_000),
            app("Simulator", 116, memory: 4_700_000_000), app("Xcode", 113, memory: 3_000_000_000), app("Claude", 3, memory: 600_000_000),
        ]
        let row = HStack(spacing: Tokens.Spacing.gridGutter) {
            PowerByAppCard(apps: apps)
            MemoryByAppCard(apps: apps)
        }
        .padding()
        try await write(row, name: "donut-totals", size: CGSize(width: 760, height: 260))
        try await write(row, name: "donut-totals-narrow", size: CGSize(width: 560, height: 240))
    }

    @Test("What's new after an update: Overview's line and the sheet (D-179)")
    func whatsNew() async throws {
        let text = (try? String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Packages/MactivityKit/Tests/UITests/NewFeaturesRenderTests.swift", with: "docs/releases/1.0.5.md"
        ), encoding: .utf8)) ?? "- A fix."
        let model = WhatsNewModel(pending: "1.0.6", notes: WhatsNewModel.lines(text))
        let services = AppServices.preview()
        await services.metrics.apply(SimulatedSnapshotSource().next())
        services.whatsNew = model
        try await write(OverviewView(services: services), name: "whatsnew-overview", size: CGSize(width: 900, height: 360))
        try await write(WhatsNewSheet(model: model), name: "whatsnew-sheet", size: CGSize(width: 520, height: 640))
    }

    @Test("Apps open but unused")
    func unused() async throws {
        let now = Date()
        let apps = [
            UnusedApp(
                app: Self.app("Docker Desktop", id: "com.docker.docker"),
                memoryBytes: 2_300_000_000,
                lastUsed: now - 7 * 86400,
                unusedFor: 7 * 86400
            ),
            UnusedApp(
                app: Self.app("Xcode", id: "com.apple.dt.Xcode"),
                memoryBytes: 4_100_000_000,
                lastUsed: now - 4 * 86400,
                unusedFor: 4 * 86400
            ),
            UnusedApp(
                app: Self.app("Keynote", id: "com.apple.iWork.Keynote"),
                memoryBytes: 600_000_000,
                lastUsed: nil,
                unusedFor: 12 * 86400
            ),
        ].sorted { $0.memoryBytes > $1.memoryBytes }
        try await write(
            UnusedAppsSheet(services: .preview(), model: UnusedAppsModel(apps: apps)), name: "unused-apps", size: CGSize(
                width: 520,
                height: 400
            )
        )
    }

    @Test("The hotspot card on the Network tab")
    func hotspot() async throws {
        var session = HotspotSession(start: Date().addingTimeInterval(-25 * 60))
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 30 {
            await session.add(source.next())
        }
        try await write(
            HotspotCard(model: HotspotModel(session: session)).padding(), name: "hotspot", size: CGSize(width: 640, height: 260)
        )
    }

    @Test("The Agents tab")
    func agents() async throws {
        let services = AppServices.preview()
        await services.agents.refresh()
        try await write(AgentsView(services: services), name: "agents", size: CGSize(width: 860, height: 360))
    }

    @Test("The connection line on the Network tab")
    func connection() async throws {
        let services = AppServices.preview()
        await services.networkDetails.refresh()
        let line = try #require(services.networkDetails.details.map(ConnectionCard.line))
        #expect(line == "Wi-Fi · 192.168.1.24 · Router 192.168.1.1 · Signal good (-58 dBm) · 866 Mb/s · Channel 149, 5 GHz")
        try await write(ConnectionCard(model: services.networkDetails), name: "connection", size: CGSize(width: 760, height: 60))
    }

    @Test("The browser split in an expanded app")
    func browserSplit() async throws {
        let services = AppServices.preview()
        for _ in 0 ..< 50 where services.metrics.appList == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let list = AppListView(data: services.metrics.appList, metric: .memory, search: "Code Helper", services: services)
        try await write(list, name: "browser-split", size: CGSize(width: 720, height: 260))
    }

    @Test("The menu bar window's Projects page with a 16-port project")
    func manyPorts() async throws {
        struct ManyPorts: ProjectSource {
            func projects() async throws -> [Project] {
                let server = DevServer(
                    pid: 2207, name: "node", command: "vite", runtime: .node, ports: (0 ..< 16).map { UInt16(56040 + $0) },
                    memoryBytes: 457_000_000, startedAt: Date(), cpuTime: .seconds(1), activity: .working, stopTarget: .process(2207)
                )
                return [Project(rootPath: "/Users/demo/Developer/storefront-api", name: "storefront-api", servers: [server])]
            }
        }
        let services = AppServices.preview()
        services.projects.replaceSource(ManyPorts())
        await services.projects.refresh()
        let width = Tokens.Layout.menuBarWindowWidth - 2 * Tokens.Spacing.m
        try await write(
            CompactProjectsView(services: services).padding(Tokens.Spacing.m),
            name: "menu-projects",
            size: CGSize(width: width + 32, height: 220)
        )
    }

    @Test("Drive health on the Disk tab")
    func driveHealth() async throws {
        let services = AppServices.preview()
        let line = await DriveHealthCard.line(SimulatedDriveHealth().drives()[0])
        #expect(line.hasPrefix("APPLE SSD AP1024Z · Good · 2% of rated life used"))
        let card = DriveHealthCard(services: services)
        try await write(card, name: "drive-health", size: CGSize(width: 760, height: 60))
    }

    @Test("The report PDF: two pages from simulated history")
    func reportPDF() async throws {
        let servers = SimulatedDevServers()
        let services = AppServices(
            metrics: .preview(), history: SimulatedThirtyDayHistory(apps: SimulatedHistoryStore()), alertLog: SimulatedAlertStateStore(),
            alertSettings: .defaults, projects: servers, terminator: servers
        )
        let report = await UsageReportLoader.load(services, period: .week, mac: "MacBook Pro, M5 Pro")
        #expect(report.peak != nil)
        #expect(!report.dailyCPU.isEmpty)
        let pdf = try #require(ReportPDF.data(report))
        #expect(pdf.count > 5000)
        #expect(String(bytes: pdf.prefix(5), encoding: .ascii) == "%PDF-")
        if let folder = ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] {
            try pdf.write(to: URL(fileURLWithPath: folder).appendingPathComponent("report.pdf"))
        }
    }

    @Test("The Battery tab: the Mac's figures and the Accessories card side by side")
    func batteryAccessories() async throws {
        for (name, hasBattery) in [("battery-tab-laptop", true), ("battery-tab-desktop", false)] {
            let servers = SimulatedDevServers()
            let metrics = LiveMetrics(source: SimulatedSnapshotSource(hasBattery: hasBattery), isSimulated: true)
            let services = AppServices(
                metrics: metrics, history: SimulatedHistoryStore(), alertLog: SimulatedAlertStateStore(),
                alertSettings: .defaults, projects: servers, terminator: servers
            )
            let source = SimulatedSnapshotSource(hasBattery: hasBattery)
            for _ in 0 ..< 3 {
                await metrics.apply(source.next())
            }
            let view = MetricDetailView(tab: .battery, services: services, range: .h24, search: "")
            try await write(view, name: name, size: CGSize(width: 1100, height: 330))
        }
    }

    @Test("An app's history page")
    func appHistory() async throws {
        let servers = SimulatedDevServers()
        let services = AppServices(
            metrics: .preview(), history: SimulatedThirtyDayHistory(apps: SimulatedHistoryStore()), alertLog: SimulatedAlertStateStore(),
            alertSettings: .defaults, projects: servers, terminator: servers
        )
        let xcode = AppIdentity(
            id: "com.apple.dt.Xcode",
            name: "Xcode",
            bundleID: "com.apple.dt.Xcode",
            iconKey: "/Applications/Xcode.app",
            kind: .app
        )
        services.appHistory.open(xcode)
        await services.appHistory.load(services)
        try await write(
            AppHistorySheet(services: services, model: services.appHistory),
            name: "app-history",
            size: CGSize(width: 780, height: 700)
        )
    }

    @Test("Quick Search")
    func quickSearch() async throws {
        let services = AppServices.preview()
        try await write(QuickSearchView(services: services) {}, name: "quick-search", size: CGSize(width: 560, height: 430))
        // Pages by name (D-186).
        try await write(
            QuickSearchView(services: services, query: "st") {},
            name: "quick-search-pages",
            size: CGSize(width: 560, height: 430)
        )
    }

    private static func spinRunLoop(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func write(_ view: some View, name: String, size: CGSize) async throws {
        _ = NSApplication.shared
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
}
