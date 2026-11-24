import SwiftUI

/// Colors for words, beside the shared tokens. Plain system orange and
/// green are about 2.2:1 on a light surface, too faint for text, so words take these instead.
/// Symbols, fills and chart marks keep `Tokens.Colors.strain` and plain green.
extension Tokens.Colors {
    /// Amber for words. It is `strainText` for wherever the view is drawn, read from the
    /// environment, so a call site needs no `colorScheme` of its own.
    public static let strainLabel = StrainLabelStyle()

    /// Green for words ("12% faster"), as `strainLabel` is amber for words.
    public static let goodLabel = GoodLabelStyle()

    /// Green text, darkened on a light surface by the same amounts as `strainText`.
    public static func goodText(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color {
        guard scheme == .light else {
            return contrast == .increased ? Color.green.mix(with: .white, by: 0.2) : .green
        }
        return Color.green.mix(with: .black, by: contrast == .increased ? 0.45 : 0.3)
    }
}

public struct StrainLabelStyle: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> Color {
        Tokens.Colors.strainText(environment.colorScheme, environment.colorSchemeContrast)
    }
}

public struct GoodLabelStyle: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> Color {
        Tokens.Colors.goodText(environment.colorScheme, environment.colorSchemeContrast)
    }
}
