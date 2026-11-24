import AppKit
import Core
import Foundation
import Testing
@testable import UI

/// The menu bar item's small displays: text, widths that never move, bars, and the stacked list.
@Suite("Menu bar layout")
struct MenuBarLayoutTests {
    init() {
        // `make test-pseudo` runs the width checks with doubled strings.
        _ = PseudoLocalization.isOn
    }

    private let locale = Locale(identifier: "en_GB")
    private let us = Locale(identifier: "en_US")

    // MARK: Text

    @Test("Text for each metric, and a dash before the first sample")
    func text() {
        #expect(MenuBarLayout.text(.cpu, value: 47.2, locale: locale) == "47%")
        #expect(MenuBarLayout.text(.memory, value: 82, locale: locale) == "82%")
        #expect(MenuBarLayout.text(.gpu, value: 0.2, locale: locale) == "<1%")
        #expect(MenuBarLayout.text(.network, value: 36000, locale: locale) == "36 kB/s")
        #expect(MenuBarLayout.text(.temperature, value: 61.6, locale: locale) == "62°")
        #expect(MenuBarLayout.text(.temperature, value: 50, locale: us) == "122°")
        #expect(MenuBarLayout.text(.cpu, value: nil, locale: locale) == "–")
        #expect(MenuBarLayout.text(.cpu, value: .nan, locale: locale) == "–")
    }

    @Test("Percentages stay within 0–100%, so they never outgrow their column")
    func clampsPercent() {
        #expect(MenuBarLayout.text(.cpu, value: 100.4, locale: locale) == "100%")
        #expect(MenuBarLayout.text(.battery, value: -3, locale: locale) == "0%")
    }

    @Test("The widest text per metric covers every unit")
    func widest() {
        #expect(MenuBarLayout.widestTexts(.cpu, locale: locale) == ["100%", "<1%"])
        #expect(MenuBarLayout.widestTexts(.network, locale: locale) == ["999 B/s", "999 kB/s", "999 MB/s", "999 GB/s"])
        #expect(MenuBarLayout.widestTexts(.temperature, locale: us) == ["230°"])
    }

    // MARK: Widths

    /// Every value a metric can plausibly show fits its slot, in both the figure and stacked sizes.
    @Test("No plausible value is wider than its slot", arguments: MenuBarMetric.allCases)
    func valuesFit(metric: MenuBarMetric) {
        let values: [Double] = switch metric {
        case .cpu, .memory, .gpu, .battery: stride(from: 0, through: 100, by: 0.5).map(\.self)
        case .network: (0 ..< 400).map { pow(10, Double($0) / 36) }
        case .temperature: stride(from: 20, through: 110, by: 0.5).map(\.self)
        }
        for locale in [locale, us] {
            let figure = MenuBarLayout.valueWidth(metric, .figure, locale: locale)
            let column = MenuBarLayout.columnWidth(metric, locale: locale)
            for value in values {
                let text = MenuBarLayout.text(metric, value: value, locale: locale)
                #expect(MenuBarLayout.width(of: text, .figure) <= figure, "\(text) in figure mode")
                #expect(MenuBarLayout.width(of: text, .value) <= column, "\(text) in a column")
            }
        }
    }

    @Test("A column is at least as wide as its label, in whole points")
    func columnCoversLabel() {
        for metric in MenuBarMetric.allCases {
            let column = MenuBarLayout.columnWidth(metric, locale: locale)
            #expect(column >= MenuBarLayout.width(of: metric.shortTitle, .label))
            #expect(column == column.rounded())
        }
    }

    @Test("The item's width depends on the settings, never on the values")
    func itemWidth() {
        let two = MenuBarLayout.itemWidth(.stacked, metric: .cpu, stacked: [.cpu, .memory], showsGlyph: true, graphShowsValue: true)
        let four = MenuBarLayout.itemWidth(
            .stacked, metric: .cpu, stacked: [.cpu, .memory, .gpu, .network], showsGlyph: true, graphShowsValue: true
        )
        let bare = MenuBarLayout.itemWidth(.stacked, metric: .cpu, stacked: [.cpu, .memory], showsGlyph: false, graphShowsValue: true)
        #expect(four > two)
        #expect(two - bare == Tokens.MenuBarItem.glyphWidth + Tokens.MenuBarItem.glyphSpacing)
        let graph = MenuBarLayout.itemWidth(.graph, metric: .cpu, stacked: [], showsGlyph: false, graphShowsValue: false)
        #expect(graph == MenuBarLayout.graphWidth + 2 * Tokens.MenuBarItem.horizontalInset)
        #expect(MenuBarLayout.itemWidth(.icon, metric: .cpu, stacked: [], showsGlyph: true, graphShowsValue: true) == 0)
    }

    @Test("Stacked columns fit the menu bar's height")
    func height() {
        let item = Tokens.MenuBarItem.self
        #expect(item.labelRow + item.valueRow == item.height)
        #expect(item.barHeight <= item.height)
    }

    // MARK: Graph

    @Test("One bar per recent sample, oldest first, padded on the left until there are enough")
    func bars() {
        #expect(MenuBarLayout.bars([50, 100], count: 4, top: 100) == [nil, nil, 0.5, 1])
        #expect(MenuBarLayout.bars([10, 20, 30, 40, 50], count: 3, top: 100) == [0.3, 0.4, 0.5])
        #expect(MenuBarLayout.bars([150, -5, .nan], count: 3, top: 100) == [1, 0, 0])
        #expect(MenuBarLayout.bars([1], count: 0, top: 100).isEmpty)
    }

    @Test("Percentages graph out of 100; network scales to its busiest sample, with a floor")
    func graphTop() {
        #expect(MenuBarLayout.graphTop(.cpu, values: [3, 4]) == 100)
        #expect(MenuBarLayout.graphTop(.network, values: [2000, 3000]) == MenuBarLayout.networkFloor)
        #expect(MenuBarLayout.graphTop(.network, values: [2e6, 5e6]) == 5e6)
        #expect(MenuBarLayout.graphTop(.network, values: []) == MenuBarLayout.networkFloor)
    }

    @Test("Bar heights snap to pixels and keep a visible stub")
    func barHeight() {
        #expect(MenuBarLayout.barHeight(0, maxHeight: 16, minimum: 1, scale: 2) == 1)
        #expect(MenuBarLayout.barHeight(0.51, maxHeight: 16, minimum: 1, scale: 2) == 8)
        #expect(MenuBarLayout.barHeight(0.52, maxHeight: 16, minimum: 1, scale: 2) == 8.5)
        #expect(MenuBarLayout.barHeight(0.52, maxHeight: 16, minimum: 1, scale: 1) == 8)
        #expect(MenuBarLayout.barHeight(1.2, maxHeight: 16, minimum: 1, scale: 2) == 16)
    }

    // MARK: Stacked list

    @Test("The checklist keeps order, caps at four, and never empties")
    func toggling() {
        #expect(MenuBarMetric.toggling(.cpu, on: true, in: [.memory]) == [.cpu, .memory])
        #expect(MenuBarMetric.toggling(.memory, on: false, in: [.cpu, .memory]) == [.cpu])
        #expect(MenuBarMetric.toggling(.cpu, on: false, in: [.cpu]) == [.cpu])
        let four: [MenuBarMetric] = [.cpu, .gpu, .memory, .network]
        #expect(MenuBarMetric.toggling(.battery, on: true, in: four) == four)
        #expect(MenuBarMetric.toggling(.gpu, on: true, in: four) == four)
    }

    @Test("Stored lists drop unknown names and repeats, and keep at most four")
    func decoding() {
        #expect(MenuBarMetric.decodeList("cpu,cpu,memory") == [.cpu, .memory])
        #expect(MenuBarMetric.decodeList("battery,cpu,memory,gpu,network") == [.battery, .cpu, .memory, .gpu])
        #expect(MenuBarMetric.decodeList(MenuBarMetric.stackedDefault) == [.cpu, .memory])
    }

    // MARK: Settings note

    @Test("Settings states the idle cost for every mode but the icon")
    func costNote() {
        #expect(MenuBarMode.icon.idleCostNote == nil)
        for mode in [MenuBarMode.figure, .graph, .stacked] {
            #expect(mode.idleCostNote?.contains("of one core") == true)
        }
    }
}

/// Renders the real image, to check what the pure functions promise.
@MainActor
@Suite("Menu bar image")
struct MenuBarImageTests {
    private func reading(_ values: [MenuBarMetric: Double], strain: StrainReason? = nil) -> LiveMetrics.MenuBarReading {
        var reading = LiveMetrics.MenuBarReading(strain: strain)
        for (metric, value) in values {
            reading.set(metric, value: value)
        }
        reading.graph[.cpu] = (0 ..< 30).map { Double($0 * 3) }
        return reading
    }

    /// Draws `image` into a bitmap at `scale` and counts the pixels it inked.
    private func inkedPixels(_ image: NSImage, scale: CGFloat) -> Int {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            return 0
        }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0 ..< rep.pixelsWide {
            for y in 0 ..< rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                inked += 1
            }
        }
        return inked
    }

    private func configuration(_ mode: MenuBarMode, stacked: [MenuBarMetric] = [.cpu, .memory]) -> MenuBarDisplay.Configuration {
        MenuBarDisplay.Configuration(mode: mode, metric: .network, stacked: stacked, showsGlyph: true, graphShowsValue: true)
    }

    @Test("Same size whatever the values, 22 pt tall, with 1x and 2x pixels", arguments: [MenuBarMode.figure, .graph, .stacked])
    func stableSize(mode: MenuBarMode) {
        let config = configuration(mode, stacked: [.cpu, .memory, .network, .temperature])
        let small = MenuBarImage.render(config, reading: reading([.cpu: 1, .memory: 2, .network: 0, .temperature: 30]))
        let large = MenuBarImage.render(config, reading: reading([.cpu: 100, .memory: 100, .network: 999e6, .temperature: 105]))
        let empty = MenuBarImage.render(config, reading: .empty)
        #expect(small.size == large.size)
        #expect(small.size == empty.size)
        #expect(small.size.height == Tokens.MenuBarItem.height)
        #expect(small.size.height <= NSStatusBar.system.thickness)
        #expect(small.size.width == config.width)
        #expect(small.representations.map(\.pixelsHigh).sorted() == [22, 44])
        // And both are drawn: they fill a 1x and a 2x bitmap with content.
        for scale in [1.0, 2.0] {
            #expect(inkedPixels(small, scale: scale) > 0)
        }
    }

    @Test("Template normally, so the menu bar tints it; colored under strain")
    func template() {
        let config = configuration(.stacked)
        #expect(MenuBarImage.render(config, reading: reading([.cpu: 5])).isTemplate)
        #expect(!MenuBarImage.render(config, reading: reading([.cpu: 95], strain: .cpu)).isTemplate)
    }

    @Test("VoiceOver reads the figures and the strain")
    func accessibility() {
        let text = configuration(.stacked).accessibilityText(reading([.cpu: 47, .memory: 82], strain: .memory))
        #expect(text == "Mactivity, CPU 47%, Memory 82%. Memory pressure is high")
    }
}
