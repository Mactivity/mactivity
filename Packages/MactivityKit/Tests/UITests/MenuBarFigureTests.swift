import AppKit
import Core
import Foundation
import Simulated
import Testing
@testable import UI

@MainActor
@Suite("Figure choices: the menu bar item")
struct MenuBarFigureTests {
    init() {
        // `make test-pseudo` runs the width checks with doubled strings.
        _ = PseudoLocalization.isOn
    }

    private let locale = Locale(identifier: "en_GB")
    private let us = Locale(identifier: "en_US")

    @Test("Automatic figures are today's text, and redraw exactly when today's did")
    func automaticIsToday() async {
        let source = SimulatedSnapshotSource()
        var systems: [SystemSample] = []
        for _ in 0 ..< 60 {
            await systems.append(source.next().system)
        }
        systems += FigureFixture.edgeSystems
        for system in systems {
            for metric in MenuBarMetric.allCases {
                let figure = MenuBarLayout.figure(metric, system, locale: locale)
                #expect(figure.text == MenuBarLayout.text(metric, value: LegacyFigures.menuBarValue(metric, system), locale: locale))
                #expect(figure.lines.isEmpty)
            }
        }
        for (old, new) in Array(zip(systems, systems.dropFirst(3))) + Array(zip(systems, systems.dropFirst())) {
            for metric in MenuBarMetric.allCases {
                var before = LiveMetrics.MenuBarReading()
                var after = LiveMetrics.MenuBarReading()
                before.figures[metric] = MenuBarLayout.figure(metric, old)
                after.figures[metric] = MenuBarLayout.figure(metric, new)
                #expect(
                    LiveMetrics.menuBarWorthRedrawing(from: before, to: after, shown: [metric])
                        == LegacyFigures.worthRedrawing(metric, from: old, to: new),
                    "\(metric)"
                )
            }
        }
    }

    @Test("Each choice's text in the menu bar")
    func texts() {
        let system = FigureFixture.system()
        func text(_ metric: MenuBarMetric, _ choices: FigureChoices, _ system: SystemSample = FigureFixture.system()) -> String {
            MenuBarLayout.figure(metric, system, choices: choices, locale: us).text
        }
        #expect(text(.memory, FigureChoices(memory: .used)) == "20 GB")
        #expect(text(.memory, FigureChoices(memory: .percent)) == "56%")
        #expect(text(.memory, FigureChoices(memory: .pressure)) == "Normal")
        #expect(text(.memory, FigureChoices(memory: .pressure), FigureFixture.system(memory: FigureFixture.memory(pressure: .warning))) ==
            "Elevated")
        #expect(text(.network, .automatic) == "1.1 MB/s")
        #expect(text(.network, FigureChoices(network: .both)) == "↓1.0 MB/s ↑114 kB/s")
        #expect(MenuBarLayout.figure(.network, system, choices: FigureChoices(network: .both), locale: us).lines == [
            "↓1.0 MB/s",
            "↑114 kB/s",
        ])
        #expect(text(.network, FigureChoices(network: .download)) == "↓1.0 MB/s")
        #expect(text(.network, FigureChoices(network: .upload)) == "↑114 kB/s")
        #expect(text(.battery, FigureChoices(battery: .timeLeft)) == "5h 30m")
        #expect(text(.battery, FigureChoices(battery: .percentAndTime)) == "84% · 5h 30m")
        #expect(text(.battery, FigureChoices(battery: .power)) == "11 W")
        let charging = FigureFixture.system(battery: FigureFixture.battery(source: .ac, charging: true, seconds: 2400, watts: 0))
        #expect(text(.battery, FigureChoices(battery: .timeLeft), charging) == "Charging")
        #expect(text(.battery, FigureChoices(battery: .percentAndTime), charging) == "84% · Charging")
        #expect(text(.battery, FigureChoices(battery: .timeLeft), FigureFixture.system(battery: nil)) == "–")
        #expect(text(.temperature, .automatic) == "129°")
        #expect(MenuBarLayout.figure(.temperature, system, choices: FigureChoices(temperature: .gpu), locale: locale).text == "47°")
        #expect(MenuBarLayout.figure(.temperature, system, choices: FigureChoices(temperature: .hottest), locale: locale).text == "71°")
        #expect(text(.temperature, FigureChoices(temperature: .gpu), FigureFixture.system(sensors: FigureFixture.sensors(gpu: nil))) == "–")
    }

    @Test("Redraws: a chosen figure redraws when its text moves past its band")
    func bands() {
        func worth(_ metric: MenuBarMetric, _ choices: FigureChoices, _ old: SystemSample, _ new: SystemSample) -> Bool {
            var before = LiveMetrics.MenuBarReading()
            var after = LiveMetrics.MenuBarReading()
            before.figures[metric] = MenuBarLayout.figure(metric, old, choices: choices)
            after.figures[metric] = MenuBarLayout.figure(metric, new, choices: choices)
            return LiveMetrics.menuBarWorthRedrawing(from: before, to: after, shown: [metric])
        }
        let both = FigureChoices(network: .both)
        // Either direction moving far enough redraws; small moves in both don't.
        #expect(worth(.network, both, FigureFixture.system(), FigureFixture.system(outBPS: 900_000)))
        #expect(worth(.network, both, FigureFixture.system(), FigureFixture.system(inBPS: 3_000_000)))
        #expect(!worth(.network, both, FigureFixture.system(), FigureFixture.system(inBPS: 1_100_000, outBPS: 118_000)))
        let time = FigureChoices(battery: .timeLeft)
        let later = { (minutes: Int64) in FigureFixture.system(battery: FigureFixture.battery(seconds: minutes * 60)) }
        #expect(!worth(.battery, time, later(330), later(325)))
        #expect(worth(.battery, time, later(330), later(290)))
        #expect(worth(.battery, time, later(330), FigureFixture.system(battery: FigureFixture.battery(source: .ac, charging: true))))
        let pressure = FigureChoices(memory: .pressure)
        #expect(worth(.memory, pressure, FigureFixture.system(), FigureFixture.system(memory: FigureFixture.memory(pressure: .warning))))
        #expect(!worth(
            .memory,
            pressure,
            FigureFixture.system(),
            FigureFixture.system(memory: FigureFixture.memory(used: 30 * FigureFixture.gib))
        ))
        let used = FigureChoices(memory: .used)
        // 20 → 20.6 GB of 36 is under two points: the text moves, the band holds.
        #expect(!worth(
            .memory,
            used,
            FigureFixture.system(),
            FigureFixture.system(memory: FigureFixture.memory(used: 20 * FigureFixture.gib + 650_000_000))
        ))
        #expect(worth(
            .memory,
            used,
            FigureFixture.system(),
            FigureFixture.system(memory: FigureFixture.memory(used: 22 * FigureFixture.gib))
        ))
        let power = FigureChoices(battery: .power)
        #expect(!worth(.battery, power, FigureFixture.system(), FigureFixture.system(battery: FigureFixture.battery(watts: 12.2))))
        #expect(worth(.battery, power, FigureFixture.system(), FigureFixture.system(battery: FigureFixture.battery(watts: 18))))
    }

    /// Plausible systems at the far ends of every figure, for the width checks.
    private func extremes(_ metric: MenuBarMetric) -> [SystemSample] {
        let rates = (0 ..< 400).map { pow(10, Double($0) / 36) }
        switch metric {
        case .cpu, .gpu:
            return stride(from: 0, through: 100, by: 0.5).map { FigureFixture.system(cpu: $0, gpu: $0) }
        case .memory:
            let gib = Double(FigureFixture.gib)
            let sizes = (0 ..< 300).map { pow(10, Double($0) / 50) * 1_048_576 }.filter { $0 <= 512 * gib }
            return sizes.map { FigureFixture.system(memory: FigureFixture.memory(used: UInt64($0), total: 512 * FigureFixture.gib)) }
                + [MemoryPressure.normal, .warning, .critical].map { FigureFixture.system(memory: FigureFixture.memory(pressure: $0)) }
        case .network:
            return rates.flatMap { rate in
                [FigureFixture.system(inBPS: rate, outBPS: rate), FigureFixture.system(inBPS: rate, outBPS: 999e9 - rate)]
            }
        case .battery:
            let seconds = (0 ..< 200).map { Int64(pow(10, Double($0) / 30)) }.filter { $0 < 65535 * 60 }
            let watts = (0 ..< 100).map { pow(10, Double($0) / 40) - 1 }
            return seconds.map { FigureFixture.system(battery: FigureFixture.battery(percent: 100, seconds: $0)) }
                + watts.map { FigureFixture.system(battery: FigureFixture.battery(percent: 100, watts: $0)) }
                + stride(from: 0, through: 100, by: 0.5).map { FigureFixture.system(battery: FigureFixture.battery(percent: $0)) }
                + FigureFixture.edgeSystems
        case .temperature:
            return stride(from: 20, through: 110, by: 0.5).map { FigureFixture.system(sensors: FigureFixture.sensors(
                cpu: $0,
                gpu: $0,
                other: $0
            )) }
                + [FigureFixture.system(sensors: nil)]
        }
    }

    @Test("No choice's text is wider than the room made for it", arguments: MenuBarMetric.allCases)
    func widths(metric: MenuBarMetric) {
        let systems = extremes(metric)
        for choices in allFigureChoices + [.automatic] {
            for locale in [locale, us] {
                let figure = MenuBarLayout.valueWidth(metric, .figure, choices: choices, locale: locale)
                let column = MenuBarLayout.columnWidth(metric, choices: choices, locale: locale)
                let twoLines = MenuBarLayout.showsTwoLines(metric, choices: choices)
                for system in systems {
                    let shown = MenuBarLayout.figure(metric, system, choices: choices, locale: locale)
                    #expect(MenuBarLayout.width(of: shown.text, .figure) <= figure, "\(shown.text) in figure mode")
                    if twoLines {
                        #expect(shown.lines.count == 2)
                        for line in shown.lines {
                            #expect(MenuBarLayout.width(of: line, .line) <= column, "\(line) in a two-line column")
                        }
                    } else {
                        #expect(MenuBarLayout.width(of: shown.text, .value) <= column, "\(shown.text) in a column")
                    }
                }
            }
        }
    }

    @Test("Two lines fit the menu bar's height")
    func lineHeight() {
        #expect(2 * Tokens.MenuBarItem.lineRow == Tokens.MenuBarItem.height)
    }

    @Test("Automatic widths are today's")
    func automaticWidths() {
        for metric in MenuBarMetric.allCases {
            #expect(MenuBarLayout.widestTexts(metric, choices: .automatic, locale: locale) == MenuBarLayout.widestTexts(
                metric,
                locale: locale
            ))
        }
        #expect(MenuBarLayout.widestTexts(.network, locale: locale) == ["999 B/s", "999 kB/s", "999 MB/s", "999 GB/s"])
        // "<1%" is never the wider in English; it's there for translations.
        #expect(MenuBarLayout.widestTexts(.memory, locale: locale) == ["100%", "<1%"])
        #expect(MenuBarLayout.widestTexts(.battery, locale: locale) == ["100%"])
    }
}

@MainActor
@Suite("Figure choices: live readings and the image")
struct FigureChoicesLiveTests {
    @Test("Changing a choice redraws the item straight away, even while idle")
    func choiceRedraws() {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true)
        let snapshot = FigureFixture.snapshot()
        metrics.apply(snapshot)
        #expect(metrics.menuBar.text(for: .memory) == Formatters.percent(20.0 / 36 * 100))
        metrics.figureChoices = FigureChoices(memory: .used, network: .both)
        #expect(metrics.menuBar.text(for: .memory) == Formatters.memory(20 * FigureFixture.gib))
        #expect(metrics.menuBar.figures[.network]?.lines.count == 2)
    }

    @Test("The image keeps its size whatever the values, with any choice", arguments: [MenuBarMode.figure, .graph, .stacked])
    func stableSize(mode: MenuBarMode) {
        for choices in allFigureChoices {
            let config = MenuBarDisplay.Configuration(
                mode: mode, metric: .battery, stacked: [.memory, .network, .battery, .temperature], showsGlyph: true,
                graphShowsValue: true, choices: choices
            )
            func reading(_ system: SystemSample) -> LiveMetrics.MenuBarReading {
                var reading = LiveMetrics.MenuBarReading()
                for metric in MenuBarMetric.allCases {
                    reading.figures[metric] = MenuBarLayout.figure(metric, system, choices: choices)
                }
                return reading
            }
            let small = MenuBarImage.render(config, reading: reading(FigureFixture.system(inBPS: 0, outBPS: 0)))
            let large = MenuBarImage.render(config, reading: reading(FigureFixture.system(
                memory: FigureFixture.memory(used: 500 * FigureFixture.gib, total: 512 * FigureFixture.gib), inBPS: 999e6, outBPS: 999e6,
                battery: FigureFixture.battery(percent: 100, seconds: 23 * 3600 + 59 * 60)
            )))
            #expect(small.size == large.size)
            #expect(small.size.width == config.width)
        }
    }
}
