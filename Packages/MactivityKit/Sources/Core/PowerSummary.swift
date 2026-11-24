import Foundation

/// The whole Mac's power over a range (D-258): its average and its peak, in milliwatts, from the
/// `powerDraw` series. Pure.
public struct PowerSummary: Hashable, Sendable {
    /// Averaged over the readings in the range.
    public let averageMW: Double
    /// The highest single reading.
    public let peakMW: Double
    /// When recording began, if that was well inside the range: the figure covers less than it.
    public let since: Date?

    /// Recording that began more than this after the range's start says so.
    static let lateStart: TimeInterval = 1800

    /// Nil without a reading in the range.
    public static func read(_ points: [SeriesPoint], rangeStart: Date) -> PowerSummary? {
        let readings = points.filter { $0.at >= rangeStart && $0.average > 0 }
        guard let first = readings.first else {
            return nil
        }
        let average = readings.map(\.average).reduce(0, +) / Double(readings.count)
        let peak = readings.map { max($0.maximum, $0.average) }.max() ?? average
        let late = first.at.timeIntervalSince(rangeStart) > lateStart
        return PowerSummary(averageMW: average, peakMW: peak, since: late ? first.at : nil)
    }
}
