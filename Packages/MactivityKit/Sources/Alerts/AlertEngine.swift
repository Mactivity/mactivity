import Core
import Foundation

/// What one evaluation produced: the alerts to post, and the state to keep for the next one.
public struct AlertEvaluation: Hashable, Sendable {
    public let alerts: [Alert]
    public let state: AlertState

    public init(alerts: [Alert], state: AlertState) {
        self.alerts = alerts
        self.state = state
    }
}

/// The rule engine (spec 5.4, 6.8). A pure function over recent per-app activity.
public enum AlertEngine {
    /// The oldest counted point must be at or before `now − coverage × window`.
    static let coverage = 0.9
    /// Each point stands for a bucket this long (`AlertMonitor.bucketLength`).
    static let pointLength: TimeInterval = 5
    /// Readings at most this far apart count as continuous (10 s idle, 20 s in Low Power Mode);
    /// a longer gap (sleep, the app not running) counts only this much toward the window (D-139).
    static let longestCountedGap: TimeInterval = 30
    /// "Sustained": at least this share of the window's points is at or above the threshold.
    static let sustainedShare = 0.8
    /// "Still growing" compares the last point with the point closest to this long before now.
    static let stillGrowingLookback: TimeInterval = 5 * 60
    /// Growing memory measures from the median of the window's first 5 minutes, not its first
    /// point: one bad reading (seen right after a wake, D-130) made a steady 2 GB app read as
    /// "up 2 GB in an hour".
    static let baselineSpan: TimeInterval = 5 * 60
    /// How long growing memory remembers the footprint it last alerted at (D-111).
    static let growthMemory: TimeInterval = 24 * 3600

    /// Pure. Same inputs → same outputs. Alert IDs may be random; everything else is deterministic.
    ///
    /// Apps are evaluated in `activity` order, rules in `AlertRule.allCases` order. Each history's
    /// points must be oldest first.
    public static func evaluate(
        settings: AlertSettings,
        activity: [AppActivityHistory],
        state: AlertState,
        context: AlertContext
    ) -> AlertEvaluation {
        let now = context.now
        if let quietHours = settings.quietHours, quietHours.contains(now, calendar: context.calendar) {
            return AlertEvaluation(alerts: [], state: state)
        }
        let cooldown = settings.cooldown.seconds
        var newState = state
        var alerts: [Alert] = []
        for history in activity where isWatched(history.app, settings: settings, context: context) {
            for rule in AlertRule.appRules {
                let ruleSettings = settings.settings(for: rule)
                guard ruleSettings.isEnabled else {
                    continue
                }
                let key = AlertKey(appID: history.app.id, rule: rule)
                if rule == .growingMemory {
                    forgetLevel(key, in: &newState, latest: history.points.last, threshold: ruleSettings.threshold, now: now)
                }
                // A time ahead of now is from a clock since set back: it doesn't hold the alert (D-221).
                if let lastFired = newState.lastFired[key], lastFired <= now, lastFired.addingTimeInterval(cooldown) > now {
                    continue
                }
                guard let finding = finding(for: rule, settings: ruleSettings, points: history.points, now: now) else {
                    continue
                }
                if case let .growingMemory(_, current) = finding, let level = newState.levelAtLastAlert[key],
                   Double(current) < level + ruleSettings.threshold {
                    // Still growing, but not by the threshold again since the last alert.
                    continue
                }
                if case let .growingMemory(_, current) = finding, let peak = context.usualPeakMemory[history.app.id],
                   Double(current) < peak {
                    // Growing, but still below what it reaches on an ordinary day here (D-218).
                    continue
                }
                let text = AlertText.make(for: finding, app: history.app, window: ruleSettings.window)
                alerts.append(Alert(rule: rule, app: history.app, firedAt: now, title: text.title, body: text.body))
                newState.lastFired[key] = now
                if case let .growingMemory(_, current) = finding {
                    newState.levelAtLastAlert[key] = Double(current)
                }
            }
        }
        return AlertEvaluation(alerts: alerts, state: newState)
    }

    /// Growing memory alerts again only once the app has grown by the threshold beyond where it
    /// last alerted (D-111): a steadily growing app no longer re-alerts every cooldown at the same
    /// size. The level is forgotten once the app gives that much back (it freed memory or was
    /// relaunched), and after a day.
    static func forgetLevel(_ key: AlertKey, in state: inout AlertState, latest: AppActivityPoint?, threshold: Double, now: Date) {
        guard let level = state.levelAtLastAlert[key] else {
            return
        }
        let stale = state.lastFired[key].map { now.timeIntervalSince($0) > growthMemory } ?? true
        let released = latest.map { Double($0.memoryBytes) <= level - threshold } ?? false
        if stale || released {
            state.levelAtLastAlert[key] = nil
        }
    }

    // MARK: Eligibility

    static func isWatched(_ app: AppIdentity, settings: AlertSettings, context: AlertContext) -> Bool {
        if app.kind == .system || settings.mutedAppIDs.contains(app.id) {
            return false
        }
        if settings.exemptsFrontmostApp, app.id == context.frontmostAppID {
            return false
        }
        return true
    }

    // MARK: Rules

    /// The evidence for one rule, or nil when it doesn't fire.
    static func finding(
        for rule: AlertRule,
        settings: RuleSettings,
        points: [AppActivityPoint],
        now: Date
    ) -> Finding? {
        guard let window = counted(points, window: settings.window.seconds, now: now) else {
            return nil
        }
        let threshold = settings.threshold
        switch rule {
        case .highCPU:
            let average = mean(window.map(\.cpuPercent))
            return average >= threshold ? .highCPU(average: average) : nil
        case .growingMemory:
            return growingMemory(window, threshold: threshold, now: now)
        case .heavyDisk:
            return sustainedAverage(window.map(\.diskWriteBPS), threshold: threshold).map { .heavyDisk(average: $0) }
        case .heavyNetwork:
            let download = sustainedAverage(window.map { $0.netInBPS ?? 0 }, threshold: threshold)
            let upload = sustainedAverage(window.map { $0.netOutBPS ?? 0 }, threshold: threshold)
            switch (download, upload) {
            case let (download?, upload?):
                return upload > download
                    ? .heavyNetwork(direction: .upload, average: upload)
                    : .heavyNetwork(direction: .download, average: download)
            case let (download?, nil):
                return .heavyNetwork(direction: .download, average: download)
            case let (nil, upload?):
                return .heavyNetwork(direction: .upload, average: upload)
            case (nil, nil):
                return nil
            }
        case .accessoryBatteryLow, .diskFilling, .appCrashing, .notSleeping, .hotspotData, .diskLow, .overheating, .connectionLost,
             .runawayProcess, .outOfTheOrdinary, .agentLongSession, .agentMemory, .newStartupItem, .dataBudget,
             .vulnerableSoftware:
            // Checked by `SystemAlertRules`, not per snapshot.
            return nil
        }
    }

    /// The points with `at` in [now − window, now], or nil when they don't cover enough of it.
    static func counted(_ points: [AppActivityPoint], window: TimeInterval, now: Date) -> ArraySlice<AppActivityPoint>? {
        guard window > 0 else {
            return nil
        }
        let start = now.addingTimeInterval(-window)
        let lower = partitionIndex(points) { $0.at >= start }
        let upper = partitionIndex(points) { $0.at > now }
        guard lower < upper else {
            return nil
        }
        let slice = points[lower ..< upper]
        guard let oldest = slice.first, oldest.at <= now.addingTimeInterval(-coverage * window) else {
            return nil
        }
        // Time actually covered by readings, not just the oldest one's age: a minute at 100%,
        // eight minutes asleep and a second at 100% isn't "100% for 10 minutes".
        var covered = pointLength
        var previous = oldest.at
        for point in slice.dropFirst() {
            covered += min(point.at.timeIntervalSince(previous), longestCountedGap)
            previous = point.at
        }
        guard covered >= coverage * window - 0.001 else {
            return nil
        }
        return slice
    }

    static func growingMemory(_ window: ArraySlice<AppActivityPoint>, threshold: Double, now: Date) -> Finding? {
        guard let first = window.first, let last = window.last else {
            return nil
        }
        let start = window.prefix { $0.at < first.at.addingTimeInterval(baselineSpan) }.map(\.memoryBytes).sorted()
        let baseline = start.isEmpty ? first.memoryBytes : start[start.count / 2]
        let growth = Double(last.memoryBytes) - Double(baseline)
        guard growth >= threshold else {
            return nil
        }
        let target = now.addingTimeInterval(-stillGrowingLookback)
        var reference = first
        for point in window where abs(point.at.timeIntervalSince(target)) < abs(reference.at.timeIntervalSince(target)) {
            reference = point
        }
        guard last.memoryBytes > reference.memoryBytes else {
            return nil
        }
        return .growingMemory(growth: growth, current: last.memoryBytes)
    }

    /// The average, when it is at or above the threshold and enough points are too.
    static func sustainedAverage(_ values: [Double], threshold: Double) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let average = mean(values)
        guard average >= threshold else {
            return nil
        }
        let above = values.lazy.filter { $0 >= threshold }.count
        guard Double(above) >= sustainedShare * Double(values.count) else {
            return nil
        }
        return average
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// The first index whose element satisfies `predicate`, which must be false then true along the array.
    private static func partitionIndex(
        _ points: [AppActivityPoint],
        where predicate: (AppActivityPoint) -> Bool
    ) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if predicate(points[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}

/// Why a rule fired, with the figures the notification quotes.
enum Finding: Hashable {
    enum Direction: Hashable {
        case download, upload
    }

    case highCPU(average: Double)
    case growingMemory(growth: Double, current: UInt64)
    case heavyDisk(average: Double)
    case heavyNetwork(direction: Direction, average: Double)
}

/// Notification text (spec 4.4). Every figure goes through `Formatters`. One key per sentence, so
/// each body comes in two forms: "for an hour" and "for N minutes".
enum AlertText {
    static func make(for finding: Finding, app: AppIdentity, window: Duration) -> (title: String, body: String) {
        let name = app.name
        switch finding {
        case let .highCPU(average):
            return (
                String(localized: "\(name) is using a lot of CPU", bundle: .strings, comment: "Alert title; the argument is an app."),
                averaged(Formatters.percent(average), window: window)
            )
        case let .growingMemory(growth, current):
            return (
                String(localized: "\(name)'s memory keeps climbing", bundle: .strings, comment: "Alert title; the argument is an app."),
                grew(Formatters.memory(growth), now: Formatters.memory(current), window: window)
            )
        case let .heavyDisk(average):
            return (
                String(localized: "\(name) is writing a lot to disk", bundle: .strings, comment: "Alert title; the argument is an app."),
                averaged(Formatters.rate(average), window: window)
            )
        case let .heavyNetwork(direction, average):
            return (
                String(localized: "\(name) is using a lot of network", bundle: .strings, comment: "Alert title; the argument is an app."),
                transferred(Formatters.rate(average), direction: direction, window: window)
            )
        }
    }

    /// The window in whole minutes, at least 1; nil for exactly an hour, which reads "an hour".
    private static func minutes(in window: Duration) -> Int? {
        let minutes = max(1, Int((window.seconds / 60).rounded()))
        return minutes == 60 ? nil : minutes
    }

    /// "an hour" for 60 minutes, otherwise "1 minute" / "N minutes", rounded to whole minutes.
    static func phrase(for window: Duration) -> String {
        guard let minutes = minutes(in: window) else {
            return String(localized: "an hour", bundle: .strings, comment: "An alert's time window of 60 minutes.")
        }
        return String(localized: "\(minutes) minutes", bundle: .strings, comment: "An alert's time window.")
    }

    /// "Averaged 84% for 10 minutes." The figure is a percent or a rate.
    private static func averaged(_ figure: String, window: Duration) -> String {
        guard let minutes = minutes(in: window) else {
            return String(
                localized: "Averaged \(figure) for an hour.", bundle: .strings,
                comment: "Alert body. The argument is a percent or a rate, e.g. 84% or 52 MB/s."
            )
        }
        return String(
            localized: "Averaged \(figure) for \(minutes) minutes.", bundle: .strings,
            comment: "Alert body. The first argument is a percent or a rate, e.g. 84% or 52 MB/s."
        )
    }

    /// "Up 1.4 GB in 60 minutes, now 3.3 GB."
    private static func grew(_ growth: String, now current: String, window: Duration) -> String {
        guard let minutes = minutes(in: window) else {
            return String(
                localized: "Up \(growth) in an hour, now \(current).", bundle: .strings,
                comment: "Alert body: an app's memory grew by the first amount and now uses the second."
            )
        }
        return String(
            localized: "Up \(growth) in \(minutes) minutes, now \(current).", bundle: .strings,
            comment: "Alert body: an app's memory grew by the first amount and now uses the last."
        )
    }

    /// "Downloading 12 MB/s for 5 minutes."
    private static func transferred(_ rate: String, direction: Finding.Direction, window: Duration) -> String {
        let minutes = minutes(in: window)
        switch (direction, minutes) {
        case (.download, nil):
            return String(localized: "Downloading \(rate) for an hour.", bundle: .strings, comment: "Alert body. The argument is a rate.")
        case let (.download, minutes?):
            return String(
                localized: "Downloading \(rate) for \(minutes) minutes.", bundle: .strings,
                comment: "Alert body. The first argument is a rate."
            )
        case (.upload, nil):
            return String(localized: "Uploading \(rate) for an hour.", bundle: .strings, comment: "Alert body. The argument is a rate.")
        case let (.upload, minutes?):
            return String(
                localized: "Uploading \(rate) for \(minutes) minutes.", bundle: .strings,
                comment: "Alert body. The first argument is a rate."
            )
        }
    }
}
