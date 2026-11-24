import Observation
import SwiftUI

/// Settings → Customize (D-240): the metrics' colors, the figures' typeface and weight, and how
/// tightly the cards sit. Read through `Tokens`, so every view that draws a metric's color, a
/// headline figure or a card follows a change at once. Kept in the app's defaults.
@Observable
public final class Customization: @unchecked Sendable {
    public static let shared = Customization()

    public var palette: MetricPalette {
        didSet { defaults.set(palette.rawValue, forKey: PreferenceKey.metricPalette) }
    }

    public var typeface: FigureTypeface {
        didSet { defaults.set(typeface.rawValue, forKey: PreferenceKey.figureTypeface) }
    }

    /// An index into `FigureTypeface.weights`: light to heavy, semibold by default.
    public var weight: Int {
        didSet { defaults.set(weight, forKey: PreferenceKey.figureWeight) }
    }

    public var density: CardDensity {
        didSet { defaults.set(density.rawValue, forKey: PreferenceKey.cardDensity) }
    }

    /// Standard or Larger: every figure and chart label (D-276).
    public var figureSize: FigureSize {
        didSet { defaults.set(figureSize.rawValue, forKey: PreferenceKey.figureSize) }
    }

    /// What `Tokens` multiplies by. A picture or a page with a fixed layout sets this to 1 while
    /// it's drawn; the layout tests set it to Larger's. Not observed: neither should redraw windows.
    @ObservationIgnored var scaleOverride: CGFloat?

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        palette = defaults.string(forKey: PreferenceKey.metricPalette).flatMap(MetricPalette.init) ?? .standard
        typeface = defaults.string(forKey: PreferenceKey.figureTypeface).flatMap(FigureTypeface.init) ?? .rounded
        let weight = defaults.object(forKey: PreferenceKey.figureWeight) as? Int ?? FigureTypeface.defaultWeight
        self.weight = min(max(weight, 0), FigureTypeface.weights.count - 1)
        density = defaults.string(forKey: PreferenceKey.cardDensity).flatMap(CardDensity.init) ?? .comfortable
        figureSize = defaults.string(forKey: PreferenceKey.figureSize).flatMap(FigureSize.init) ?? .standard
    }

    public var figureScale: CGFloat {
        scaleOverride ?? figureSize.scale
    }

    /// Runs `body` at the standard size: for share images and PDFs, whose layouts are fixed.
    /// They render synchronously, so no window can draw in between.
    @MainActor public func atStandardSize<Result>(_ body: () -> Result) -> Result {
        let saved = scaleOverride
        scaleOverride = 1
        defer { scaleOverride = saved }
        return body()
    }

    public var fontWeight: Font.Weight {
        FigureTypeface.weights[min(max(weight, 0), FigureTypeface.weights.count - 1)]
    }

    public var isDefault: Bool {
        palette == .standard && typeface == .rounded && weight == FigureTypeface.defaultWeight && density == .comfortable
            && figureSize == .standard
    }

    public func reset() {
        palette = .standard
        typeface = .rounded
        weight = FigureTypeface.defaultWeight
        density = .comfortable
        figureSize = .standard
    }
}

/// How big figures and chart labels are, for reading Mactivity from across the desk (D-276).
public enum FigureSize: String, CaseIterable, Identifiable, Sendable {
    case standard, larger

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .standard: String(localized: "Standard", bundle: .strings, comment: "Customize: the usual size of figures and chart labels")
        case .larger: String(localized: "Larger", bundle: .strings, comment: "Customize: larger figures and chart labels")
        }
    }

    var scale: CGFloat {
        self == .larger ? 1.25 : 1
    }
}

/// The six metrics' colors.
public enum MetricPalette: String, CaseIterable, Identifiable, Sendable {
    /// The colors Mactivity has always used (D-057).
    case standard
    /// Shades of gray: for a calm window, or a screen shared with others.
    case graphite
    /// Okabe and Ito's palette, told apart with any of the common kinds of color blindness.
    case distinct

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .standard: String(localized: "Mactivity", bundle: .strings, comment: "Customize: the app's own metric colors")
        case .graphite: String(localized: "Graphite", bundle: .strings, comment: "Customize: metric colors in shades of gray")
        case .distinct: String(
                localized: "Color-blind safe",
                bundle: .strings,
                comment: "Customize: metric colors that stay distinct with color blindness"
            )
        }
    }

    /// CPU, GPU, Memory, Disk, Network, Battery.
    public func color(_ metric: MetricTab) -> Color {
        switch self {
        case .standard:
            switch metric {
            case .cpu: .blue
            case .gpu: .pink
            case .memory: .purple
            case .disk: .orange
            case .network: .teal
            case .battery: .green
            }
        case .graphite:
            switch metric {
            case .cpu: Color(white: 0.62)
            case .gpu: Color(white: 0.5)
            case .memory: Color(white: 0.7)
            case .disk: Color(white: 0.56)
            case .network: Color(white: 0.66)
            case .battery: Color(white: 0.6)
            }
        case .distinct:
            switch metric {
            case .cpu: Color(red: 0.34, green: 0.71, blue: 0.91)
            case .gpu: Color(red: 0.84, green: 0.37, blue: 0)
            case .memory: Color(red: 0.8, green: 0.47, blue: 0.65)
            case .disk: Color(red: 0.9, green: 0.62, blue: 0)
            case .network: Color(red: 0, green: 0.62, blue: 0.45)
            case .battery: Color(red: 0.94, green: 0.89, blue: 0.26)
            }
        }
    }
}

/// The typeface of the big figures.
public enum FigureTypeface: String, CaseIterable, Identifiable, Sendable {
    case rounded, standard, monospaced, serif

    public static let weights: [Font.Weight] = [.light, .regular, .medium, .semibold, .bold, .heavy]
    public static let defaultWeight = 3

    public var id: String {
        rawValue
    }

    public var design: Font.Design {
        switch self {
        case .rounded: .rounded
        case .standard: .default
        case .monospaced: .monospaced
        case .serif: .serif
        }
    }

    public var title: String {
        switch self {
        case .rounded: String(localized: "Rounded", bundle: .strings, comment: "Customize: the figures' typeface")
        case .standard: String(localized: "Standard", bundle: .strings, comment: "Customize: the figures' typeface, the system's own")
        case .monospaced: String(localized: "Monospaced", bundle: .strings, comment: "Customize: the figures' typeface")
        case .serif: String(localized: "Serif", bundle: .strings, comment: "Customize: the figures' typeface")
        }
    }
}

/// How tightly cards sit and how much room is inside them.
public enum CardDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable, compact

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .comfortable: String(localized: "Comfortable", bundle: .strings, comment: "Customize: roomy card spacing")
        case .compact: String(localized: "Compact", bundle: .strings, comment: "Customize: tighter card spacing")
        }
    }

    var gutter: CGFloat {
        self == .compact ? 8 : 12
    }

    var cardPadding: CGFloat {
        self == .compact ? 12 : 16
    }
}
