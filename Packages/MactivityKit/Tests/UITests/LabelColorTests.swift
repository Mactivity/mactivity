import SwiftUI
import Testing
@testable import UI

/// Words in amber and green have to be readable where they are drawn (spec 10.3). Plain system
/// orange and green are about 2.2:1 on white; text needs far more.
@MainActor
@Suite("Amber and green words are readable on light and dark")
struct LabelColorTests {
    private func environment(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast = .standard) -> EnvironmentValues {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        environment._colorSchemeContrast = contrast
        return environment
    }

    /// WCAG relative luminance, from the color as SwiftUI resolves it (linear components).
    private func luminance(_ color: Color, in environment: EnvironmentValues) -> Double {
        let resolved = color.resolve(in: environment)
        return 0.2126 * Double(resolved.linearRed) + 0.7152 * Double(resolved.linearGreen) + 0.0722 * Double(resolved.linearBlue)
    }

    /// WCAG contrast of `color` against a surface of luminance `surface` (white is 1, black 0).
    private func contrast(_ color: Color, on surface: Double, in environment: EnvironmentValues) -> Double {
        let text = luminance(color, in: environment)
        return (max(text, surface) + 0.05) / (min(text, surface) + 0.05)
    }

    @Test("On a light surface the words are about twice as readable as the plain color, more under Increase Contrast")
    func light() {
        let light = environment(.light)
        let plainOrange = contrast(Tokens.Colors.strain, on: 1, in: light)
        let plainGreen = contrast(.green, on: 1, in: light)
        #expect(plainOrange < 3 && plainGreen < 3)

        let amber = contrast(Tokens.Colors.strainLabel.resolve(in: light), on: 1, in: light)
        let green = contrast(Tokens.Colors.goodLabel.resolve(in: light), on: 1, in: light)
        #expect(amber >= 4 && amber > plainOrange * 1.8)
        #expect(green >= 4 && green > plainGreen * 1.8)

        let increased = environment(.light, .increased)
        #expect(contrast(Tokens.Colors.strainLabel.resolve(in: increased), on: 1, in: increased) >= 6)
        #expect(contrast(Tokens.Colors.goodLabel.resolve(in: increased), on: 1, in: increased) >= 6)
    }

    @Test("On a dark surface the words stay the bright system colors")
    func dark() {
        let dark = environment(.dark)
        #expect(contrast(Tokens.Colors.strainLabel.resolve(in: dark), on: 0, in: dark) >= 7)
        #expect(contrast(Tokens.Colors.goodLabel.resolve(in: dark), on: 0, in: dark) >= 7)
    }
}
