import Core
import Foundation

/// One bar of a history strip: the points whose time falls in `start ..< end`.
struct HistoryBin: Hashable, Sendable {
    let start: Date
    let end: Date
    /// Mean of the points' averages. Points in one range come from one tier, so each spans the
    /// same time and weighs the same.
    let average: Double
    /// Highest of the points' peaks.
    let maximum: Double

    var middle: Date {
        start + end.timeIntervalSince(start) / 2
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

/// A run of consecutive marked bins, e.g. where thermal pressure was serious or worse.
struct HistorySpan: Hashable, Sendable {
    let start: Date
    let end: Date
}

/// Bins a history series into bars. Thirty days of quarter-hour points is about 2,900 of them,
/// far too many bars to draw or to tell apart; a strip shows at most `Tokens.Layout.historyMaxBars`.
enum HistoryBinning {
    /// Bar widths a strip may use, shortest first: round numbers on a clock.
    static let intervals: [TimeInterval] = [
        60, 120, 300, 600, 900, 1200, 1800,
        3600, 2 * 3600, 3 * 3600, 4 * 3600, 6 * 3600, 8 * 3600, 12 * 3600, 24 * 3600,
        // A year in at most 180 bars, or in a narrow strip (D-089).
        2 * 86400, 3 * 86400, 7 * 86400, 14 * 86400, 30 * 86400,
    ]

    /// How many bins fit a plot `width` points wide: at most `cap` bars, none closer than
    /// `minPitch`, shared among `series` side-by-side bars per bin.
    static func maxBins(
        width: CGFloat,
        series: Int,
        cap: Int = Tokens.Layout.historyMaxBars,
        minPitch: CGFloat = Tokens.Layout.historyMinBarPitch
    ) -> Int {
        guard width.isFinite, width > 0, minPitch > 0 else {
            return 1
        }
        return max(1, min(cap, Int(width / minPitch)) / max(1, series))
    }

    /// The shortest interval that splits `duration` into at most `maxBins` bins.
    static func interval(for duration: TimeInterval, maxBins: Int) -> TimeInterval {
        let longest = intervals[intervals.count - 1]
        guard maxBins > 0 else {
            return longest
        }
        return intervals.first { duration / $0 <= Double(maxBins) } ?? longest
    }

    /// Average and peak of `points` per `interval`. Bins are aligned to the clock in `timeZone`
    /// (an hour's bin starts on the hour, a day's at midnight), so bars stay put as new points
    /// arrive. Each point is placed by its own date's offset, so a range across a daylight-saving
    /// change or in a half-hour zone still bins by the Mac's clock (D-220): a bin's edges are
    /// local times turned back into dates, and the day the clocks change is 23 or 25 hours wide.
    /// Bins with no points (the Mac was asleep) have no bar.
    static func bins(_ points: [SeriesPoint], interval: TimeInterval, timeZone: TimeZone = .gmt) -> [HistoryBin] {
        guard interval > 0, !points.isEmpty else {
            return []
        }
        let sorted = points.isSorted { $0.at <= $1.at } ? points : points.sorted { $0.at < $1.at }
        var clock = LocalClock(timeZone: timeZone)
        var bins: [HistoryBin] = []
        var key: Double?
        var sum = 0.0
        var count = 0
        var peak = -Double.infinity

        func flush() {
            guard let key, count > 0 else {
                return
            }
            let start = clock.date(forLocal: key * interval)
            let end = clock.date(forLocal: (key + 1) * interval)
            bins.append(HistoryBin(start: start, end: max(end, start + 1), average: sum / Double(count), maximum: peak))
        }

        for point in sorted {
            let pointKey = (clock.local(point.at) / interval).rounded(.down)
            if pointKey != key {
                flush()
                key = pointKey
                sum = 0
                count = 0
                peak = -Double.infinity
            }
            sum += point.average
            count += 1
            peak = max(peak, point.maximum, point.average)
        }
        flush()
        return bins
    }

    /// Consecutive bins where `isMarked` holds, merged into one span each.
    static func spans(_ bins: [HistoryBin], where isMarked: (HistoryBin) -> Bool) -> [HistorySpan] {
        var spans: [HistorySpan] = []
        for bin in bins where isMarked(bin) {
            if let last = spans.last, last.end >= bin.start {
                spans[spans.count - 1] = HistorySpan(start: last.start, end: max(last.end, bin.end))
            } else {
                spans.append(HistorySpan(start: bin.start, end: bin.end))
            }
        }
        return spans
    }

    /// Where series `index` of `count` draws its bar inside `bin`: side by side, with `gap` (a
    /// share of the bin) split around the group.
    static func slot(of bin: HistoryBin, series index: Int, of count: Int, gap: Double = Tokens.Layout.historyBarGap) -> HistorySpan {
        let width = bin.end.timeIntervalSince(bin.start)
        let usable = width * (1 - min(max(gap, 0), 1))
        let each = usable / Double(max(1, count))
        let start = bin.start + (width - usable) / 2 + each * Double(min(max(index, 0), max(0, count - 1)))
        return HistorySpan(start: start, end: start + each)
    }

    /// The bin a scrub position falls in, or the nearest one (the pointer may be over a gap).
    static func bin(at date: Date, in bins: [HistoryBin]) -> HistoryBin? {
        bins.first { $0.contains(date) }
            ?? bins.min { abs($0.middle.timeIntervalSince(date)) < abs($1.middle.timeIntervalSince(date)) }
    }
}

extension Array {
    fileprivate func isSorted(by areInOrder: (Element, Element) -> Bool) -> Bool {
        zip(self, dropFirst()).allSatisfy { areInOrder($0, $1) }
    }
}

/// Local wall-clock seconds since the reference date, and back, in one time zone. Remembers the
/// offset until the zone's next change, so binning sorted points asks the zone once per change.
struct LocalClock {
    let timeZone: TimeZone
    private var offset: TimeInterval = 0
    private var validFrom = Date.distantFuture
    private var validUntil = Date.distantPast

    init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    /// `date` as seconds on the local clock.
    mutating func local(_ date: Date) -> TimeInterval {
        if date < validFrom || date >= validUntil {
            offset = TimeInterval(timeZone.secondsFromGMT(for: date))
            validFrom = date
            validUntil = timeZone.nextDaylightSavingTimeTransition(after: date) ?? .distantFuture
        }
        return date.timeIntervalSinceReferenceDate + offset
    }

    /// The date the local clock reads `wall`. A time the clock shows twice (clocks going back)
    /// is its first; one it skips (clocks going forward) is the moment of the jump.
    func date(forLocal wall: TimeInterval) -> Date {
        let before = TimeInterval(timeZone.secondsFromGMT(for: Date(timeIntervalSinceReferenceDate: wall - 86400)))
        let after = TimeInterval(timeZone.secondsFromGMT(for: Date(timeIntervalSinceReferenceDate: wall + 86400)))
        let valid = [before, after].map { wall - $0 }.filter { candidate in
            let date = Date(timeIntervalSinceReferenceDate: candidate)
            return TimeInterval(timeZone.secondsFromGMT(for: date)) == wall - candidate
        }
        return Date(timeIntervalSinceReferenceDate: valid.min() ?? wall - before)
    }
}
