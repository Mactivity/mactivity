import Foundation

/// One app's figure in two periods (D-207): the apps that changed most between two days or weeks.
public struct AppShift: Hashable, Sendable, Identifiable {
    public let app: AppIdentity
    public let metric: Metric
    public let first: Double
    public let second: Double

    public init(app: AppIdentity, metric: Metric, first: Double, second: Double) {
        self.app = app
        self.metric = metric
        self.first = first
        self.second = second
    }

    public var id: String {
        app.id + "\u{1F}" + metric.rawValue
    }
}

/// Two days or two weeks side by side (D-207). Pure.
public enum DayComparison {
    /// The apps whose figure moved most between `first` and `second` (each a period's top apps),
    /// biggest move first. An app missing from a period did next to nothing in it. Moves under a
    /// third of Out of the ordinary's floor are left out, and so is macOS.
    public static func shifts(metric: Metric, first: [AppTotal], second: [AppTotal], limit: Int = 4) -> [AppShift] {
        var apps: [AppIdentity.ID: AppIdentity] = [:]
        var values: [AppIdentity.ID: (first: Double, second: Double)] = [:]
        for total in first where total.app.kind != .system {
            apps[total.app.id] = total.app
            values[total.app.id, default: (0, 0)].first = total.value
        }
        for total in second where total.app.kind != .system {
            apps[total.app.id] = total.app
            values[total.app.id, default: (0, 0)].second = total.value
        }
        let floor = Baselines.floor(metric) / 3
        return values
            .filter { abs($0.value.second - $0.value.first) >= floor }
            .sorted { abs($0.value.second - $0.value.first) > abs($1.value.second - $1.value.first) }
            .prefix(limit)
            .compactMap { id, value in
                apps[id].map { AppShift(app: $0, metric: metric, first: value.first, second: value.second) }
            }
    }

    /// Slowdowns on a day's timeline.
    public static func slowdowns(_ result: DayStoryResult) -> Int {
        result.events.count {
            if case .slowdown = $0.kind {
                true
            } else {
                false
            }
        }
    }

    /// Alerts on a day's timeline, each collapsed group counted in full.
    public static func alerts(_ result: DayStoryResult) -> Int {
        result.events.reduce(0) { total, event in
            if case let .alert(_, _, count) = event.kind {
                return total + count
            }
            return total
        }
    }

    /// The period a day stands for: the day itself, or the week ending on it.
    public static func interval(ending day: Date, days: Int, now: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        let first = calendar.date(byAdding: .day, value: -(days - 1), to: start) ?? start
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: first, end: max(first, min(end, now)))
    }
}
