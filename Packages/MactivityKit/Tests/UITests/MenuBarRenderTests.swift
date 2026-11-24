import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Renders the menu bar item in every mode, normal and under strain, on a stand-in menu bar in
/// light and dark, plus Settings → Menu Bar and the menu bar window, into `MACTIVITY_SNAPSHOT_DIR`
/// (`make snapshots M=menubar FILTER=MenuBarRenderTests`).
@MainActor
@Suite("Menu bar renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct MenuBarRenderTests {
    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    /// Two minutes of simulated samples, so graphs have bars and every figure has a value.
    private func filledMetrics() async -> LiveMetrics {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true)
        metrics.setVisible(true, surface: .mainWindow)
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< LiveMetrics.historyLength {
            await metrics.apply(source.next())
        }
        return metrics
    }

    private struct Row {
        let title: String
        let configuration: MenuBarDisplay.Configuration
    }

    private var rows: [Row] {
        func row(
            _ title: String, _ mode: MenuBarMode, _ metric: MenuBarMetric = .cpu, stacked: [MenuBarMetric] = [],
            glyph: Bool = true, value: Bool = true, choices: FigureChoices = .automatic
        ) -> Row {
            Row(title: title, configuration: .init(
                mode: mode, metric: metric, stacked: stacked, showsGlyph: glyph, graphShowsValue: value, choices: choices
            ))
        }
        let chosen = FigureChoices(memory: .used, network: .both, battery: .timeLeft)
        return [
            row("Icon", .icon),
            row("Figure · CPU", .figure),
            row("Figure · Network, no symbol", .figure, .network, glyph: false),
            row("Graph · CPU", .graph),
            row("Graph · Network, bars only", .graph, .network, value: false),
            row("Stacked · CPU, MEM", .stacked, stacked: [.cpu, .memory]),
            row("Stacked · four", .stacked, stacked: [.cpu, .memory, .gpu, .network]),
            row("Stacked · four, no symbol", .stacked, stacked: [.cpu, .memory, .network, .temperature], glyph: false),
            row("Figure · Network both ways", .figure, .network, choices: chosen),
            row("Figure · Battery % and time", .figure, .battery, choices: FigureChoices(battery: .percentAndTime)),
            row("Stacked · GB used, both ways, time", .stacked, stacked: [.cpu, .memory, .network, .battery], choices: chosen),
        ]
    }

    @Test("Every mode, normal and under strain, at 2x and 1x")
    func modes() async throws {
        let metrics = await filledMetrics()
        var reading = metrics.menuBar
        reading.set(.temperature, value: 58)
        var strained = reading
        strained.strain = .cpu
        strained.set(.cpu, value: 96)
        // Rows with figure choices draw those choices' figures from the latest sample.
        func shown(_ base: LiveMetrics.MenuBarReading, _ choices: FigureChoices) -> LiveMetrics.MenuBarReading {
            guard choices != .automatic, let system = metrics.snapshot?.system else {
                return base
            }
            var reading = base
            for metric in [MenuBarMetric.memory, .network, .battery] {
                reading.figures[metric] = MenuBarLayout.figure(metric, system, choices: choices)
            }
            return reading
        }
        for scale in [2.0, 1.0] {
            for dark in [false, true] {
                let sheet = Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.m, verticalSpacing: Tokens.Spacing.s) {
                    GridRow {
                        Text("")
                        Text("Normal").font(.headline)
                        Text("Under strain").font(.headline)
                    }
                    ForEach(rows, id: \.title) { row in
                        GridRow {
                            Text(row.title).font(.callout).foregroundStyle(.secondary)
                            FakeMenuBar(dark: dark) { item(row.configuration, shown(reading, row.configuration.choices)) }
                            FakeMenuBar(dark: dark) { item(row.configuration, shown(strained, row.configuration.choices)) }
                        }
                    }
                }
                .padding(Tokens.Spacing.l)
                .background(dark ? Color(white: 0.1) : Color(white: 0.98))
                .environment(\.colorScheme, dark ? .dark : .light)
                let suffix = scale == 1 ? "-1x" : ""
                try writeImage(sheet, scale: scale, name: "menubar-modes\(suffix)-\(dark ? "dark" : "light")")
            }
        }
    }

    @Test("The reference: stacked CPU and MEM, close up")
    func reference() async throws {
        let metrics = await filledMetrics()
        var reading = metrics.menuBar
        reading.set(.cpu, value: 47)
        reading.set(.memory, value: 82)
        let config = MenuBarDisplay.Configuration(
            mode: .stacked, metric: .cpu, stacked: [.cpu, .memory], showsGlyph: true, graphShowsValue: true
        )
        for dark in [false, true] {
            let view = FakeMenuBar(dark: dark) { item(config, reading) }
                .environment(\.colorScheme, dark ? .dark : .light)
            try writeImage(view, scale: 4, name: "menubar-stacked-closeup-\(dark ? "dark" : "light")")
        }
    }

    @Test("Settings → Menu Bar in each mode")
    func settings() async throws {
        let defaults = UserDefaults.standard
        let keys = [PreferenceKey.menuBarMode, PreferenceKey.menuBarMetric, PreferenceKey.menuBarStackedMetrics]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set("cpu,memory,network", forKey: PreferenceKey.menuBarStackedMetrics)
        defaults.set("cpu", forKey: PreferenceKey.menuBarMetric)
        let metrics = await filledMetrics()
        for mode in MenuBarMode.allCases {
            defaults.set(mode.rawValue, forKey: PreferenceKey.menuBarMode)
            let height: CGFloat = mode == .stacked ? 560 : 400
            try await host(
                MenuBarSettings(metrics: metrics),
                name: "settings-\(mode.rawValue)",
                size: CGSize(width: Tokens.Layout.settingsWidth, height: height)
            )
        }
    }

    @Test("The menu bar window's footer: Settings with Customize Menu Bar…")
    func window() async throws {
        let services = AppServices.preview()
        await services.metrics.apply(SimulatedSnapshotSource().next())
        let window = MenuBarContent(services: services, isSimulated: .constant(true), mainWindowID: "main")
        try await host(window, name: "menubar-window", size: CGSize(width: Tokens.Layout.menuBarWindowWidth, height: 720))
    }

    @Test("Every tab of the menu bar window")
    func windowTabs() async throws {
        _ = PseudoLocalization.isOn
        let services = AppServices.preview()
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 10 {
            await services.metrics.apply(source.next())
        }
        await services.projects.refresh()
        for tab in CompactTab.allCases {
            let window = MenuBarContent(services: services, isSimulated: .constant(true), mainWindowID: "main", tab: tab)
            try await host(
                window,
                name: "menubar-window-\(tab.rawValue)",
                size: CGSize(width: Tokens.Layout.menuBarWindowWidth, height: 720)
            )
        }
    }

    // MARK: Drawing

    /// The item as the menu bar shows it: a template image takes the bar's text color.
    @ViewBuilder
    private func item(_ configuration: MenuBarDisplay.Configuration, _ reading: LiveMetrics.MenuBarReading) -> some View {
        if configuration.mode == .icon {
            Image(systemName: reading.strain == nil ? Tokens.MenuBarItem.glyph : Tokens.MenuBarItem.strainGlyph)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(reading.strain == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Tokens.Colors.strain))
        } else {
            let image = MenuBarImage.render(configuration, reading: reading)
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .foregroundStyle(.primary)
        }
    }

    private func writeImage(_ view: some View, scale: CGFloat, name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// Lets AppKit lay out and draw. Synchronous: `RunLoop.run` isn't available from async code.
    private static func spinRunLoop(seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Forms, pickers, and toggles are AppKit underneath, which `ImageRenderer` can't draw, so
    /// these go through an offscreen window.
    private func host(_ view: some View, name: String, size: CGSize) async throws {
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
            try await Task.sleep(for: .milliseconds(300))
            Self.spinRunLoop(seconds: 0.3)
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            window.close()
        }
    }
}

/// A slice of the menu bar: Finder's menus on the left, the item among system extras on the right.
private struct FakeMenuBar<Item: View>: View {
    let dark: Bool
    @ViewBuilder let item: Item

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo")
            Text("Finder").fontWeight(.bold)
            Text("File")
            Text("Edit")
            Spacer(minLength: Tokens.Spacing.l)
            item
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Tue 14:32")
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .padding(.horizontal, Tokens.Spacing.s)
        .frame(width: 600, height: 24)
        .background(dark ? Color(white: 0.17) : Color(white: 0.9))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}
