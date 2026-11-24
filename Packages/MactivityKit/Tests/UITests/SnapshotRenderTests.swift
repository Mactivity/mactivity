import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Renders content views to PNG in light and dark for docs/screenshots. Runs only when
/// `MACTIVITY_SNAPSHOT_DIR` is set (`make snapshots`); a normal `make test` skips it.
@MainActor
@Suite("Snapshot renders", .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct SnapshotRenderTests {
    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    private func filledMetrics() async -> LiveMetrics {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true)
        metrics.setVisible(true, surface: .mainWindow)
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< LiveMetrics.historyLength {
            await metrics.apply(source.next())
        }
        return metrics
    }

    private func write(_ view: some View, name: String, width: CGFloat) throws {
        for scheme in [ColorScheme.light, .dark] {
            let framed = view
                .padding(Tokens.Spacing.l)
                .frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @Test("Every tab's headline and secondary figures")
    func tabCards() async throws {
        let metrics = await filledMetrics()
        let snapshot = try #require(metrics.snapshot)
        for tab in MetricTab.allCases {
            let view = HStack(alignment: .top, spacing: Tokens.Spacing.gridGutter) {
                HeadlineCard(tab, metrics: metrics)
                    .frame(width: Tokens.Layout.headlineCardWidth)
                SecondaryFiguresCard(figures: tab.figures(snapshot))
            }
            .fixedSize(horizontal: false, vertical: true)
            try write(view, name: "tab-\(tab.rawValue)", width: 860)
        }
    }

    @Test("Overview headline grid")
    func overviewGrid() async throws {
        let metrics = await filledMetrics()
        let view = LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Tokens.Layout.overviewCardMinWidth), spacing: Tokens.Spacing.gridGutter)],
            spacing: Tokens.Spacing.gridGutter
        ) {
            ForEach(MetricTab.allCases) { HeadlineCard($0, metrics: metrics, compact: true) }
        }
        try write(view, name: "overview-grid", width: 1000)
    }

    @Test("Projects in the menu bar window")
    func compactProjects() async throws {
        let services = AppServices.preview()
        await services.projects.refresh()
        try write(
            CompactProjectsView(services: services).frame(width: Tokens.Layout.menuBarWindowWidth),
            name: "compact-projects",
            width: Tokens.Layout.menuBarWindowWidth + 2 * Tokens.Spacing.l
        )
    }
}
