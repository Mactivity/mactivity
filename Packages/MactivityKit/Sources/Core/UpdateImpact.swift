import Foundation

/// A version that arrived on this Mac: macOS itself or an app (D-206).
public struct InstalledUpdate: Hashable, Sendable, Identifiable {
    /// Nil for macOS.
    public let app: AppIdentity?
    public let name: String
    public let version: String
    public let installedAt: Date

    public init(app: AppIdentity?, name: String, version: String, installedAt: Date) {
        self.app = app
        self.name = name
        self.version = version
        self.installedAt = installedAt
    }

    public var id: String {
        "\(app?.id ?? "macOS")@\(version)"
    }
}

/// What an update changed: the days after it beside the days before (D-206).
public struct UpdateImpact: Hashable, Sendable, Identifiable {
    public struct Change: Hashable, Sendable {
        public let metric: Metric
        /// Median day before and after.
        public let before: Double
        public let after: Double

        public init(metric: Metric, before: Double, after: Double) {
            self.metric = metric
            self.before = before
            self.after = after
        }

        /// +0.33 for a third more; nil when there was nothing before.
        public var fraction: Double? {
            before > 0 ? after / before - 1 : nil
        }
    }

    public let update: InstalledUpdate
    public let daysBefore: Int
    public let daysAfter: Int
    public let changes: [Change]

    public init(update: InstalledUpdate, daysBefore: Int, daysAfter: Int, changes: [Change]) {
        self.update = update
        self.daysBefore = daysBefore
        self.daysAfter = daysAfter
        self.changes = changes
    }

    public var id: String {
        update.id
    }

    /// The change worth a word, when one is: a quarter more or less, or bigger, on a figure over
    /// its floor (a tenth of a percent becoming two tenths isn't news). The biggest first.
    public var notable: Change? {
        changes
            .filter { change in
                guard let fraction = change.fraction, abs(fraction) >= UpdateComparison.threshold else {
                    return false
                }
                return max(change.before, change.after) >= UpdateComparison.floor(change.metric)
            }
            .max { abs(log($0.after / $0.before)) < abs(log($1.after / $1.before)) }
    }

    /// Heavier on the notable figure.
    public var isHeavier: Bool {
        (notable?.fraction ?? 0) > 0
    }
}

/// The days before an update beside the days after (D-206). Pure: daily figures in, the change out.
public enum UpdateComparison {
    /// Days each side compared.
    public static let window = 7
    /// Days of use each side before anything is said.
    public static let minimumDays = 2
    /// A change this big (a quarter) or bigger is notable.
    public static let threshold = 0.25
    public static let metrics: [Metric] = [.cpu, .memory, .energy]

    /// Below these, a change isn't worth a word: Out of the ordinary's floors, a third of them.
    static func floor(_ metric: Metric) -> Double {
        Baselines.floor(metric) / 3
    }

    /// The days to read for `update`: up to `window` before its day and after it, never today.
    public static func span(_ update: InstalledUpdate, now: Date, calendar: Calendar = .current) -> DateInterval? {
        let day = calendar.startOfDay(for: update.installedAt)
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -window, to: day),
              let after = calendar.date(byAdding: .day, value: window + 1, to: day) else {
            return nil
        }
        return DateInterval(start: start, end: max(start, min(after, today)))
    }

    /// Whether an update not compared yet still can be: history goes back far enough before it,
    /// and its week after isn't over. Otherwise it's left out rather than waiting forever.
    public static func mayCompare(_ update: InstalledUpdate, firstRecorded: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: update.installedAt)
        guard let firstRecorded, let enough = calendar.date(byAdding: .day, value: -minimumDays, to: day),
              calendar.startOfDay(for: firstRecorded) <= enough else {
            return false
        }
        let daysSince = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? .max
        return daysSince <= window + 1
    }

    /// Days the app was used in the week before its update's day.
    public static func daysUsedBefore(_ update: InstalledUpdate, daily: [Metric: [DayValue]], calendar: Calendar = .current) -> Int {
        let day = calendar.startOfDay(for: update.installedAt)
        return daily.values.map { $0.count { $0.day < day } }.max() ?? 0
    }

    /// `daily[metric]`: the app's (or for macOS, the whole Mac's) figure on each day it was used.
    /// Days it wasn't aren't zeros: an app left closed isn't lighter. Nil until there are
    /// `minimumDays` of use on each side of the update's day, which itself is left out.
    public static func impact(
        _ update: InstalledUpdate, daily: [Metric: [DayValue]], now: Date, calendar: Calendar = .current
    ) -> UpdateImpact? {
        let day = calendar.startOfDay(for: update.installedAt)
        let today = calendar.startOfDay(for: now)
        var changes: [UpdateImpact.Change] = []
        var counts: (before: Int, after: Int) = (0, 0)
        for metric in metrics {
            let values = daily[metric] ?? []
            let before = values.filter { value in
                value.day < day && (calendar.dateComponents([.day], from: value.day, to: day).day ?? .max) <= window
            }
            let after = values.filter { value in
                value.day > day && value.day < today && (calendar.dateComponents([.day], from: day, to: value.day).day ?? .max) <= window
            }
            guard before.count >= minimumDays, after.count >= minimumDays else {
                continue
            }
            counts = (max(counts.before, before.count), max(counts.after, after.count))
            changes.append(.init(
                metric: metric, before: Baselines.median(before.map(\.average)), after: Baselines.median(after.map(\.average))
            ))
        }
        guard !changes.isEmpty else {
            return nil
        }
        return UpdateImpact(update: update, daysBefore: counts.before, daysAfter: counts.after, changes: changes)
    }
}
