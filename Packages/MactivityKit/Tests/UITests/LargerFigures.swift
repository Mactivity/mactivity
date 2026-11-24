import Foundation
import Testing
@testable import UI

/// `make test-larger` runs the layout suites with Settings → Customize's Larger figures on, in a
/// process of its own (D-276): `Tokens` reads one shared setting, and turning it on in the middle
/// of the other suites would change what they measure. Set in memory only, never in the defaults.
enum LargerFigures {
    static let isOn: Bool = {
        guard ProcessInfo.processInfo.environment["MACTIVITY_LARGER_FIGURES"] == "1" else {
            return false
        }
        Customization.shared.scaleOverride = FigureSize.larger.scale
        return true
    }()
}

/// Proof `make test-larger` makes bigger what the layout suites lay out.
@Suite("Larger figures reach the tokens (D-276)", .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LARGER_FIGURES"] == "1"))
struct LargerFiguresProofTests {
    @Test("Every text token and chart label changes")
    @MainActor func scales() {
        _ = LargerFigures.isOn
        #expect(Customization.shared.figureScale == 1.25)
        #expect(Tokens.Typography.chartLabel != nil)
        #expect(Tokens.Typography.windowDefault != nil)
        #expect(Tokens.Typography.secondary != .subheadline)
        #expect(Tokens.Typography.body != .body)
    }

    @Test("A fixed layout's picture still draws at the standard size")
    @MainActor func exportStaysStandard() {
        _ = LargerFigures.isOn
        Customization.shared.atStandardSize {
            #expect(Customization.shared.figureScale == 1)
            #expect(Tokens.Typography.chartLabel == nil)
            #expect(Tokens.Typography.secondary == .subheadline)
        }
        #expect(Customization.shared.figureScale == 1.25)
    }
}
