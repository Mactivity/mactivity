import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Renders Focus streaks, Busiest hours, Battery temperature and Chargers compared into
/// `MACTIVITY_SNAPSHOT_DIR`, with simulated data and empty, off screen. With
/// `MACTIVITY_LARGER_FIGURES=1`, also the pages Larger changes most (D-276).
@MainActor
@Suite("Habits and battery renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct HabitsRenderTests {
    private static let defaultDetail = CGSize(width: 900, height: 668)
    private static let minimumDetail = CGSize(width: 580, height: 468)

    init() {
        _ = LargerFigures.isOn
    }

    private var suffix: String {
        LargerFigures.isOn ? "-larger" : ""
    }

    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    private func services() async -> AppServices {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true)
        metrics.setVisible(true, surface: .mainWindow)
        let source = SimulatedSnapshotSource(hasBattery: true)
        let recorded = SimulatedHistoryStore()
        for _ in 0 ..< LiveMetrics.historyLength {
            let snapshot = await source.next()
            metrics.apply(snapshot)
            try? await recorded.record(snapshot)
        }
        let servers = SimulatedDevServers()
        return AppServices(
            metrics: metrics,
            history: SimulatedThirtyDayHistory(apps: recorded, now: Date()),
            alertLog: SimulatedAlertStateStore(),
            alertSettings: .defaults,
            projects: servers,
            terminator: servers
        )
    }

    private func write(_ view: some View, name: String, size: CGSize, dark: Bool = false) async throws {
        _ = NSApplication.shared
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
        try await Task.sleep(for: .seconds(1.2))
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name)\(suffix)-\(dark ? "dark" : "light").png"))
        window.close()
    }

    @Test("The new cards with data, wide and narrow, light and dark")
    func cards() async throws {
        let services = await services()
        let history = try #require(services.history as? SimulatedThirtyDayHistory)
        for (label, width) in [("wide", 852.0), ("narrow", 532.0)] {
            for dark in [false, true] where label == "wide" || !dark {
                let size = CGSize(width: width, height: 560)
                try await write(
                    BusiestHoursCard(store: history, generation: 0).padding(), name: "busiest-\(label)", size: size, dark: dark
                )
                try await write(
                    FocusStreaksCard(store: history, generation: 0).padding(), name: "streaks-\(label)", size: size, dark: dark
                )
                try await write(
                    BatteryTemperatureCard(services: services, range: .d7).padding(), name: "temperature-\(label)", size: size, dark: dark
                )
                try await write(
                    ChargersComparedCard(store: history, generation: 0).padding(), name: "chargers-\(label)", size: size, dark: dark
                )
            }
        }
    }

    @Test("The empty states: nothing recorded yet")
    func empty() async throws {
        let empty = EmptyHabitsStore()
        let size = CGSize(width: 852, height: 240)
        try await write(BusiestHoursCard(store: empty, generation: 0).padding(), name: "busiest-empty", size: size)
        try await write(FocusStreaksCard(store: empty, generation: 0).padding(), name: "streaks-empty", size: size)
        try await write(ChargersComparedCard(store: empty, generation: 0).padding(), name: "chargers-empty", size: size)
    }

    @Test("The pages Larger changes most")
    func pages() async throws {
        let services = await services()
        for (tab, name) in [(MetricTab.cpu, "cpu"), (.battery, "battery"), (.memory, "memory")] {
            try await write(
                MetricDetailView(tab: tab, services: services, range: .d7, search: ""), name: "page-\(name)", size: Self.defaultDetail
            )
            try await write(
                MetricDetailView(tab: tab, services: services, range: .d7, search: ""),
                name: "page-\(name)-minimum", size: Self.minimumDetail
            )
        }
        try await write(OverviewView(services: services), name: "page-overview", size: Self.defaultDetail)
        try await write(OverviewView(services: services), name: "page-overview-minimum", size: CGSize(width: 580, height: 760))
        try await write(HistoryView(services: services, range: .d7), name: "page-history", size: CGSize(width: 900, height: 2400))
        for tab in [CompactTab.overview, .cpu, .battery] {
            try await write(
                MenuBarContent(services: services, isSimulated: .constant(true), mainWindowID: "main", tab: tab),
                name: "menubar-\(tab.id)", size: CGSize(width: Tokens.Layout.menuBarWindowWidth, height: 760)
            )
        }
    }
}

/// A store that has recorded nothing yet.
private actor EmptyHabitsStore: HourRhythmStore, ChargerHistoryStore, FocusStore {
    func wholeMacHours(from _: Date, to _: Date) async throws -> [HourSample] {
        []
    }

    func chargerUse(days _: Int) async throws -> [ChargerUse] {
        []
    }

    func recordFocus(_: AppIdentity, from _: Date, to _: Date) async throws {}

    func focusTotals(from _: Date, to _: Date, limit _: Int) async throws -> [AppTotal] {
        []
    }

    func activeSeconds(from _: Date, to _: Date) async throws -> Double {
        0
    }

    func firstFocus() async throws -> Date? {
        nil
    }

    func lastFocus() async throws -> [AppIdentity.ID: Date] {
        [:]
    }

    func focusStretches(from _: Date, to _: Date) async throws -> [FocusStretch] {
        []
    }
}
