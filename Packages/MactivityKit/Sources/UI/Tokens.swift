import AppKit
import Core
import SwiftUI

/// Design tokens (spec 10.3). No view uses a raw number or a raw color; add a token instead.
public enum Tokens {

    // MARK: Color

    public enum Colors {
        /// The user's system accent. An in-app override (spec 13, question 4) would replace this.
        public static let accent = Color.accentColor

        /// Status colors are for status words and the strain badge only. Never red: red is
        /// reserved for Force Quit (spec 10.2).
        public static func status(_ status: MetricStatus) -> Color {
            switch status {
            case .normal: .green
            case .elevated: .yellow
            case .critical: .orange
            }
        }

        /// A ring around a status dot where the fill alone is too faint: yellow on a light card
        /// always, and every dot under Increase Contrast. Nil means no ring.
        public static func statusOutline(_ status: MetricStatus, _ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color? {
            let isFaint = status == .elevated && scheme == .light
            guard isFaint || contrast == .increased else {
                return nil
            }
            return Self.status(status).mix(with: scheme == .light ? .black : .white, by: contrast == .increased ? 0.45 : 0.3)
        }

        /// Strain tint for the menu bar figure (spec 6.14).
        public static let strain = Color.orange

        /// Charts take their metric's color, the same one as its sidebar symbol
        /// (`MetricTab.tint`, D-057). This is for charts without a metric.
        public static let chartDefault = accent
        /// A history bar's peak, drawn behind its average.
        public static func chartPeak(_ tint: Color) -> Color {
            tint.opacity(0.3)
        }

        /// Second series in a history strip (reads, uploads, GPU temperature).
        public static func chartSecondary(_ tint: Color) -> Color {
            tint.opacity(0.5)
        }

        /// The rounded track behind a sparkline's bars.
        public static func chartTrack(_ tint: Color, _ contrast: ColorSchemeContrast) -> Color {
            tint.opacity(contrast == .increased ? 0.2 : 0.1)
        }

        /// Donut and category colors, in order. System colors, so both appearances work.
        /// In another palette from Settings → Customize, its own colors (D-240).
        public static var series: [Color] {
            let palette = Customization.shared.palette
            guard palette != .standard else {
                return [accent, .purple, .pink, .teal, .indigo]
            }
            return [MetricTab.cpu, .memory, .gpu, .network, .disk].map(palette.color)
        }

        /// "Free" and "Everything else" slices.
        public static func seriesRemainder(_ contrast: ColorSchemeContrast) -> Color {
            Color.secondary.opacity(contrast == .increased ? 0.6 : 0.35)
        }

        /// A row's background for the one-time pulse after a notification deep link.
        public static func pulse(_ contrast: ColorSchemeContrast) -> Color {
            accent.opacity(contrast == .increased ? 0.35 : 0.18)
        }

        /// A tinted fill behind strain content: the thermal band in a history strip, flag tags.
        public static func strainFill(_ contrast: ColorSchemeContrast) -> Color {
            strain.opacity(contrast == .increased ? 0.3 : 0.15)
        }

        /// Amber text. Plain orange on a light surface is too faint to read, so it darkens there,
        /// more under Increase Contrast.
        public static func strainText(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color {
            guard scheme == .light else {
                return contrast == .increased ? strain.mix(with: .white, by: 0.2) : strain
            }
            return strain.mix(with: .black, by: contrast == .increased ? 0.45 : 0.3)
        }

        /// Alert threshold rule lines. Amber, never red.
        public static let threshold = Color.orange
    }

    // MARK: Type

    /// SF Pro throughout. Sizes name the spec's scale; text styles follow the system scale.
    public enum Typography {
        /// 44 pt rounded semibold, for the headline figure.
        /// In the typeface and weight chosen in Settings → Customize (D-240).
        public static var hero: Font {
            figure(size: 44)
        }

        /// 28 pt rounded semibold, for the menu bar window's figure and secondary headlines.
        public static var headline: Font {
            figure(size: 28)
        }

        static func figure(size: CGFloat) -> Font {
            let style = Customization.shared
            return Font.system(size: size * style.figureScale, weight: style.fontWeight, design: style.typeface.design)
        }

        /// `standard` at the standard size; at Larger (D-276), the same font scaled up from the
        /// size macOS draws it. Dynamic Type sizes do nothing on macOS, measured on 27.
        static func scaled(_ standard: Font, size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
            let scale = Customization.shared.figureScale
            return scale == 1 ? standard : .system(size: size * scale, weight: weight, design: design)
        }

        /// 13 pt on macOS.
        public static var body: Font {
            scaled(.body, size: 13)
        }

        /// 11 pt on macOS.
        public static var secondary: Font {
            scaled(.subheadline, size: 11)
        }

        /// 10 pt on macOS: a label among marks, a legend.
        public static var caption: Font {
            scaled(.caption2, size: 10)
        }

        /// A chart axis's labels. Nil is Swift Charts' own size; `.font` on a chart doesn't reach
        /// them, so every `AxisValueLabel` takes this (D-276).
        public static var chartLabel: Font? {
            let scale = Customization.shared.figureScale
            return scale == 1 ? nil : .system(size: 10 * scale)
        }

        /// What a view's text is with no font of its own. Nil at the standard size: the system's.
        static var windowDefault: Font? {
            Customization.shared.figureScale == 1 ? nil : body
        }

        /// Card and section titles.
        public static var cardTitle: Font {
            scaled(.headline, size: 13, weight: .bold)
        }

        /// The total in a donut's center.
        public static var donutCenter: Font {
            .system(size: 15 * Customization.shared.figureScale, weight: .semibold, design: .rounded)
        }

        /// The word under a donut's total ("in use", "all apps").
        public static var donutCenterCaption: Font {
            caption
        }

        /// PIDs, paths, ports.
        public static var code: Font {
            scaled(.system(.body, design: .monospaced), size: 13, design: .monospaced)
        }

        /// Paths and PIDs at the secondary size: under a chart, in the inspector's header.
        public static var codeSecondary: Font {
            scaled(.system(.subheadline, design: .monospaced), size: 11, design: .monospaced)
        }

        /// The first line of a two-line table row (a project, a container), and a table's
        /// section headers.
        public static var rowTitle: Font {
            scaled(.headline, size: 13, weight: .bold)
        }

        /// A sheet's title (onboarding).
        public static let sheetTitle = Font.title2.weight(.semibold)
        /// A symbol drawn at `IconSize.card` beside a card's title (the volume, the Full Disk
        /// Access explainer).
        public static let cardSymbol = Font.title2
        /// A symbol beside a feature's title and description (onboarding).
        public static let featureSymbol = Font.title3
        /// Small glyphs between items: a breadcrumb's chevrons.
        public static let separatorGlyph = Font.caption2
    }

    // MARK: Space

    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 12
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 32

        /// Comfortable or Compact, from Settings → Customize (D-240).
        public static var cardPadding: CGFloat {
            Customization.shared.density.cardPadding
        }

        public static var gridGutter: CGFloat {
            Customization.shared.density.gutter
        }

        /// Between a row's title and the line under it.
        public static let lineGap: CGFloat = 2
    }

    // MARK: Shape

    public enum Radius {
        /// Fallback card radius where no concentric container applies.
        public static let card: CGFloat = 12
        /// Donut sector corners.
        public static let sector: CGFloat = 3
        /// Top corners of a sparkline bar; half its width makes a rounded cap.
        public static let sparklineBar: CGFloat = 1
        /// The track behind a sparkline's bars.
        public static let sparklineTrack: CGFloat = 6
        /// History strip bars.
        public static let historyBar: CGFloat = 1.5
    }

    public enum Shapes {
        /// Cards follow the container's corner style, never tighter than `Radius.card`.
        public static let card = ConcentricRectangle(corners: .concentric(minimum: .fixed(Radius.card)), isUniform: true)
        public static let tag = Capsule()
    }

    // MARK: Material

    /// Glass is for chrome; content sits on these solid surfaces (spec 10.1, principle 2).
    public enum Surfaces {
        public static var card: some ShapeStyle {
            .background.secondary
        }

        public static var inset: some ShapeStyle {
            .background.tertiary
        }

        /// Capsule tags (runtime) on top of a card.
        public static var tag: some ShapeStyle {
            .fill.tertiary
        }
    }

    // MARK: Size

    public enum IconSize {
        public static let small: CGFloat = 16
        public static let row: CGFloat = 20
        public static let card: CGFloat = 32
        public static let shareCard: CGFloat = 64
    }

    // MARK: Symbols

    public enum Symbols {
        /// Show in Finder, wherever a button shows a path (Safari's downloads use the same).
        public static let revealInFinder = "magnifyingglass.circle"
        /// A list of apps: top apps, memory by app.
        public static let apps = "square.stack.3d.up"
    }

    public enum Layout {
        public static let mainWindowDefault = CGSize(width: 1100, height: 720)
        public static let mainWindowMinimum = CGSize(width: 760, height: 520)
        public static let sidebarWidth: CGFloat = 200
        public static let sidebarMinWidth: CGFloat = 180
        /// The image Share makes: Overview's headline cards, three across at about their width in
        /// a default-size window. Its height follows the content.
        public static let statusImageWidth: CGFloat = 900
        public static let menuBarWindowWidth: CGFloat = 340
        public static let overviewCardMinWidth: CGFloat = 250
        public static let sparklineHeight: CGFloat = 56
        public static let menuBarSparklineHeight: CGFloat = 40
        public static let statusDot: CGFloat = 8
        /// A card's title row: symbol, title, status badge.
        public static let cardHeaderHeight: CGFloat = 20
        /// A line in the menu bar window's Overview card: symbol, name, figure.
        public static let compactRowHeight: CGFloat = 18
        public static let headlineCardWidth: CGFloat = 300
        /// The Battery tab's Accessories card, beside the figures (D-165).
        public static let accessoriesCardWidth: CGFloat = 280
        public static var accessoriesCardNarrowWidth: CGFloat {
            190 * Customization.shared.figureScale
        }

        /// The narrowest a metric tab's secondary figures get in three columns, and in two (D-176).
        public static var figuresThreeColumnMinWidth: CGFloat {
            330 * Customization.shared.figureScale
        }

        public static var figuresTwoColumnMinWidth: CGFloat {
            240 * Customization.shared.figureScale
        }

        /// The figures card alone: below this a third is too narrow for "Performance cores (10)".
        public static let figuresThreeColumnRoomyWidth: CGFloat = 500
        /// Your week: the day-by-day chart sits beside the figures from this width, under them below.
        public static let yourWeekSideBySideWidth: CGFloat = 820
        public static let weekDaysChartMaxWidth: CGFloat = 360
        /// Agents → This week: its list is narrower than Your week's figures, so side by side sooner.
        public static let agentWeekSideBySideWidth: CGFloat = 740
        /// Agents: below this page height, This week is its summary line alone.
        public static let agentWeekFullMinHeight: CGFloat = 640
        /// Overview → Today so far: the ribbon and its hour labels.
        public static let todayRibbonHeight: CGFloat = 40
        public static let todayRibbonCompactHeight: CGFloat = 34
        public static let weekDaysChartHeight: CGFloat = 150
        /// Your day: the time column, wide enough for "10:45 – 11:30 AM".
        public static let dayTimelineTimeWidth: CGFloat = 132
        public static let historyStripHeight: CGFloat = 210
        /// Why is my Mac slow?: its causes and past slowdowns scroll past this height.
        public static let diagnosisListMaxHeight: CGFloat = 520
        /// The shortest a metric tab's app list gets; below it, the page scrolls (D-174).
        public static let appListMinHeight: CGFloat = 240
        public static let historyTopAppsWidth: CGFloat = 240
        /// The "+25%" column in a history strip's top apps.
        public static let changeColumnWidth: CGFloat = 40
        /// A sparkline bar and the gap after it. Samples that don't fit at this pitch scroll off
        /// the left, so a narrow card shows the most recent ones (at most
        /// `LiveMetrics.historyLength`).
        public static let sparklineBarWidth: CGFloat = 2
        public static let sparklineBarGap: CGFloat = 1.5
        /// Space between a sparkline's track and its bars.
        public static let sparklineTrackInset: CGFloat = 4
        /// A history strip's bar count: at most this many, and none thinner than
        /// `historyMinBarPitch` points apart (bins widen instead).
        public static let historyMaxBars = 180
        public static let historyMinBarPitch: CGFloat = 3
        /// Share of a history bin left empty between bars.
        public static let historyBarGap: Double = 0.3
        /// Donut ring diameter: the legend gets its full width first, then the ring takes what's
        /// left within this range.
        public static let donutRing: ClosedRange<CGFloat> = 84 ... 116
        /// The ring's hole, as a share of its radius.
        public static let donutInnerRatio: CGFloat = 0.72
        /// The gap between a donut's slices.
        public static let donutSliceGap: CGFloat = 1
        /// The total in a donut's center shrinks this far before truncating, on the smallest ring.
        public static let donutCenterMinimumScale: CGFloat = 0.6
        /// The center label's width as a share of the ring's: the hole is 72%, and text a little
        /// narrower than that clears the slices at the height of its two lines.
        public static let donutLabelWidthRatio: CGFloat = 0.6
        /// Legend rows before the rest fold into "Other".
        public static let donutTopRows = 4
        public static let onboardingWidth: CGFloat = 480
        /// The output-device menu in a Volume tab row.
        public static let audioDevicePickerWidth: CGFloat = 170
        /// The same menu in the menu bar window, where the app's name comes first.
        public static let audioDevicePickerCompactWidth: CGFloat = 150
        public static let settingsWidth: CGFloat = 560
        public static let settingsMinHeight: CGFloat = 420
        /// Fits a 13-inch MacBook Air's screen under the menu bar, with the title bar.
        public static let settingsMaxHeight: CGFloat = 680
        /// Onboarding stays on a laptop screen in any language; its features scroll past this.
        public static let onboardingMaxHeight: CGFloat = 680
    }

    // MARK: Menu bar item

    /// The small displays in the menu bar (spec 4.1). Point sizes, drawn into a template image.
    public enum MenuBarItem {
        /// `NSStatusBar.system.thickness`. A taller image would be scaled down and blur.
        public static let height: CGFloat = 22
        /// The pulse glyph before a figure, graph, or stacked display.
        public static let glyph = "waveform.path.ecg"
        public static let strainGlyph = "exclamationmark.triangle.fill"
        public static let glyphSize: CGFloat = 12
        public static let glyphWeight = NSFont.Weight.semibold
        /// The glyph's slot, so swapping to the warning sign under strain keeps the width.
        public static let glyphWidth: CGFloat = 15
        /// Clear space at each end, so antialiased edges aren't clipped.
        public static let horizontalInset: CGFloat = 1
        /// Figure mode: the menu bar's own text size.
        public static let figureSize: CGFloat = 13
        public static let figureWeight = NSFont.Weight.medium
        /// Stacked mode: a tiny uppercase label centered above each value.
        public static let labelSize: CGFloat = 8.5
        public static let labelWeight = NSFont.Weight.semibold
        public static let valueSize: CGFloat = 12
        public static let valueWeight = NSFont.Weight.medium
        /// Label and value rows; together they make `height`.
        public static let labelRow: CGFloat = 8
        public static let valueRow: CGFloat = 14
        /// Template images carry alpha only; the menu bar tints them. Labels read as secondary.
        public static let labelOpacity: Double = 0.6
        /// A column with two values (network both ways): two rows of `lineRow`, in place of label
        /// and value, together `height`.
        public static let lineSize: CGFloat = 9.5
        public static let lineRow: CGFloat = 11
        public static let columnSpacing: CGFloat = 5
        /// Between the glyph and what follows.
        public static let glyphSpacing: CGFloat = 4
        /// Graph mode: one bar per recent sample, oldest on the left.
        public static let barCount = 14
        public static let barWidth: CGFloat = 2
        public static let barGap: CGFloat = 1
        public static let barHeight: CGFloat = 16
        /// An empty sample still shows a stub, so the graph's baseline stays visible.
        public static let barMinimum: CGFloat = 1
        /// Settings preview: a strip that looks like a piece of the menu bar.
        public static let previewPadding: CGFloat = 10
        public static let previewHeight: CGFloat = 24
    }

    // MARK: Motion

    /// Numbers tick; nothing else moves (spec 10.1, principle 6).
    public enum Motion {
        public static let figure = Animation.snappy(duration: 0.35)
        /// A live figure's once-a-second digit roll (`FigureText`, D-053).
        public static let tick = Animation.easeOut(duration: 0.15)

        /// `figure`, or none with Reduce Motion on: a scroll jumps rather than glides (D-221).
        public static func figure(reduced: Bool) -> Animation? {
            reduced ? nil : figure
        }
    }

    // MARK: Sidebar symbols

    public enum SidebarTint {
        public static let overview = Color.blue
        public static let checkup = Color.green
        // Metrics: also their charts' colors (D-057), in the palette from Settings → Customize
        // (D-240).
        public static var cpu: Color {
            Customization.shared.palette.color(.cpu)
        }

        public static var memory: Color {
            Customization.shared.palette.color(.memory)
        }

        public static var disk: Color {
            Customization.shared.palette.color(.disk)
        }

        public static var network: Color {
            Customization.shared.palette.color(.network)
        }

        public static var gpu: Color {
            Customization.shared.palette.color(.gpu)
        }

        public static var battery: Color {
            Customization.shared.palette.color(.battery)
        }

        public static let projects = Color.brown
        public static let agents = Color.orange
        public static let storage = Color.mint
        public static let startup = Color.cyan
        public static let security = Color.teal
        public static let volume = Color.pink
        public static let devices = Color.indigo
        public static let alerts = Color.red
        public static let history = Color.indigo
    }
}

extension View {
    /// A content card: solid grouped surface, card padding, container-concentric corners.
    public func cardStyle() -> some View {
        modifier(CardStyle())
    }
}

/// Cards are borderless (spec 10.1, principle 3) until Increase Contrast asks for edges.
private struct CardStyle: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(Tokens.Spacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Surfaces.card, in: Tokens.Shapes.card)
            .overlay {
                if contrast == .increased {
                    Tokens.Shapes.card.stroke(.separator)
                }
            }
    }
}
