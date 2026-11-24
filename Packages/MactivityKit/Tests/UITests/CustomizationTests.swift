import Foundation
import Testing
@testable import UI

/// Settings → Customize keeps its choices, and falls back to the defaults on anything odd (D-240).
struct CustomizationTests {
    @Test("Choices persist across launches; Back to the Defaults undoes them")
    func persists() throws {
        let defaults = try #require(UserDefaults(suiteName: "CustomizationTests-\(UUID().uuidString)"))
        let first = Customization(defaults: defaults)
        #expect(first.isDefault)
        first.palette = .distinct
        first.typeface = .serif
        first.weight = 5
        first.density = .compact
        first.figureSize = .larger
        let second = Customization(defaults: defaults)
        #expect(second.palette == .distinct)
        #expect(second.typeface == .serif)
        #expect(second.fontWeight == .heavy)
        #expect(second.density.gutter < CardDensity.comfortable.gutter)
        #expect(second.figureSize == .larger)
        #expect(second.figureScale > 1)
        #expect(!second.isDefault)
        second.reset()
        #expect(Customization(defaults: defaults).isDefault)
    }

    @Test("Larger is a choice of its own: alone it isn't the default, and a picture is drawn at the standard size")
    @MainActor func larger() throws {
        let defaults = try #require(UserDefaults(suiteName: "CustomizationTests-\(UUID().uuidString)"))
        let style = Customization(defaults: defaults)
        #expect(style.figureScale == 1)
        style.figureSize = .larger
        #expect(!style.isDefault)
        let inside = style.atStandardSize { style.figureScale }
        #expect(inside == 1)
        #expect(style.figureScale == FigureSize.larger.scale)
        style.reset()
        #expect(style.isDefault)
    }

    @Test("A stored weight out of range is clamped")
    func clampsWeight() throws {
        let defaults = try #require(UserDefaults(suiteName: "CustomizationTests-\(UUID().uuidString)"))
        defaults.set(42, forKey: PreferenceKey.figureWeight)
        defaults.set("neon", forKey: PreferenceKey.metricPalette)
        let style = Customization(defaults: defaults)
        #expect(style.weight == FigureTypeface.weights.count - 1)
        #expect(style.palette == .standard)
    }
}
