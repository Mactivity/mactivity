import Foundation

/// The math behind an app's history page (D-168): its series in day or hour buckets, its
/// average and peak, and when in the week it's busiest. Pure.
public enum AppRhythm {
    public enum Bucket: Sendable {
        case hour, day
    }

    /// The series averaged per hour or per day (each bucket's start), oldest first. A bucket's
    /// peak is the highest maximum seen in it.
    public static func bucketed(_ points: [SeriesPoint], by bucket: Bucket, calendar: Calendar) -> [SeriesPoint] {
        let component: Calendar.Component = bucket == .hour ? .hour : .day
        var groups: [Date: (sum: Double, count: Int, peak: Double)] = [:]
        for point in points {
            guard let start = calendar.dateInterval(of: component, for: point.at)?.start else {
                continue
            }
            let group = groups[start] ?? (0, 0, -.infinity)
            groups[start] = (group.sum + point.average, group.count + 1, max(group.peak, point.maximum))
        }
        return groups.keys.sorted().compactMap { start in
            groups[start].map { SeriesPoint(at: start, average: $0.sum / Double($0.count), maximum: $0.peak) }
        }
    }

    /// The average over every point, and the highest maximum; nil with no points.
    public static func summary(_ points: [SeriesPoint]) -> (average: Double, peak: Double)? {
        guard !points.isEmpty else {
            return nil
        }
        return (points.reduce(0) { $0 + $1.average } / Double(points.count), points.map(\.maximum).max() ?? 0)
    }

    /// Seven rows (the calendar's weekdays, starting with its first weekday) of 24 hours: the
    /// average in each cell, nil where nothing was recorded.
    public static func week(_ points: [SeriesPoint], calendar: Calendar) -> [[Double?]] {
        var sums = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var counts = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for point in points {
            let weekday = calendar.component(.weekday, from: point.at)
            let row = (weekday - calendar.firstWeekday + 7) % 7
            let hour = calendar.component(.hour, from: point.at)
            sums[row][hour] += point.average
            counts[row][hour] += 1
        }
        return (0 ..< 7).map { row in
            (0 ..< 24).map { hour in counts[row][hour] > 0 ? sums[row][hour] / Double(counts[row][hour]) : nil }
        }
    }
}
