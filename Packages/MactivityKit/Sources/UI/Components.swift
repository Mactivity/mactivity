import AppKit
import Charts
import Core
import Export
import SwiftUI

/// A live figure whose changed digits roll into place, and which never changes width between
/// samples.
///
/// Each character is its own view: a changed one slides out as the new one slides in (up when the
/// value rises, down when it falls), clipped to its cell like an odometer. That's
/// `numericText`'s motion without its per-frame blur, which cost 39% of a core with six figures
/// on screen, even with the blur moved to the GPU in a `drawingGroup` (D-011). This costs about
/// 11% (D-053). Figures don't animate while the window is in the background or
/// with Reduce Motion on.
public struct FigureText: View {
    private let text: String
    private let value: Double
    private let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    /// Which way the digits last rolled. A reference, not state: writing state from `onChange`
    /// re-evaluated the body a second time on every tick (D-086).
    @State private var direction = RollDirection()

    private var ticks: Bool {
        !reduceMotion && appearsActive
    }

    public init(_ text: String, value: Double, font: Font = Tokens.Typography.hero) {
        self.text = text
        self.value = value
        self.font = font
    }

    public var body: some View {
        let glyphs = Array(text)
        let rising = direction.rising(for: text, value: value)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Cells are numbered from the right, so "9.9 kB/s" → "10.1 kB/s" keeps the unit's cells
            // (and only rolls the digits that changed).
            ForEach(glyphs.indices.map { glyphs.count - $0 }, id: \.self) { fromRight in
                GlyphCell(glyph: glyphs[glyphs.count - fromRight], rising: rising, animates: ticks)
            }
        }
        .font(font)
        .monospacedDigit()
        // Keyed on the text: a sample that rounds to the same text ("12%") doesn't animate.
        .animation(ticks ? Tokens.Motion.tick : nil, value: text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Remembers the value behind the text on screen, so a new text rolls up when its value is higher
/// and down when it's lower. Updated only when the text changes, so evaluating a body twice for
/// the same text gives the same answer.
@MainActor
final class RollDirection {
    private var text: String?
    private var value: Double?
    private var isRising = true

    func rising(for text: String, value: Double) -> Bool {
        if text != self.text {
            isRising = value >= (self.value ?? value)
            self.text = text
            self.value = value
        }
        return isRising
    }
}

/// One character of a `FigureText`. Changing the character swaps the view's identity, which
/// is what runs the slide transition.
private struct GlyphCell: View {
    let glyph: Character
    let rising: Bool
    let animates: Bool

    var body: some View {
        ZStack {
            Text(String(glyph))
                .id(glyph)
                .transition(animates ? .push(from: rising ? .bottom : .top) : .identity)
        }
        .clipped()
    }
}

/// Status word with a colored dot: "● Normal".
public struct StatusBadge: View {
    private let status: MetricStatus
    private let showsTitle: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// `showsTitle: false` keeps only the dot, for narrow cards; the word stays in help and VoiceOver.
    public init(_ status: MetricStatus, showsTitle: Bool = true) {
        self.status = status
        self.showsTitle = showsTitle
    }

    public var body: some View {
        StatusDotLabel(
            showsTitle ? status.title : nil,
            color: Tokens.Colors.status(status),
            // Yellow alone disappears on a light card, and the dot may be all there is.
            outline: Tokens.Colors.statusOutline(status, colorScheme, contrast)
        )
        .font(Tokens.Typography.secondary)
        .help(status.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.title)
    }
}

/// A status dot and its word, "● Running": metric status, container state, startup item state.
struct StatusDotLabel: View {
    private let title: String?
    private let color: Color?
    private let outline: Color?
    private let isProminent: Bool

    /// `color: nil` leaves the dot's space empty, so the words still line up down a column.
    /// `isProminent` draws the word in the primary color (running), otherwise secondary.
    init(_ title: String?, color: Color?, outline: Color? = nil, isProminent: Bool = false) {
        self.title = title
        self.color = color
        self.outline = outline
        self.isProminent = isProminent
    }

    var body: some View {
        HStack(spacing: Tokens.Spacing.xxs) {
            Circle()
                .fill(color ?? .clear)
                .overlay {
                    if let outline {
                        Circle().strokeBorder(outline)
                    }
                }
                .frame(width: Tokens.Layout.statusDot, height: Tokens.Layout.statusDot)
                .accessibilityHidden(true)
            if let title {
                Text(title)
                    .foregroundStyle(isProminent ? .primary : .secondary)
            }
        }
    }
}

/// The last couple of minutes of one metric, one bar per sample. Content, so it never sits on
/// glass.
///
/// Drawn as one `Path` of rounded bars over a rounded track, not with Swift Charts or a view per
/// bar: six Charts sparklines redrawing every second cost about a third of a core on the Overview
/// (D-032). No `drawingGroup` either: a single filled path needs no offscreen
/// texture, and each `drawingGroup` keeps one.
public struct Sparkline: View {
    private let values: [Double]
    private let domain: ClosedRange<Double>?
    private let tint: Color
    private let unit: SparklineUnit?

    @Environment(\.colorSchemeContrast) private var contrast
    /// The spoken summary is only worked out while VoiceOver is on: the sparkline redraws every tick.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// - Parameters:
    ///   - domain: fixed y range (0...100 for percentages); nil scales to the data shown.
    ///   - tint: the metric's color (`MetricTab.tint`).
    ///   - unit: how VoiceOver reads the latest value; nil reads only the label.
    public init(
        points: [LiveMetrics.Point],
        domain: ClosedRange<Double>? = 0 ... 100,
        tint: Color = Tokens.Colors.chartDefault,
        unit: SparklineUnit? = nil
    ) {
        values = points.map(\.value)
        self.domain = domain
        self.tint = tint
        self.unit = unit
    }

    public var body: some View {
        SparklineBars(values: values, domain: domain)
            .fill(tint)
            .padding(Tokens.Layout.sparklineTrackInset)
            .background(Tokens.Colors.chartTrack(tint, contrast), in: RoundedRectangle(cornerRadius: Tokens.Radius.sparklineTrack))
            .accessibilityElement()
            .accessibilityLabel(Text("Recent activity", bundle: .strings, comment: "Sparkline accessibility label"))
            .accessibilityValue(voiceOver ? SparklineLayout.spokenValue(values, domain: domain, unit: unit) : "")
    }
}

/// What a sparkline's values are, so VoiceOver can read the latest one.
public enum SparklineUnit: Sendable {
    /// 0...100.
    case percent
    /// Bytes per second.
    case rate
    /// Bytes.
    case memory
    /// Milliwatts.
    case power

    func format(_ value: Double) -> String {
        switch self {
        case .percent: Formatters.percent(value)
        case .rate: Formatters.rate(value)
        case .memory: Formatters.memory(value)
        case .power: Formatters.power(milliwatts: value)
        }
    }
}

/// Which way a sparkline is heading.
enum SparklineTrend: Equatable {
    case rising, falling, steady
}

/// Every visible sample as one rounded bar, in a single path.
struct SparklineBars: Shape {
    let values: [Double]
    let domain: ClosedRange<Double>?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(Tokens.Radius.sparklineBar, Tokens.Layout.sparklineBarWidth / 2)
        let corners = RectangleCornerRadii(topLeading: radius, bottomLeading: 0, bottomTrailing: 0, topTrailing: radius)
        for bar in SparklineLayout.bars(values: values, domain: domain, in: rect) {
            path.addRoundedRect(in: bar, cornerRadii: corners)
        }
        return path
    }
}

/// Where a sparkline's bars go. Pure, so it's tested without drawing.
enum SparklineLayout {
    /// The spoken forms, looked up once.
    private static let rising = String(
        localized: "sparkline.rising", defaultValue: "Latest %@, rising", bundle: .strings,
        comment: "VoiceOver for a sparkline: the latest value, and it's going up"
    )
    private static let falling = String(
        localized: "sparkline.falling", defaultValue: "Latest %@, falling", bundle: .strings,
        comment: "VoiceOver for a sparkline: the latest value, and it's going down"
    )
    private static let steady = String(
        localized: "sparkline.steady", defaultValue: "Latest %@, steady", bundle: .strings,
        comment: "VoiceOver for a sparkline: the latest value, and it's holding steady"
    )

    /// "Latest 42%, rising". Empty without a unit or a sample.
    static func spokenValue(_ values: [Double], domain: ClosedRange<Double>?, unit: SparklineUnit?) -> String {
        guard let unit, let latest = values.last else {
            return ""
        }
        let format = switch trend(values, domain: domain) {
        case .rising: rising
        case .falling: falling
        case .steady: steady
        }
        return String(format: format, unit.format(latest))
    }

    /// The newest `window` samples' average against the `window` before them: a move of more
    /// than a tenth of the range (the fixed domain, or the largest sample) is rising or falling.
    static func trend(_ values: [Double], domain: ClosedRange<Double>?, window: Int = 5) -> SparklineTrend {
        let recent = values.suffix(window)
        let earlier = values.dropLast(recent.count).suffix(window)
        guard !recent.isEmpty, !earlier.isEmpty else {
            return .steady
        }
        let change = recent.reduce(0, +) / Double(recent.count) - earlier.reduce(0, +) / Double(earlier.count)
        let span = domain.map { $0.upperBound - $0.lowerBound } ?? (values.max() ?? 0)
        guard span > 0, abs(change) > span * 0.1 else {
            return .steady
        }
        return change > 0 ? .rising : .falling
    }

    /// One rect per sample, newest at the right edge, at a fixed pitch. Samples that don't fit
    /// scroll off the left. A zero sample is still a stub as tall as the bar is wide, so the
    /// baseline reads as a row of dots rather than as missing data.
    /// - Parameter domain: fixed y range; nil scales to the visible samples, with headroom.
    static func bars(
        values: [Double],
        domain: ClosedRange<Double>?,
        in rect: CGRect,
        barWidth: CGFloat = Tokens.Layout.sparklineBarWidth,
        gap: CGFloat = Tokens.Layout.sparklineBarGap
    ) -> [CGRect] {
        let pitch = barWidth + gap
        guard !values.isEmpty, rect.width >= barWidth, rect.height > 0, pitch > 0 else {
            return []
        }
        let fitting = Int(((rect.width + gap) / pitch).rounded(.down))
        let shown = values.suffix(fitting)
        // Headroom so a flat run doesn't hug the top; never a zero-height range.
        let range = domain ?? 0 ... max(shown.max() ?? 0, 1) * 1.15
        let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
        let minimumHeight = min(barWidth, rect.height)
        return shown.enumerated().map { offset, value in
            let fraction = CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
            let height = max(minimumHeight, rect.height * fraction)
            let fromRight = CGFloat(shown.count - offset)
            let x = rect.maxX - fromRight * pitch + gap
            return CGRect(x: x, y: rect.maxY - height, width: barWidth, height: height)
        }
    }
}

/// An app's icon at a given size: the bundle icon for apps and terminals, a symbol for the
/// macOS and Other rows.
public struct AppIconView: View {
    private let app: AppIdentity
    private let size: CGFloat

    public init(_ app: AppIdentity, size: CGFloat = Tokens.IconSize.row) {
        self.app = app
        self.size = size
    }

    public var body: some View {
        Group {
            switch app.kind {
            case .app, .terminal:
                Image(nsImage: IconCache.shared.icon(forPath: app.iconKey))
                    .resizable()
                    .interpolation(.high)
            case .system:
                Image(systemName: app.id == AppIdentity.otherUsers.id ? "person.2.fill" : "applelogo")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.15)
                    .foregroundStyle(.secondary)
            case .other:
                Image(nsImage: IconCache.shared.executableIcon)
                    .resizable()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Bundle icons, read once per path (spec 6.2) through `AppIconLookup`.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var icons: [String: NSImage] = [:]

    lazy var executableIcon: NSImage = AppIconLookup.executable

    func removeAll() {
        icons.removeAll()
    }

    func icon(forPath path: String) -> NSImage {
        if let icon = icons[path] {
            return icon
        }
        let icon = AppIconLookup.icon(forPath: path)
        icons[path] = icon
        return icon
    }
}

/// A card title: symbol, name, and an optional status badge on the trailing side.
struct CardHeader: View {
    let title: String
    let symbol: String
    let status: MetricStatus?
    /// The metric's color for the symbol, matching its chart and sidebar entry (D-057).
    var tint: Color?

    /// Differentiate Without Color: the status word stays, since a dot is only a color.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        // The title stays on one line: where the badge's word doesn't fit beside it (the 340 pt
        // menu bar window's two-column cards), the badge drops to its dot. With Differentiate
        // Without Color on, the word stays and the title truncates instead.
        ViewThatFits(in: .horizontal) {
            row(showsStatusTitle: true)
            if differentiateWithoutColor {
                row(showsStatusTitle: true, titleTruncates: true)
            } else {
                row(showsStatusTitle: false)
            }
        }
    }

    private func row(showsStatusTitle: Bool, titleTruncates: Bool = false) -> some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Label {
                Text(title)
            } icon: {
                RowSymbol(symbol, tint: tint)
            }
            .font(Tokens.Typography.cardTitle)
            .lineLimit(1)
            // The full-badge row claims its title's whole width, so it only fits when nothing
            // truncates; the dot-only row may truncate as a last resort.
            .fixedSize(horizontal: showsStatusTitle && !titleTruncates, vertical: false)
            Spacer(minLength: 0)
            if let status {
                StatusBadge(status, showsTitle: showsStatusTitle)
            }
        }
        // Whole points, with or without a badge: a fractional header puts the card's figure and
        // everything under it on a half pixel.
        .frame(height: Tokens.Layout.cardHeaderHeight)
    }
}

/// An SF Symbol in a fixed `IconSize.small` box, for card titles and label rows. Each symbol has
/// its own natural width and height; without the box, titles beside different symbols start at
/// different places and rows differ in height by a point.
struct RowSymbol: View {
    let name: String
    /// Nil keeps the surrounding foreground style (primary, or secondary in a secondary row).
    var tint: Color?

    init(_ name: String, tint: Color? = nil) {
        self.name = name
        self.tint = tint
    }

    var body: some View {
        Group {
            if let tint {
                Image(systemName: name).foregroundStyle(tint)
            } else {
                Image(systemName: name)
            }
        }
        .frame(width: Tokens.IconSize.small, height: Tokens.IconSize.small)
        .accessibilityHidden(true)
    }
}

extension View {
    /// A small capsule tag (a runtime, a startup flag, "This Mac"): secondary text on a tinted
    /// capsule, one line, the same padding everywhere.
    func tagStyle(_ fill: some ShapeStyle) -> some View {
        font(Tokens.Typography.secondary)
            .lineLimit(1)
            .padding(.horizontal, Tokens.Spacing.xs)
            .padding(.vertical, Tokens.Spacing.lineGap)
            .background(fill, in: Tokens.Shapes.tag)
    }

    /// A tag on the default tag surface.
    func tagStyle() -> some View {
        tagStyle(Tokens.Surfaces.tag)
    }
}

/// A label whose icon is centered on its title rather than aligned to its baseline, so rows with
/// different symbols are the same height (each symbol has its own baseline).
struct CenteredIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.xs) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == CenteredIconLabelStyle {
    static var centeredIcon: CenteredIconLabelStyle {
        CenteredIconLabelStyle()
    }
}
