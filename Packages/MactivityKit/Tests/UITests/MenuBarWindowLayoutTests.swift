import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Every metric tab in the menu bar window is the same height, so switching tabs doesn't make the
/// window's contents jump (CPU → GPU shifted by a point or two).
@MainActor
@Suite("Menu bar window layout")
struct MenuBarWindowLayoutTests {
    init() {
        // Doubled strings under `make test-pseudo`; English otherwise.
        _ = PseudoLocalization.isOn
        // Bigger figures under `make test-larger` (D-276).
        _ = LargerFigures.isOn
    }

    private func height(of tab: MetricTab, services: AppServices) -> CGFloat {
        let width = Tokens.Layout.menuBarWindowWidth - 2 * Tokens.Spacing.m
        // Its natural height, as the menu bar window sizes to it.
        let view = CompactMetricView(tab: tab, services: services).frame(width: width).fixedSize(horizontal: false, vertical: true)
        let controller = NSHostingController(rootView: view)
        return controller.sizeThatFits(in: CGSize(width: width, height: 2000)).height
    }

    @Test("All metric tabs share one height")
    func uniformHeight() async {
        let services = AppServices.preview()
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 10 {
            await services.metrics.apply(source.next())
        }
        let heights = Dictionary(uniqueKeysWithValues: MetricTab.allCases.map { ($0, height(of: $0, services: services)) })
        let tallest = heights.values.max() ?? 0
        // Whole points too: a fractional height puts everything below it on a half pixel.
        #expect(tallest == tallest.rounded(), "The tabs are \(tallest) pt tall, not a whole number")
        for (tab, value) in heights.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            #expect(abs(value - tallest) < 0.01, "\(tab.rawValue) is \(value) pt, the tallest tab is \(tallest) pt")
        }
    }

    /// The main window's metric pages: the headline card sets the top row's height, and the
    /// figures beside it must fit within it, so History starts at the same place on every tab.
    @Test("Main window: every tab's figures fit beside its headline card")
    func mainWindowTopRow() async {
        let services = AppServices.preview()
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 10 {
            await services.metrics.apply(source.next())
        }
        guard let snapshot = services.metrics.snapshot else {
            Issue.record("No snapshot")
            return
        }
        let width = Tokens.Layout.headlineCardWidth
        func natural(_ view: some View, width: CGFloat) -> CGFloat {
            NSHostingController(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
                .sizeThatFits(in: CGSize(width: width, height: 2000)).height
        }
        let headline = natural(HeadlineCard(.cpu, metrics: services.metrics), width: width)
        #expect(headline == headline.rounded(), "The headline card is \(headline) pt, not a whole number")
        for tab in MetricTab.allCases {
            let card = natural(HeadlineCard(tab, metrics: services.metrics), width: width)
            #expect(card == headline, "\(tab.rawValue)'s headline card is \(card) pt, CPU's is \(headline) pt")
            let figures = natural(SecondaryFiguresCard(figures: tab.figures(snapshot)).frame(maxHeight: nil), width: 560)
            #expect(figures <= headline, "\(tab.rawValue)'s figures need \(figures) pt beside a \(headline) pt headline card")
        }
    }

    /// The Overview tab's rows: every symbol sits in the same box, so the titles start at the same
    /// place and every row is the same whole-point height.
    @Test("Compact overview rows share one whole-point height")
    func overviewRows() {
        let width = Tokens.Layout.menuBarWindowWidth - 2 * Tokens.Spacing.m
        let symbols = [CompactOverview.uptimeSymbol, CompactOverview.temperatureSymbol] + MetricTab.allCases.map(\.symbol)
        let heights = symbols.map { symbol in
            NSHostingController(rootView: CompactOverviewRow(label: "Label", value: "12%", symbol: symbol).frame(width: width))
                .sizeThatFits(in: CGSize(width: width, height: 200)).height
        }
        let first = heights.first ?? 0
        #expect(first == first.rounded(), "A row is \(first) pt tall, not a whole number")
        for (symbol, height) in zip(symbols, heights) {
            #expect(height == first, "The \(symbol) row is \(height) pt, the uptime row is \(first) pt")
        }
    }

    /// Values are trailing-aligned, so a trailing space would shift one figure left of the rest.
    @Test("Compact overview values have no stray spaces")
    func overviewValues() async {
        let source = SimulatedSnapshotSource()
        let snapshot = await source.next()
        for tab in MetricTab.allCases {
            let value = CompactOverview.value(tab, snapshot)
            #expect(value == value.trimmingCharacters(in: .whitespaces), "\(tab.rawValue): \"\(value)\"")
            #expect(!value.contains("  "), "\(tab.rawValue): \"\(value)\"")
        }
    }

    /// Card titles with and without a status badge, with every metric's symbol: one height.
    @Test("Card headers are one height whatever the symbol")
    func cardHeaders() {
        let width = Tokens.Layout.menuBarWindowWidth
        let symbols = MetricTab.allCases.map(\.symbol) + [Tokens.Symbols.apps, "fan", "thermometer.medium", "battery.100percent"]
        for symbol in symbols {
            for status in [MetricStatus?.none, .normal] {
                let height = NSHostingController(rootView: CardHeader(title: "Title", symbol: symbol, status: status).frame(width: width))
                    .sizeThatFits(in: CGSize(width: width, height: 200)).height
                #expect(height == Tokens.Layout.cardHeaderHeight, "\(symbol) header is \(height) pt")
            }
        }
    }

    /// One project held 16 ports, and the row they were on widened the menu bar
    /// window's Projects page off screen.
    @Test("A project with many ports stays within the menu bar window")
    func manyPorts() async {
        struct ManyPorts: ProjectSource {
            func projects() async throws -> [Project] {
                let ports = (0 ..< 16).map { UInt16(56040 + $0) }
                let server = DevServer(
                    pid: 2207, name: "node", command: "vite", runtime: .node, ports: ports, memoryBytes: 457_000_000,
                    startedAt: Date(), cpuTime: .seconds(1), activity: .working, stopTarget: .process(2207)
                )
                return [Project(rootPath: "/Users/demo/Developer/storefront-api", name: "storefront-api", servers: [server])]
            }
        }
        let services = AppServices.preview()
        services.projects.replaceSource(ManyPorts())
        await services.projects.refresh()
        let width = Tokens.Layout.menuBarWindowWidth - 2 * Tokens.Spacing.m
        let controller = NSHostingController(rootView: CompactProjectsView(services: services).fixedSize(horizontal: false, vertical: true))
        let size = controller.sizeThatFits(in: CGSize(width: width, height: 2000))
        #expect(size.width <= width + 0.5, "The page wants \(size.width) pt in a \(width) pt window")
        #expect(ProjectText.portList([5173, 8787, 9229], limit: 2) == ":5173 :8787 +1")
        #expect(ProjectText.portList([5173], limit: 2) == ":5173")
    }
}
