import Core
import Foundation
import Testing
@testable import UI

/// The pure parts of the charts: sparkline bar layout, history binning, and the donut's rows.
@MainActor
@Suite("Chart logic")
struct ChartLogicTests {
    private static func fixture(_ name: String) throws -> [SeriesPoint] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try JSONDecoder().decode([SeriesPoint].self, from: Data(contentsOf: url))
    }

    // MARK: Sparkline

    @Test("Sparkline: one bar per sample, newest flush right, zero is a stub")
    func sparklineBars() throws {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
        let bars = SparklineLayout.bars(values: [0, 50, 100], domain: 0 ... 100, in: rect, barWidth: 2, gap: 1)
        #expect(bars.count == 3)
        let last = try #require(bars.last)
        #expect(last.maxX == rect.maxX)
        #expect(last.height == 40)
        #expect(bars[1].height == 20)
        // Zero: as tall as the bar is wide, on the baseline.
        #expect(bars[0].height == 2)
        #expect(bars[0].maxY == rect.maxY)
        #expect(bars[1].minX - bars[0].minX == 3)
    }

    @Test("Sparkline: samples that don't fit scroll off the left")
    func sparklineTrims() {
        let values = (0 ..< LiveMetrics.historyLength).map(Double.init)
        let bars = SparklineLayout.bars(values: values, domain: nil, in: CGRect(x: 0, y: 0, width: 35, height: 10), barWidth: 2, gap: 1.5)
        // (35 + 1.5) / 3.5 = 10.4 → the 10 newest.
        #expect(bars.count == 10)
        // Scaled to the visible samples (110...119), with headroom: the newest is the tallest.
        #expect(bars.last?.height == bars.map(\.height).max())
        #expect(bars.allSatisfy { $0.minX >= 0 })
    }

    @Test("Sparkline: never more than the history length, and nothing for no room or no data")
    func sparklineEdges() {
        let wide = CGRect(x: 0, y: 0, width: 2000, height: 10)
        let values = Array(repeating: 1.0, count: LiveMetrics.historyLength)
        #expect(SparklineLayout.bars(values: values, domain: 0 ... 100, in: wide).count == LiveMetrics.historyLength)
        #expect(SparklineLayout.bars(values: [], domain: 0 ... 100, in: wide).isEmpty)
        #expect(SparklineLayout.bars(values: values, domain: 0 ... 100, in: .zero).isEmpty)
    }

    // MARK: History binning

    @Test("Binning: average and peak per bin, gaps stay gaps")
    func binsFixture() throws {
        let points = try Self.fixture("history-series-gap.json")
        let bins = HistoryBinning.bins(points, interval: 300)
        #expect(bins.count == 3)
        #expect(bins[0].average == 30)
        #expect(bins[0].maximum == 90)
        #expect(bins[1].average == 5)
        #expect(bins[1].maximum == 6)
        #expect(bins[2].average == 75)
        #expect(bins[2].maximum == 100)
        // The empty 810000600 bin (the Mac asleep) has no bar.
        #expect(bins[2].start == Date(timeIntervalSinceReferenceDate: 810_000_900))
        #expect(bins[0].end == bins[1].start)
    }

    @Test("Binning: bins align to the local clock, not to the first point")
    func binsAlign() throws {
        let points = try Self.fixture("history-series-gap.json")
        // A zone 30 minutes off UTC moves bin edges by half an hour, not by the points.
        let bins = try HistoryBinning.bins(points, interval: 3600, timeZone: #require(TimeZone(secondsFromGMT: 1800)))
        let start = try #require(bins.first?.start)
        #expect((start.timeIntervalSinceReferenceDate + 1800).truncatingRemainder(dividingBy: 3600) == 0)
        #expect(bins.count == 1)
    }

    /// Every quarter-hour from `start` for `hours` hours.
    private static func quarters(from start: Date, hours: Int) -> [SeriesPoint] {
        stride(from: 0, to: TimeInterval(hours * 3600), by: 900).map { SeriesPoint(at: start + $0, average: 1, maximum: 1) }
    }

    @Test("Binning: days start at local midnight across a daylight-saving change (D-220)")
    func binsDaysAcrossDST() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        // Berlin's clocks go back on 2026-10-25; four days around it.
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23)))
        let bins = HistoryBinning.bins(Self.quarters(from: start, hours: 96), interval: 86400, timeZone: berlin)
        #expect(bins.count == 4)
        for bin in bins {
            #expect(calendar.dateComponents([.hour, .minute], from: bin.start) == DateComponents(hour: 0, minute: 0))
        }
        #expect(bins.map { $0.end.timeIntervalSince($0.start) / 3600 } == [24, 24, 25, 24])
        #expect(zip(bins, bins.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    @Test(
        "Binning: hours start on the hour in half-hour and quarter-hour zones",
        arguments: ["Asia/Kolkata", "Asia/Kathmandu", "America/St_Johns"]
    )
    func binsHalfHourZones(identifier: String) throws {
        let zone = try #require(TimeZone(identifier: identifier))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = Date(timeIntervalSince1970: 1_790_330_400)
        let bins = HistoryBinning.bins(Self.quarters(from: start, hours: 12), interval: 3600, timeZone: zone)
        #expect(bins.count >= 12)
        for bin in bins {
            #expect(calendar.component(.minute, from: bin.start) == 0)
        }
    }

    @Test("Binning: the hour the clocks go back is one bar, and bars still meet")
    func binsFallBack() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        // 2026-11-01: 1:00–2:00 happens twice in New York.
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let bins = HistoryBinning.bins(Self.quarters(from: start, hours: 6), interval: 3600, timeZone: newYork)
        #expect(bins.count == 5)
        #expect(bins[1].end.timeIntervalSince(bins[1].start) == 7200)
        #expect(zip(bins, bins.dropFirst()).allSatisfy { $0.end == $1.start })
        #expect(bins.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } == 6 * 3600)
    }

    @Test("Binning: a skipped local time reads as the moment the clocks jump")
    func localClockGap() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        // 2026-03-08: 2:00 jumps to 3:00 in New York, at 7:00 UTC.
        let midnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        var clock = LocalClock(timeZone: newYork)
        let wall = clock.local(midnight) + 2 * 3600
        #expect(clock.date(forLocal: wall) == Date(timeIntervalSince1970: 1_772_953_200))
        let bins = HistoryBinning.bins(Self.quarters(from: midnight, hours: 5), interval: 3600, timeZone: newYork)
        #expect(bins.count == 5)
        #expect(bins[1].end == bins[2].start)
        #expect(calendar.component(.hour, from: bins[2].start) == 3)
    }

    @Test("Binning: unsorted input gives the same bins")
    func binsUnsorted() throws {
        let points = try Self.fixture("history-series-gap.json")
        #expect(HistoryBinning.bins(points.reversed(), interval: 300) == HistoryBinning.bins(points, interval: 300))
    }

    @Test("Binning: every range, up to a year of hours, fits the bar budget", arguments: HistoryRange.allCases)
    func barBudget(range: HistoryRange) {
        let duration = TimeInterval(range.duration.components.seconds)
        let step: TimeInterval = switch range {
        case .h12, .h24: 60
        case .d7, .d30: 900
        case .d90, .y1: 3600
        }
        let now = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let points = stride(from: duration, to: 0, by: -step).map { SeriesPoint(at: now - $0, average: 1, maximum: 2) }
        for width in [CGFloat(180), 520, 2000] {
            for series in [1, 2] {
                let maxBins = HistoryBinning.maxBins(width: width, series: series)
                let interval = HistoryBinning.interval(for: duration, maxBins: maxBins)
                let bins = HistoryBinning.bins(points, interval: interval)
                // One more than the budget at most: the range rarely starts on a bin edge.
                #expect(bins.count <= maxBins + 1)
                #expect(bins.count * series <= Tokens.Layout.historyMaxBars + series)
                #expect(width / CGFloat(bins.count * series) >= Tokens.Layout.historyMinBarPitch * 0.9)
            }
        }
    }

    @Test("Binning: intervals are the shortest round one that fits")
    func intervals() {
        #expect(HistoryBinning.interval(for: 12 * 3600, maxBins: 173) == 300)
        #expect(HistoryBinning.interval(for: 30 * 86400, maxBins: 180) == 4 * 3600)
        #expect(HistoryBinning.interval(for: 30 * 86400, maxBins: 179) == 6 * 3600)
        #expect(HistoryBinning.interval(for: 30 * 86400, maxBins: 0) == 30 * 86400)
        #expect(HistoryBinning.interval(for: 90 * 86400, maxBins: 180) == 12 * 3600)
        #expect(HistoryBinning.interval(for: 365 * 86400, maxBins: 180) == 3 * 86400)
        #expect(HistoryBinning.interval(for: 365 * 86400, maxBins: 30) == 14 * 86400)
        #expect(HistoryBinning.maxBins(width: 540, series: 1) == 180)
        #expect(HistoryBinning.maxBins(width: 540, series: 2) == 90)
        #expect(HistoryBinning.maxBins(width: 0, series: 1) == 1)
    }

    @Test("Binning: consecutive marked bins merge into one span")
    func spans() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let bins = (0 ..< 6).map { index in
            HistoryBin(
                start: start + Double(index) * 60,
                end: start + Double(index + 1) * 60,
                average: 0,
                maximum: [0, 3, 3, 0, 3, 0][index]
            )
        }
        let spans = HistoryBinning.spans(bins) { $0.maximum >= 3 }
        #expect(spans == [HistorySpan(start: start + 60, end: start + 180), HistorySpan(start: start + 240, end: start + 300)])
    }

    @Test("Binning: series sit side by side inside their bin, with the gap around the group")
    func slots() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let bin = HistoryBin(start: start, end: start + 100, average: 1, maximum: 1)
        let only = HistoryBinning.slot(of: bin, series: 0, of: 1, gap: 0.2)
        #expect(only == HistorySpan(start: bin.start + 10, end: bin.start + 90))
        let first = HistoryBinning.slot(of: bin, series: 0, of: 2, gap: 0.2)
        let second = HistoryBinning.slot(of: bin, series: 1, of: 2, gap: 0.2)
        #expect(first.end == second.start)
        #expect(second.end == bin.start + 90)
    }

    @Test("Binning: the scrubbed bin, or the nearest across a gap")
    func scrub() throws {
        let bins = try HistoryBinning.bins(Self.fixture("history-series-gap.json"), interval: 300)
        #expect(HistoryBinning.bin(at: Date(timeIntervalSinceReferenceDate: 810_000_310), in: bins) == bins[1])
        #expect(HistoryBinning.bin(at: Date(timeIntervalSinceReferenceDate: 810_000_800), in: bins) == bins[2])
        #expect(HistoryBinning.bin(at: .now, in: []) == nil)
    }

    // MARK: Donut

    @Test("Donut: top four, then Other with the rest")
    func donutTop() {
        let entries = [3.0, 9, 1, 7, 5, 2].enumerated().map { DonutEntry(name: "App \($0.offset)", value: $0.element) }
        let rows = DonutEntries.top(entries, limit: 4)
        #expect(rows.map(\.value) == [9, 7, 5, 3, 3])
        #expect(rows.last == DonutEntry(name: "Other", value: 3, isRemainder: true))
        #expect(rows.reduce(0) { $0 + $1.value } == entries.reduce(0) { $0 + $1.value })
    }

    @Test("Donut: one left over gets its own row; zeros are left out")
    func donutSmall() {
        let entries = [4.0, 3, 2, 1, 0.5, 0].enumerated().map { DonutEntry(name: "App \($0.offset)", value: $0.element) }
        let rows = DonutEntries.top(entries, limit: 4)
        #expect(rows.count == 5)
        #expect(!rows.contains { $0.isRemainder })
        #expect(DonutEntries.top([DonutEntry(name: "Idle", value: 0)]).isEmpty)
    }

    @Test("Donut: the legend gets its width first, the ring the rest within its range")
    func donutRing() {
        let ring: ClosedRange<CGFloat> = 88 ... 116
        #expect(DonutRowLayout.diameter(available: 300, legend: 100, ring: ring, spacing: 16) == 116)
        #expect(DonutRowLayout.diameter(available: 244, legend: 130, ring: ring, spacing: 16) == 98)
        #expect(DonutRowLayout.diameter(available: 218, legend: 200, ring: ring, spacing: 16) == 88)
        #expect(DonutRowLayout.diameter(available: 50, legend: 200, ring: ring, spacing: 16) == 34)
    }
}
