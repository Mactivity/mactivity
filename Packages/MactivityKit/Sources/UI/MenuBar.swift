import AppKit
import Core
import SwiftUI

/// The menu bar item (spec 4.1) in all four modes.
///
/// It reads only `metrics.menuBar`, which changes at most every 15 s while no window is open,
/// so the system redraws the item rarely (D-019, D-020). Figure, graph, and
/// stacked modes render to an image whose width depends only on the settings, so the item never
/// changes width as its figures change.
public struct MenuBarLabel: View {
    private let metrics: LiveMetrics
    private let configuration: MenuBarDisplay.Configuration

    public init(
        metrics: LiveMetrics,
        mode: MenuBarMode,
        metric: MenuBarMetric,
        stacked: [MenuBarMetric],
        showsGlyph: Bool = true,
        graphShowsValue: Bool = true,
        choices: FigureChoices = .automatic
    ) {
        self.metrics = metrics
        configuration = MenuBarDisplay.Configuration(
            mode: mode, metric: metric, stacked: stacked, showsGlyph: showsGlyph, graphShowsValue: graphShowsValue,
            choices: choices
        )
    }

    public var body: some View {
        if configuration.mode == .icon {
            // Reads only `strain`, so the item redraws only when strain starts or ends.
            let strain = metrics.strain
            Image(systemName: strain == nil ? Tokens.MenuBarItem.glyph : Tokens.MenuBarItem.strainGlyph)
                .symbolEffect(.bounce, value: strain)
                .accessibilityLabel(MenuBarDisplay.iconAccessibilityText(strain: strain))
        } else {
            let reading = metrics.menuBar
            Image(nsImage: MenuBarImage.render(configuration, reading: reading))
                .accessibilityLabel(configuration.accessibilityText(reading))
        }
    }
}

/// What figure, graph, and stacked modes show; `MenuBarImage` draws it (D-067, D-069).
enum MenuBarDisplay {
    struct Configuration: Equatable {
        var mode: MenuBarMode
        var metric: MenuBarMetric
        var stacked: [MenuBarMetric]
        var showsGlyph: Bool
        var graphShowsValue: Bool
        /// What each figure shows; widths make room for the chosen texts.
        var choices: FigureChoices = .automatic

        /// Graph mode has no temperature history; it draws CPU instead (Settings doesn't offer it).
        var graphMetric: MenuBarMetric {
            metric.graphSource
        }

        var columns: [MenuBarMetric] {
            stacked.isEmpty ? [.cpu] : stacked
        }

        var width: CGFloat {
            MenuBarLayout.itemWidth(
                mode, metric: mode == .graph ? graphMetric : metric, stacked: columns,
                showsGlyph: showsGlyph, graphShowsValue: graphShowsValue, choices: choices
            )
        }

        func accessibilityText(_ reading: LiveMetrics.MenuBarReading) -> String {
            let shown = mode == .stacked ? columns : [mode == .graph ? graphMetric : metric]
            let figures = shown.map { metric in
                let value = reading.text(for: metric)
                return String(
                    localized: "\(metric.title) \(value)", bundle: .strings,
                    comment: "Menu bar item's spoken figure: a metric's name, then its value, e.g. CPU 47%"
                )
            }
            .joined(separator: ", ")
            guard let strain = reading.strain else {
                return String(
                    localized: "Mactivity, \(figures)", bundle: .strings,
                    comment: "Menu bar item's spoken label: the figures it shows, e.g. CPU 47%, Memory 82%"
                )
            }
            return String(
                localized: "Mactivity, \(figures). \(strain.description)", bundle: .strings,
                comment: "Menu bar item's spoken label under strain: its figures, then why the Mac is strained"
            )
        }
    }

    /// Icon mode's spoken label: the app's name, and why the Mac is strained if it is.
    static func iconAccessibilityText(strain: StrainReason?) -> String {
        guard let strain else {
            return "Mactivity"
        }
        return String(
            localized: "Mactivity. \(strain.description)", bundle: .strings,
            comment: "Menu bar icon's spoken label under strain, then why the Mac is strained"
        )
    }
}

/// Draws the menu bar display with AppKit text and shapes into 1x and 2x bitmaps, once per update.
/// Not SwiftUI's `ImageRenderer`: that brought up SwiftUI's
/// GPU renderer for a 100-pixel image, about 14 MB for the life of the app and brief spikes of
/// ~80 MB of graphics memory (D-069). The layout rules are `MenuBarLayout`'s.
@MainActor
enum MenuBarImage {
    static func render(_ configuration: MenuBarDisplay.Configuration, reading: LiveMetrics.MenuBarReading) -> NSImage {
        let drawing = MenuBarDrawing(configuration: configuration, reading: reading, width: configuration.width)
        let size = CGSize(width: drawing.width, height: Tokens.MenuBarItem.height)
        let image = NSImage(size: size)
        // Drawn once per update into 1x and 2x bitmaps. A drawing-handler image would redraw on
        // every menu bar redraw instead: twice the CPU when measured (D-069).
        for scale in [1.0, 2.0] {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else {
                continue
            }
            // Points, not pixels: the context then scales everything by `scale` itself.
            rep.size = size
            guard let bitmap = NSGraphicsContext(bitmapImageRep: rep) else {
                continue
            }
            let context = bitmap.cgContext
            // AppKit's bitmap context is y-up; the drawing is laid out y-down.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            drawing.draw(in: CGRect(origin: .zero, size: size), scale: scale)
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = reading.strain == nil
        return image
    }
}

/// One menu bar image's contents, drawn in a flipped context (y down) at a given scale.
struct MenuBarDrawing {
    let configuration: MenuBarDisplay.Configuration
    let reading: LiveMetrics.MenuBarReading
    let width: CGFloat

    private typealias Item = Tokens.MenuBarItem

    private var color: NSColor {
        // Template images carry alpha only: black becomes the menu bar's own text color. Under
        // strain the image keeps its color (spec 6.14).
        reading.strain == nil ? .black : .systemOrange
    }

    /// Widths of what sits side by side, in order; matches `MenuBarLayout.itemWidth`.
    private func parts(scale: CGFloat) -> [(width: CGFloat, draw: (CGRect) -> Void)] {
        var parts: [(CGFloat, (CGRect) -> Void)] = []
        if configuration.showsGlyph {
            parts.append((Item.glyphWidth, drawGlyph))
        }
        switch configuration.mode {
        case .icon:
            break
        case .figure:
            let metric = configuration.metric
            parts.append((MenuBarLayout.valueWidth(metric, .figure, choices: configuration.choices), { drawFigure(metric, in: $0) }))
        case .graph:
            parts.append((MenuBarLayout.graphWidth, { drawBars(in: $0, scale: scale) }))
            if configuration.graphShowsValue {
                let metric = configuration.graphMetric
                parts.append((MenuBarLayout.valueWidth(metric, .figure, choices: configuration.choices), { drawFigure(metric, in: $0) }))
            }
        case .stacked:
            let columns = configuration.columns
            let widths = columns.map { MenuBarLayout.columnWidth($0, choices: configuration.choices) }
            let total = widths.reduce(0, +) + CGFloat(max(0, columns.count - 1)) * Item.columnSpacing
            parts.append((total, { rect in
                var x = rect.minX
                for (metric, width) in zip(columns, widths) {
                    drawColumn(metric, in: CGRect(x: x, y: rect.minY, width: width, height: rect.height))
                    x += width + Item.columnSpacing
                }
            }))
        }
        return parts
    }

    func draw(in rect: CGRect, scale: CGFloat) {
        let parts = parts(scale: scale)
        let content = parts.map(\.width).reduce(0, +) + CGFloat(max(0, parts.count - 1)) * Item.glyphSpacing
        var x = rect.minX + (rect.width - content) / 2
        for part in parts {
            part.draw(CGRect(x: x, y: rect.minY, width: part.width, height: rect.height))
            x += part.width + Item.glyphSpacing
        }
    }

    private func drawGlyph(in rect: CGRect) {
        let name = reading.strain == nil ? Item.glyph : Item.strainGlyph
        let configuration = NSImage.SymbolConfiguration(pointSize: Item.glyphSize, weight: Item.glyphWeight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return
        }
        // Monochrome, then tinted: keeps the symbol's cut-outs (the "!" in the warning sign),
        // which a one-color palette would fill in.
        let size = symbol.size
        let color = color
        let tinted = NSImage(size: size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    private func drawFigure(_ metric: MenuBarMetric, in rect: CGRect) {
        draw(reading.text(for: metric), style: .figure, in: rect, alignment: .right, opacity: 1)
    }

    private func drawColumn(_ metric: MenuBarMetric, in rect: CGRect) {
        if MenuBarLayout.showsTwoLines(metric, choices: configuration.choices),
           let lines = reading.figures[metric]?.lines, lines.count == 2 {
            // Download over upload, left-aligned so the arrows line up.
            let top = rect.minY + (rect.height - 2 * Item.lineRow) / 2
            for (index, line) in lines.enumerated() {
                let row = CGRect(x: rect.minX, y: top + CGFloat(index) * Item.lineRow, width: rect.width, height: Item.lineRow)
                draw(line, style: .line, in: row, alignment: .left, opacity: 1)
            }
            return
        }
        let top = rect.minY + (rect.height - Item.labelRow - Item.valueRow) / 2
        draw(
            metric.shortTitle,
            style: .label,
            in: CGRect(x: rect.minX, y: top, width: rect.width, height: Item.labelRow),
            alignment: .center,
            opacity: Item.labelOpacity
        )
        draw(
            reading.text(for: metric),
            style: .value,
            in: CGRect(x: rect.minX, y: top + Item.labelRow, width: rect.width, height: Item.valueRow),
            alignment: .center,
            opacity: 1
        )
    }

    /// One line of text, vertically centered in `rect`.
    private func draw(_ text: String, style: MenuBarLayout.Style, in rect: CGRect, alignment: NSTextAlignment, opacity: Double) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        let string = NSAttributedString(string: text, attributes: [
            .font: style.font,
            .foregroundColor: color.withAlphaComponent(opacity),
            .paragraphStyle: paragraph,
        ])
        let height = ceil(string.size().height)
        string.draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
    }

    private func drawBars(in rect: CGRect, scale: CGFloat) {
        let metric = configuration.graphMetric
        let values = reading.graph[metric] ?? []
        let fractions = MenuBarLayout.bars(values, count: Item.barCount, top: MenuBarLayout.graphTop(metric, values: values))
        let bottom = rect.midY + Item.barHeight / 2
        color.setFill()
        for (index, fraction) in fractions.enumerated() {
            guard let fraction else {
                continue
            }
            let height = MenuBarLayout.barHeight(fraction, maxHeight: Item.barHeight, minimum: Item.barMinimum, scale: max(1, scale))
            let x = rect.minX + CGFloat(index) * (Item.barWidth + Item.barGap)
            CGRect(x: x, y: bottom - height, width: Item.barWidth, height: height).fill()
        }
    }
}

/// The menu bar window (spec 4.2): Overview plus one tab per metric, then Open and Quit. The
/// window is glass from the system; cards inside sit on solid surfaces (charts never on glass).
public struct MenuBarContent: View {
    private let services: AppServices
    private let mainWindowID: String
    @Binding private var isSimulated: Bool

    @State private var tab: CompactTab = .overview
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(PreferenceKey.settingsTab) private var settingsTab: SettingsTab = .general
    @AppStorage(PreferenceKey.perAppVolume) private var perAppVolume = false
    @State private var audio = PerAppAudioModel()

    public init(services: AppServices, isSimulated: Binding<Bool>, mainWindowID: String) {
        self.init(services: services, isSimulated: isSimulated, mainWindowID: mainWindowID, tab: .overview)
    }

    /// Open on a tab: render tests.
    init(services: AppServices, isSimulated: Binding<Bool>, mainWindowID: String, tab: CompactTab) {
        _tab = State(initialValue: tab)
        self.services = services
        _isSimulated = isSimulated
        self.mainWindowID = mainWindowID
    }

    public var body: some View {
        content
            .font(Tokens.Typography.windowDefault)
            .padding(Tokens.Spacing.s)
            .frame(width: Tokens.Layout.menuBarWindowWidth)
            // SwiftUI keeps a closed menu bar window's views, still observing every snapshot,
            // as it does the main window's (D-055); drop them while it's closed (D-086).
            .releasedWhileHidden()
            .onAppear { services.metrics.setVisible(true, surface: .menuBarWindow) }
            .onDisappear { services.metrics.setVisible(false, surface: .menuBarWindow) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Picker(String(localized: "Tab", bundle: .strings, comment: "The menu bar window's tab picker"), selection: $tab) {
                let hasBattery = services.metrics.hardware.hasBattery
                ForEach(CompactTab.allCases) { tab in
                    Image(systemName: tab.symbol(hasBattery: hasBattery))
                        .help(tab.title(hasBattery: hasBattery))
                        .accessibilityLabel(tab.title(hasBattery: hasBattery))
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // ⌘1–⌘8 pick a tab, as ⌘1–⌘9 pick the main window's pages (D-197).
            .background {
                ForEach(Array(CompactTab.allCases.enumerated()), id: \.element) { index, item in
                    Button("") { tab = item }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        .hidden()
                }
            }

            Group {
                if tab == .projects {
                    CompactProjectsView(services: services)
                } else if let metricTab = tab.metricTab {
                    CompactMetricView(tab: metricTab, services: services)
                } else {
                    CompactOverview(services: services, select: { tab = $0 }, edit: { showSettings(.menuBar) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            MenuBarNotices(services: services) {
                services.navigation.selection = .checkup
                openWindow(id: mainWindowID, value: mainWindowID)
                NSApplication.shared.activate()
            }

            // Per-app volume (M10): only with the flag on and something playing.
            if perAppVolume, !audio.rows.isEmpty {
                CompactVolumeSection(model: audio, metrics: services.metrics)
            }

            // A recording runs on with the main window closed: say so here, with the way to stop it (D-196).
            if services.recording.isRecording {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text("Recording activity", bundle: .strings, comment: "Menu bar window: a CSV recording is running")
                        .font(Tokens.Typography.secondary)
                    Spacer(minLength: Tokens.Spacing.xs)
                    RecordingIndicator(model: services.recording)
                        .controlSize(.small)
                }
            }

            #if DEBUG
                Toggle(String(localized: "Simulated data", bundle: .strings), isOn: $isSimulated)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            #endif

            Divider()

            // Chrome, not content: the footer's controls are glass, like a toolbar's. Full labels
            // when they fit; "Quit" and "Open" when not (the cup and the gauge, or longer
            // languages), never a label cut off mid-word.
            ViewThatFits(in: .horizontal) {
                footer(full: true)
                footer(full: false)
            }
        }
        .task(id: perAppVolume) {
            if perAppVolume {
                await audio.poll { services.audio }
            }
        }
    }

    private func footer(full: Bool) -> some View {
        HStack {
            Button(full ? String(localized: "Quit Mactivity", bundle: .strings) : String(localized: "Quit", bundle: .strings)) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .fixedSize()
            .help(Text("Quit Mactivity", bundle: .strings))
            Spacer()
            KeepAwakeMenu(model: services.keepAwake)
            Button {
                openWindow(id: mainWindowID, value: mainWindowID)
                NSApplication.shared.activate()
                services.slowdown.open(services)
            } label: {
                Image(systemName: "gauge.with.needle")
            }
            .help(Text("Why is my Mac slow?", bundle: .strings))
            .accessibilityLabel(Text("Why is my Mac slow?", bundle: .strings))
            // Click for Settings; the menu offers the Menu Bar pane directly.
            Menu {
                Button(String(localized: "Customize Menu Bar…", bundle: .strings)) { showSettings(.menuBar) }
                Button(String(localized: "Your Next Mac…", bundle: .strings)) {
                    openWindow(id: mainWindowID, value: mainWindowID)
                    NSApplication.shared.activate()
                    services.nextMac.open()
                }
                // Where testers look first; the Help menu has it too (D-179).
                if let feedback = FeedbackDraft.url(services: services) {
                    Divider()
                    Button(String(localized: "Send Feedback…", bundle: .strings)) { NSWorkspace.shared.open(feedback) }
                }
            } label: {
                Image(systemName: "gearshape")
            } primaryAction: {
                showSettings(nil)
            }
            // ⌘, as everywhere on the Mac (D-197); a hidden button, since a menu's primary action
            // doesn't take a shortcut.
            .background {
                Button("") { showSettings(nil) }
                    .keyboardShortcut(",")
                    .hidden()
            }
            .menuStyle(.button)
            .menuIndicator(.visible)
            .fixedSize()
            .help(Text("Settings", bundle: .strings))
            .accessibilityLabel(Text("Settings", bundle: .strings))
            Button(full ? String(localized: "Open Mactivity", bundle: .strings) : String(localized: "Open", bundle: .strings)) {
                services.navigation.selection = tab.sidebarItem
                openWindow(id: mainWindowID, value: mainWindowID)
                NSApplication.shared.activate()
            }
            .keyboardShortcut("o")
            .buttonStyle(.glassProminent)
            .fixedSize()
            .help(Text("Open Mactivity", bundle: .strings))
        }
        .buttonStyle(.glass)
    }

    /// Opens Settings, on `pane` if given, else where the user left it.
    private func showSettings(_ pane: SettingsTab?) {
        if let pane {
            settingsTab = pane
        }
        openSettings()
        NSApplication.shared.activate()
    }
}
