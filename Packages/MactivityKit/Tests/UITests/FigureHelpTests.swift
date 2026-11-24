import Core
import Foundation
import Testing
@testable import UI

/// Explanations on the less obvious figures, and what VoiceOver reads for charts.
@MainActor
@Suite("Figure help and spoken charts")
struct FigureHelpTests {
    @Test("Every memory figure explains itself")
    func memory() {
        let figures = MetricTab.memory.figures(FigureFixture.snapshot())
        #expect(figures.count == 6)
        #expect(figures.allSatisfy { $0.help?.isEmpty == false })
    }

    @Test("CPU: the core clusters and the load average explain themselves; User, System, Idle don't need to")
    func cpu() {
        var system = FigureFixture.system()
        system = SystemSample(
            cpu: CPUStats(
                totalPercent: 20, userPercent: 15, systemPercent: 5, perCorePercent: [20, 20],
                clusters: [
                    CoreCluster(name: "Super", level: 0, coreIndexes: [0], percent: 30),
                    CoreCluster(name: "Performance", level: 1, coreIndexes: [1], percent: 10),
                    CoreCluster(name: "Mystery", level: 2, coreIndexes: [], percent: 0),
                ],
                loadAverage: LoadAverage(one: 1, five: 2, fifteen: 3)
            ),
            memory: system.memory, disk: system.disk, network: system.network, gpu: system.gpu,
            battery: system.battery, sensors: system.sensors, thermal: system.thermal, uptime: system.uptime
        )
        let figures = MetricTab.cpu.figures(FigureFixture.snapshot(system))
        let helped = figures.filter { $0.help != nil }.map(\.label)
        #expect(helped == ["Super cores (1)", "Performance cores (1)", "Load average"])
    }

    @Test("Energy Impact explains itself on a Mac without a battery")
    func energyImpact() throws {
        let snapshot = FigureFixture.snapshot(FigureFixture.system(battery: nil))
        let figure = try #require(MetricTab.battery.figures(snapshot).first)
        #expect(figure.label == Metric.energyImpact.title)
        #expect(figure.help?.contains("Activity Monitor") == true)
    }

    @Test("The hover text is the whole figure, then what it means")
    func hoverText() {
        #expect(Figure("Interface", "en0").hoverText == "Interface: en0")
        #expect(Figure("Wired", "3 GB", help: "Kept for macOS.").hoverText == "Wired: 3 GB\nKept for macOS.")
    }

    @Test("Sparkline trend: a move of more than a tenth of the range", arguments: [
        ([Double](), SparklineTrend.steady),
        ([50], .steady),
        ([10, 10, 10, 10, 10, 40, 40, 40, 40, 40], .rising),
        ([40, 40, 40, 40, 40, 10, 10, 10, 10, 10], .falling),
        ([40, 42, 41, 40, 43, 44, 42, 45, 43, 44], .steady),
    ])
    func trend(values: [Double], expected: SparklineTrend) {
        #expect(SparklineLayout.trend(values, domain: 0 ... 100) == expected)
    }

    @Test("A sparkline reads its latest value and trend; without a unit, nothing extra")
    func spokenSparkline() {
        let rising = [10.0, 10, 10, 10, 10, 40, 40, 40, 40, 42]
        #expect(SparklineLayout.spokenValue(rising, domain: 0 ... 100, unit: .percent) == "Latest \(Formatters.percent(42)), rising")
        #expect(SparklineLayout.spokenValue(rising, domain: 0 ... 100, unit: nil).isEmpty)
        #expect(SparklineLayout.spokenValue([], domain: 0 ... 100, unit: .percent).isEmpty)
    }

    @Test("A history chart reads the range's average, and its peak and when")
    func historySummary() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let points = [
            SeriesPoint(at: start, average: 10, maximum: 20),
            SeriesPoint(at: start + 60, average: 30, maximum: 90),
            SeriesPoint(at: start + 120, average: 20, maximum: 25),
        ]
        let text = try #require(HistoryStrip.spokenSummary(points, metric: .cpu, range: .h12))
        let peakTime = (start + 60).formatted(date: .omitted, time: .shortened)
        #expect(text == "Average \(Formatters.metric(20, .cpu)), peak \(Formatters.metric(90, .cpu)) at \(peakTime)")
        #expect(HistoryStrip.spokenSummary([], metric: .cpu, range: .h12) == nil)
    }
}
