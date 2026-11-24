import Core
import Foundation
import SwiftUI

// What a history strip says in words: the scrubbed bar's caption and the VoiceOver summary.

extension HistoryRange {
    /// Ranges whose bars are labelled by time of day alone.
    var isWithinDay: Bool {
        self == .h12 || self == .h24
    }
}

extension HistoryStrip {
    /// Chart value names, read by VoiceOver, looked up once: every bar uses them.
    static let fromAxis = String(localized: "From", bundle: .strings, comment: "Chart: start of a bar's time span")
    static let toAxis = String(localized: "To", bundle: .strings, comment: "Chart: end of a bar's time span")
    static let zeroAxis = String(localized: "Zero", bundle: .strings, comment: "Chart: bar baseline")
    static let peakAxis = String(localized: "Peak", bundle: .strings, comment: "Chart: highest value in a bar")
    static let averageAxis = String(localized: "Average", bundle: .strings, comment: "Chart: average value in a bar")
    static let thresholdAxis = String(localized: "Alert threshold", bundle: .strings, comment: "Chart: rule line")
    static let selectedAxis = String(localized: "Selected", bundle: .strings, comment: "Chart: the scrubbed bar")

    /// When a bar was: "3:15 PM", "Sep 27, 3:15 PM", or for bars of a day or more (a year's
    /// range) the days they cover, "Sep 3 – 5".
    static func caption(for bin: HistoryBin, range: HistoryRange) -> String {
        if bin.end.timeIntervalSince(bin.start) >= 86400 {
            let lastDay = bin.end - 1
            return Calendar.current.isDate(bin.start, inSameDayAs: lastDay)
                ? bin.start.formatted(date: .abbreviated, time: .omitted)
                : (bin.start ..< lastDay).formatted(.interval.month(.abbreviated).day())
        }
        return bin.start.formatted(date: range.isWithinDay ? .omitted : .abbreviated, time: .shortened)
    }
}

extension HistoryStrip {
    /// "Average 23%, peak 87% at 3:15 PM" over the whole range, for VoiceOver. Every point in a
    /// range comes from one tier, so each weighs the same. Nil without points.
    static func spokenSummary(_ points: [SeriesPoint], metric: Metric, range: HistoryRange) -> String? {
        guard let peak = points.max(by: { $0.maximum < $1.maximum }) else {
            return nil
        }
        let average = points.reduce(0) { $0 + $1.average } / Double(points.count)
        let time = peak.at.formatted(date: range.isWithinDay ? .omitted : .abbreviated, time: .shortened)
        return String(
            localized: "Average \(Formatters.metric(average, metric)), peak \(Formatters.metric(peak.maximum, metric)) at \(time)",
            bundle: .strings,
            comment: "VoiceOver for a history chart: the range's average, its highest value, and when that was"
        )
    }
}

extension HistoryStrip {
    /// Pure: the alert threshold to draw, only once the data comes within half of it (D-113). The
    /// y scale includes every mark, so a 10 MB/s line over traffic averaging 200 kB/s flattened
    /// every bar to a sliver.
    nonisolated static func visibleThreshold(_ threshold: Double?, plottedPeak: Double) -> Double? {
        guard let threshold, threshold > 0, plottedPeak >= threshold / 2 else {
            return nil
        }
        return threshold
    }

    /// Each app's share of the apps' total, in percent, highest first (D-105).
    nonisolated static func shares(_ totals: [AppTotal]) -> [AppTotal] {
        let sum = totals.reduce(0) { $0 + max(0, $1.value) }
        guard sum > 0 else {
            return []
        }
        return totals.map { AppTotal(app: $0.app, value: max(0, $0.value) / sum * 100) }
    }
}
