import Foundation

/// An app doing much more than it usually does on this Mac (D-198): today's figure beside its
/// own typical day.
public struct UnusualUsage: Hashable, Sendable, Identifiable {
    public let app: AppIdentity
    public let metric: Metric
    /// Today's figure: the app's average over the day so far, as History gives a day.
    public let today: Double
    /// Its median day over the days before; zero when it barely appeared.
    public let usual: Double

    public init(app: AppIdentity, metric: Metric, today: Double, usual: Double) {
        self.app = app
        self.metric = metric
        self.today = today
        self.usual = usual
    }

    public var id: String {
        app.id + "\u{1F}" + metric.rawValue
    }

    /// Times its usual; nil when it usually does next to nothing.
    public var ratio: Double? {
        usual > 0 ? today / usual : nil
    }
}

/// Each app's typical day, learned from History, and what stands out today (D-198). Pure: the
/// days come in, the unusual come out.
public enum Baselines {
    /// Days of history before anything is called unusual: a first week is still learning.
    public static let minimumDays = 5
    /// Today at this many times its usual or more stands out.
    public static let ratio = 2.5
    /// The latest days, whose median also counts as usual: a change that's lasted a few days is
    /// the new normal, not news every morning (one history: a Simulator in use all week read
    /// "220× usual" four days running against the quiet weeks before it).
    public static let recentDays = 3
    /// The metrics compared: what someone would notice and act on.
    public static let metrics: [Metric] = [.cpu, .memory, .energy]

    /// Below these, however many times its usual, an app's day isn't worth a word: a percent of
    /// the processor, half a gigabyte, a fifth of a watt.
    public static func floor(_ metric: Metric) -> Double {
        switch metric {
        case .cpu, .gpu: 3
        case .memory: 500_000_000
        case .energy: 200
        default: .infinity
        }
    }

    /// The apps that stand out today for `metric`, most out of the ordinary first.
    ///
    /// - Parameters:
    ///   - today: today's top apps for `metric`, each value the app's average over the day.
    ///   - before: the same for each earlier day, oldest first; an app missing from a day did
    ///     next to nothing that day.
    public static func unusual(metric: Metric, today: [AppTotal], before: [[AppTotal]], limit: Int = 3) -> [UnusualUsage] {
        // Only days the Mac was in use at all count toward "usual".
        let days = before.filter { !$0.isEmpty }
        guard days.count >= minimumDays else {
            return []
        }
        let floor = floor(metric)
        let found = today.filter { $0.value >= floor && $0.app.kind != .system }.compactMap { total -> UnusualUsage? in
            let usual = usual(total.app.id, in: days)
            guard total.value >= ratio * usual else {
                return nil
            }
            return UnusualUsage(app: total.app, metric: metric, today: total.value, usual: usual)
        }
        return Array(found.sorted { score($0) > score($1) }.prefix(limit))
    }

    /// An app's usual day: the median of the days given (oldest first; days the Mac wasn't used
    /// left out), or of the latest few when they're higher, as the new normal.
    public static func usual(_ appID: AppIdentity.ID, in days: [[AppTotal]]) -> Double {
        let values = days.map { day in day.first { $0.app.id == appID }?.value ?? 0 }
        return max(median(values), median(Array(values.suffix(recentDays))))
    }

    /// Bigger multiples first; an app with no usual at all ranks by how far over the floor it is.
    public static func score(_ usage: UnusualUsage) -> Double {
        usage.ratio ?? (usage.today / floor(usage.metric) * ratio + 1000)
    }

    public static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else {
            return 0
        }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
