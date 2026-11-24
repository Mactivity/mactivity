import AppKit
import Core

/// Text and sizes for the menu bar item's small displays (spec 4.1).
///
/// Widths come from font metrics and the widest text a metric can produce, never from the value
/// on screen, so the item keeps its width as figures change and never nudges its neighbors.
public enum MenuBarLayout {

    // MARK: Text

    /// What a metric shows in the menu bar. "–" until there's a value.
    public static func text(_ metric: MenuBarMetric, value: Double?, locale: Locale = .current) -> String {
        guard let value, value.isFinite else {
            return "–"
        }
        switch metric {
        case .cpu, .memory, .gpu, .battery: return Formatters.percent(min(100, max(0, value)), locale: locale)
        case .network: return Formatters.rate(value, locale: locale)
        case .temperature: return Formatters.temperature(celsius: value, locale: locale)
        }
    }

    /// What `metric` shows for `choices`, with the numbers its redraw band compares (D-068).
    /// Automatic gives exactly `text(_:value:)` and today's bands.
    public static func figure(
        _ metric: MenuBarMetric, _ system: SystemSample, choices: FigureChoices = .automatic, locale: Locale = .current
    ) -> MenuBarFigure {
        switch metric {
        case .cpu:
            return automatic(.cpu, value: system.cpu.totalPercent, locale: locale)
        case .gpu:
            return automatic(.gpu, value: system.gpu?.utilizationPercent, locale: locale)
        case .temperature:
            return automatic(.temperature, value: choices.temperature.celsius(system.sensors), locale: locale)
        case .memory:
            return memoryFigure(system.memory, choice: choices.memory, locale: locale)
        case .network:
            return networkFigure(system.network, choice: choices.network, locale: locale)
        case .battery:
            return batteryFigure(system.battery, choice: choices.battery, locale: locale)
        }
    }

    /// The usual figure: `text(_:value:)`, banded on the same value.
    public static func automatic(_ metric: MenuBarMetric, value: Double?, locale: Locale = .current) -> MenuBarFigure {
        let band: (Double) -> MenuBarFigure.Band = switch metric {
        case .cpu, .gpu, .memory, .battery: MenuBarFigure.Band.points
        case .temperature: MenuBarFigure.Band.degrees
        case .network: MenuBarFigure.Band.rate
        }
        // A non-finite value shows "–", which has no number to band.
        return MenuBarFigure(text: text(metric, value: value, locale: locale), band: value.flatMap { $0.isFinite ? [band($0)] : nil } ?? [])
    }

    private static func memoryFigure(_ memory: MemoryStats, choice: MemoryFigure, locale: Locale) -> MenuBarFigure {
        let percent = memory.usedFraction * 100
        switch choice {
        case .automatic, .percent:
            return automatic(.memory, value: percent, locale: locale)
        case .used:
            // Banded on the percentage, so a few hundred MB either way doesn't redraw.
            return MenuBarFigure(text: Formatters.memory(memory.usedBytes, locale: locale), band: [.points(percent)])
        case .pressure:
            // Three words; any change redraws.
            return MenuBarFigure(text: memory.status.title, band: [])
        }
    }

    private static func networkFigure(_ network: NetworkStats, choice: NetworkFigure, locale: Locale) -> MenuBarFigure {
        let down = Formatters.download(network.inBPS, compact: true, locale: locale)
        let up = Formatters.upload(network.outBPS, compact: true, locale: locale)
        switch choice {
        case .automatic:
            return automatic(.network, value: network.inBPS + network.outBPS, locale: locale)
        case .both:
            return MenuBarFigure(text: "\(down) \(up)", lines: [down, up], band: [.rate(network.inBPS), .rate(network.outBPS)])
        case .download:
            return MenuBarFigure(text: down, band: [.rate(network.inBPS)])
        case .upload:
            return MenuBarFigure(text: up, band: [.rate(network.outBPS)])
        }
    }

    private static func batteryFigure(_ battery: BatteryStats?, choice: BatteryFigure, locale: Locale) -> MenuBarFigure {
        guard let battery else {
            return automatic(.battery, value: nil, locale: locale)
        }
        let percent = automatic(.battery, value: battery.percent, locale: locale)
        // On battery the estimate; on the adapter the charge state, which has no number.
        let time = battery.source == .battery ? battery.timeRemaining.map { MenuBarFigure.Band.duration($0) } : nil
        switch choice {
        case .automatic, .percent:
            return percent
        case .timeLeft:
            return MenuBarFigure(text: Formatters.batteryTime(battery), band: time.map { [$0] } ?? [])
        case .percentAndTime:
            return MenuBarFigure(
                text: "\(percent.text) · \(Formatters.batteryTime(battery))", band: percent.band + (time.map { [$0] } ?? [])
            )
        case .power:
            let watts = battery.source == .battery ? battery.powerDrawWatts.map { MenuBarFigure.Band.watts($0) } : nil
            return MenuBarFigure(text: Formatters.batteryPower(battery, locale: locale), band: watts.map { [$0] } ?? [])
        }
    }

    /// The widest texts `figure(_:_:choices:)` gives a metric. Digits are monospaced, so the
    /// largest value in each unit stands for every value in it; words are listed outright.
    public static func widestTexts(_ metric: MenuBarMetric, choices: FigureChoices = .automatic, locale: Locale = .current) -> [String] {
        switch metric {
        case .cpu, .gpu:
            return percentTexts(metric, locale: locale)
        case .memory:
            switch choices.memory {
            case .automatic, .percent: return percentTexts(.memory, locale: locale)
            // MB go up to 1,023 before GB start; GB stay at three digits, since used memory can't
            // pass the largest Mac's 512 GB.
            case .used: return [1023 * 1_048_576, 999 * 1_073_741_824].map { Formatters.memory(Double($0), locale: locale) }
            case .pressure: return [MetricStatus.normal, .elevated, .critical].map(\.title)
            }
        case .network:
            // 999 in each unit: 999.6 would round up into the next unit.
            let rates = [999.0, 999e3, 999e6, 999e9]
            switch choices.network {
            case .automatic: return rates.map { text(.network, value: $0, locale: locale) }
            case .download: return rates.map { Formatters.download($0, compact: true, locale: locale) }
            case .upload: return rates.map { Formatters.upload($0, compact: true, locale: locale) }
            // Each direction's widest is the same unit's, so pairing units covers every pair.
            case .both: return rates.map {
                    "\(Formatters.download($0, compact: true, locale: locale)) \(Formatters.upload($0, compact: true, locale: locale))"
                }
            }
        case .battery:
            let percent = text(.battery, value: 100, locale: locale)
            switch choices.battery {
            case .automatic, .percent: return [percent]
            case .timeLeft: return batteryTimeTexts
            case .percentAndTime: return batteryTimeTexts.map { "\(percent) · \($0)" }
            case .power:
                // 999 mW and 999 W stand for every draw; on the adapter, the charge state.
                return [0.999, 999].map { Formatters.power(milliwatts: $0 * 1000, locale: locale) } + batteryStateTexts
            }
        case .temperature:
            // Three digits in either scale: 110 °C is past any Mac's throttle point.
            return [text(.temperature, value: 110, locale: locale)]
        }
    }

    /// 100% and "<1%": the latter is a localized phrase, which a translation can make the wider.
    private static func percentTexts(_ metric: MenuBarMetric, locale: Locale) -> [String] {
        [text(metric, value: 100, locale: locale), text(metric, value: 0.1, locale: locale)]
    }

    /// Every width a battery's time left takes: hours and minutes, days and hours (the battery's
    /// own estimate isn't capped at 20 h), and the charge states. No text has more digits. All
    /// localized, as drawn, so a longer translation widens the item instead of clipping.
    private static let batteryTimeTexts = [
        Formatters.duration(.seconds(23 * 3600 + 59 * 60)), Formatters.duration(.seconds(99 * 86400 + 23 * 3600)),
    ] + batteryStateTexts

    /// "Charging", "Full", "Not charging", "–" in the app's language: the same strings `Formatters` draws.
    private static let batteryStateTexts = Formatters.batteryStateTexts

    /// Stacked mode's two-line column (network both ways): the widest line of each kind.
    public static func widestLines(_ metric: MenuBarMetric, choices: FigureChoices = .automatic, locale: Locale = .current) -> [String] {
        guard showsTwoLines(metric, choices: choices) else {
            return []
        }
        return [999.0, 999e3, 999e6, 999e9].flatMap {
            [Formatters.download($0, compact: true, locale: locale), Formatters.upload($0, compact: true, locale: locale)]
        }
    }

    /// Network both ways stacks download over upload in its column, in place of label and value.
    public static func showsTwoLines(_ metric: MenuBarMetric, choices: FigureChoices) -> Bool {
        metric == .network && choices.network == .both
    }

    // MARK: Fonts

    public enum Style: Sendable {
        case figure, label, value, line

        public var font: NSFont {
            let item = Tokens.MenuBarItem.self
            return switch self {
            case .figure: NSFont.monospacedDigitSystemFont(ofSize: item.figureSize, weight: item.figureWeight)
            case .label: NSFont.systemFont(ofSize: item.labelSize, weight: item.labelWeight)
            case .value: NSFont.monospacedDigitSystemFont(ofSize: item.valueSize, weight: item.valueWeight)
            case .line: NSFont.monospacedDigitSystemFont(ofSize: item.lineSize, weight: item.valueWeight)
            }
        }
    }

    /// Rounded up to whole points, so a column's edge falls on the pixel grid at 1x and 2x.
    public static func width(of text: String, _ style: Style) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: style.font]).width)
    }

    /// Room for any value the metric can show in `style`.
    public static func valueWidth(
        _ metric: MenuBarMetric, _ style: Style, choices: FigureChoices = .automatic, locale: Locale = .current
    ) -> CGFloat {
        widestTexts(metric, choices: choices, locale: locale).map { width(of: $0, style) }.max() ?? 0
    }

    /// A stacked column: the wider of its label and its widest value, or its widest line when it
    /// stacks two values.
    public static func columnWidth(_ metric: MenuBarMetric, choices: FigureChoices = .automatic, locale: Locale = .current) -> CGFloat {
        if showsTwoLines(metric, choices: choices) {
            return widestLines(metric, choices: choices, locale: locale).map { width(of: $0, .line) }.max() ?? 0
        }
        return max(width(of: metric.shortTitle, .label), valueWidth(metric, .value, choices: choices, locale: locale))
    }

    // MARK: Graph

    /// The top of graph mode's scale. Percentages are out of 100; network scales to the busiest
    /// recent sample, but never below `networkFloor`, so a trickle doesn't fill the graph.
    public static func graphTop(_ metric: MenuBarMetric, values: [Double]) -> Double {
        switch metric {
        case .network: max(values.max() ?? 0, networkFloor)
        case .cpu, .memory, .gpu, .battery, .temperature: 100
        }
    }

    /// 100 kB/s.
    public static let networkFloor: Double = 100_000

    /// One bar per recent sample, oldest first, as a fraction of `top` in 0...1. Always `count`
    /// long: slots without a sample yet (just after launch) are `nil`, on the left.
    public static func bars(_ values: [Double], count: Int, top: Double) -> [Double?] {
        guard count > 0 else {
            return []
        }
        let recent = values.suffix(count).map { value -> Double? in
            guard value.isFinite, top > 0 else {
                return 0
            }
            return min(1, max(0, value / top))
        }
        return Array(repeating: nil, count: count - recent.count) + recent
    }

    /// A bar's height in points, snapped to whole pixels at `scale` and never below `minimum`,
    /// so an idle sample still shows as a stub on the baseline.
    public static func barHeight(_ fraction: Double, maxHeight: CGFloat, minimum: CGFloat, scale: CGFloat) -> CGFloat {
        let pixels = max(1, scale)
        let snapped = (CGFloat(fraction) * maxHeight * pixels).rounded() / pixels
        return min(maxHeight, max(minimum, snapped))
    }

    public static var graphWidth: CGFloat {
        let item = Tokens.MenuBarItem.self
        return CGFloat(item.barCount) * item.barWidth + CGFloat(item.barCount - 1) * item.barGap
    }

    // MARK: Whole item

    /// The item's width in points. Depends only on the settings, never on the values shown.
    public static func itemWidth(
        _ mode: MenuBarMode,
        metric: MenuBarMetric,
        stacked: [MenuBarMetric],
        showsGlyph: Bool,
        graphShowsValue: Bool,
        choices: FigureChoices = .automatic,
        locale: Locale = .current
    ) -> CGFloat {
        let item = Tokens.MenuBarItem.self
        var parts: [CGFloat] = showsGlyph ? [item.glyphWidth] : []
        switch mode {
        case .icon:
            return 0
        case .figure:
            parts.append(valueWidth(metric, .figure, choices: choices, locale: locale))
        case .graph:
            parts.append(graphWidth)
            if graphShowsValue {
                parts.append(valueWidth(metric, .figure, choices: choices, locale: locale))
            }
        case .stacked:
            let columns = stacked.map { columnWidth($0, choices: choices, locale: locale) }
            let content = columns.reduce(0, +) + CGFloat(max(0, columns.count - 1)) * item.columnSpacing
            parts.append(content)
        }
        return parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * item.glyphSpacing + 2 * item.horizontalInset
    }
}

/// One menu bar figure: its text, formatted once per reading, and the numbers that decide whether
/// a new reading is worth a redraw (`LiveMetrics.menuBarWorthRedrawing`, D-068).
public struct MenuBarFigure: Equatable, Sendable {
    /// A number and how far it has to move before the item redraws for it.
    public enum Band: Equatable, Sendable {
        /// Percent, 0...100: 2 points.
        case points(Double)
        /// °C: 2°.
        case degrees(Double)
        /// Bytes per second: a quarter, or 10 kB/s.
        case rate(Double)
        /// Seconds left: a tenth, or 10 minutes; battery estimates wander.
        case seconds(Double)
        /// Watts: a tenth, or 1 W.
        case watts(Double)

        static func duration(_ duration: Duration) -> Band {
            .seconds(Double(duration.components.seconds))
        }

        /// Whether `new` is too close to `self` to be worth a redraw. Different kinds never are.
        func contains(_ new: Band) -> Bool {
            switch (self, new) {
            case let (.points(old), .points(new)), let (.degrees(old), .degrees(new)): abs(new - old) < 2
            case let (.rate(old), .rate(new)): abs(new - old) < max(old * 0.25, 10000)
            case let (.seconds(old), .seconds(new)): abs(new - old) < max(old * 0.1, 600)
            case let (.watts(old), .watts(new)): abs(new - old) < max(old * 0.1, 1)
            default: false
            }
        }
    }

    public var text: String
    /// Stacked mode's two-line column (network both ways): download over upload. Empty otherwise.
    public var lines: [String] = []
    /// One per number in the text. Empty when the text has none ("Normal", "Charging", "–"):
    /// then any change of text redraws.
    public var band: [Band]

    public init(text: String, lines: [String] = [], band: [Band]) {
        self.text = text
        self.lines = lines
        self.band = band
    }

    /// Every number moved less than its band. False when the numbers don't line up (a figure
    /// gained or lost one), or there are none.
    func isWithinBand(of old: MenuBarFigure) -> Bool {
        !band.isEmpty && band.count == old.band.count && zip(old.band, band).allSatisfy { $0.contains($1) }
    }
}
