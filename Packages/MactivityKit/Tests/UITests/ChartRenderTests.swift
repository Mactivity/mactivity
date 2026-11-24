import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Renders the chart-heavy pages (Overview, a metric tab with its history strip, History) with
/// simulated data, light and dark, into `MACTIVITY_SNAPSHOT_DIR`
/// (`make snapshots-charts`, into docs/screenshots/charts). Hosted in an offscreen window like
/// `StorageRenderTests`, because tables and Swift Charts' axes are AppKit underneath.
@MainActor
@Suite("Chart renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct ChartRenderTests {
    /// The detail column at the default window (1100 × 720 less the sidebar and toolbar) and at
    /// the minimum window (760 × 520).
    private static let defaultDetail = CGSize(width: 900, height: 668)
    private static let minimumDetail = CGSize(width: 580, height: 468)

    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    private func services() async -> AppServices {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true)
        metrics.setVisible(true, surface: .mainWindow)
        let source = SimulatedSnapshotSource()
        let recorded = SimulatedHistoryStore()
        for _ in 0 ..< LiveMetrics.historyLength {
            let snapshot = await source.next()
            metrics.apply(snapshot)
            try? await recorded.record(snapshot)
        }
        let servers = SimulatedDevServers()
        return AppServices(
            metrics: metrics,
            history: SimulatedThirtyDayHistory(apps: recorded, now: Date(timeIntervalSince1970: 1_790_000_000)),
            alertLog: SimulatedAlertStateStore(),
            alertSettings: .defaults,
            projects: servers,
            terminator: servers
        )
    }

    private func write(_ view: some View, name: String, size: CGSize) async throws {
        _ = NSApplication.shared
        for dark in [false, true] {
            let framed = view
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: framed)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            // Suspends (a nested run loop wouldn't), so each history strip's `.task` can load.
            try await Task.sleep(for: .seconds(1.2))
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            window.close()
        }
    }

    @Test("Overview at the default and minimum window")
    func overview() async throws {
        let services = await services()
        try await write(OverviewView(services: services), name: "overview", size: Self.defaultDetail)
        // Taller than the window, so the donut row (below the fold at this width) is in the render.
        let tall = CGSize(width: Self.minimumDetail.width, height: 760)
        try await write(OverviewView(services: services), name: "overview-minimum", size: tall)
    }

    @Test("CPU tab with its history strip, 24 h and 30 d")
    func cpuTab() async throws {
        let services = await services()
        func tab(_ range: HistoryRange) -> some View {
            MetricDetailView(tab: .cpu, services: services, range: range, search: "")
        }
        try await write(tab(.h24), name: "cpu-24h", size: Self.defaultDetail)
        try await write(tab(.d30), name: "cpu-30d", size: Self.defaultDetail)
        try await write(tab(.h24), name: "cpu-minimum", size: Self.minimumDetail)
    }

    @Test("Your day: a day of the simulated month as a timeline (D-191)")
    func yourDay() async throws {
        let services = await services()
        let day = Date(timeIntervalSince1970: 1_790_000_000 - 2 * 86400)
        let timeline = DayTimeline(services: services, day: day, generation: 0).padding(Tokens.Spacing.l)
        try await write(timeline, name: "your-day", size: CGSize(width: 760, height: 900))
    }

    @Test("A clicked moment: Top apps for that bar (D-190)")
    func rewind() async throws {
        let services = await services()
        // Inside the simulated month, which ends at 1_790_000_000.
        let start = Date(timeIntervalSince1970: 1_790_000_000 - 3 * 86400)
        let strip = HistoryStrip(tab: .cpu, range: .d30, services: services, pinned: DateInterval(start: start, duration: 6 * 3600))
        try await write(strip.padding(Tokens.Spacing.l), name: "rewind", size: CGSize(width: 1000, height: 300))
    }

    @Test("Network and Disk with today's totals (D-188)")
    func todayTotals() async throws {
        let services = await services()
        for tab in [MetricTab.network, .disk] {
            try await write(
                MetricDetailView(tab: tab, services: services, range: .h24, search: ""), name: "\(tab.rawValue)-today",
                size: Self.defaultDetail
            )
        }
    }

    @Test("History tab")
    func history() async throws {
        let services = await services()
        // The whole scrolling page, not just the first screen.
        let page = CGSize(width: Self.defaultDetail.width, height: 1500)
        let narrow = CGSize(width: Self.minimumDetail.width, height: 900)
        try await write(HistoryView(services: services, range: .h24), name: "history", size: page)
        try await write(HistoryView(services: services, range: .d7), name: "history-minimum-7d", size: narrow)
    }

    @Test("Headline cards at the menu bar window's width")
    func menuBarCards() async throws {
        let services = await services()
        let columns = [GridItem(.flexible(), spacing: Tokens.Spacing.xs), GridItem(.flexible(), spacing: Tokens.Spacing.xs)]
        let grid = LazyVGrid(columns: columns, spacing: Tokens.Spacing.xs) {
            ForEach(MetricTab.allCases) { HeadlineCard($0, metrics: services.metrics, compact: true) }
        }
        .padding(Tokens.Spacing.s)
        try await write(grid, name: "menubar-cards", size: CGSize(width: Tokens.Layout.menuBarWindowWidth, height: 640))
    }
}
