import Foundation

/// One sleep (D-213): when it started and ended, what woke the Mac, and the battery it used.
public struct SleepSpan: Hashable, Sendable, Identifiable {
    public let start: Date
    public let end: Date
    /// The wake that ended it, with macOS's reason.
    public let wake: PowerEvent
    /// Percentage points of battery used while asleep; nil without readings either side, or
    /// when it charged.
    public let batteryUsed: Double?

    public init(start: Date, end: Date, wake: PowerEvent, batteryUsed: Double?) {
        self.start = start
        self.end = end
        self.wake = wake
        self.batteryUsed = batteryUsed
    }

    public var id: Date {
        start
    }

    public var drainPerHour: Double? {
        let hours = end.timeIntervalSince(start) / 3600
        return batteryUsed.flatMap { hours > 0 ? $0 / hours : nil }
    }

    /// More than a percent an hour, and 3% or more in all, over 2 hours or more: something kept it
    /// from resting. Shorter sleeps aren't judged: the readings either side are minutes away, and
    /// a few minutes awake would read as drain.
    public var isHeavyDrain: Bool {
        end.timeIntervalSince(start) >= 2 * 3600 && (drainPerHour ?? 0) >= 1 && (batteryUsed ?? 0) >= 3
    }
}

/// Each sleep and the battery it used (D-213). Pure.
public enum SleepDrain {
    /// Readings this close to the sleep's start or end stand for the level then: a minute's
    /// reading in the last two days, a quarter-hour's before that.
    public static let readingWindow: TimeInterval = 16 * 60

    /// Sleeps of `minimum` or longer, newest first. `levels`: the battery level, oldest first.
    public static func spans(_ events: [PowerEvent], levels: [SeriesPoint], minimum: TimeInterval = 30 * 60) -> [SleepSpan] {
        var spans: [SleepSpan] = []
        var fellAsleep: Date?
        for event in events.sorted(by: { $0.at < $1.at }) {
            switch event.kind {
            case .sleep:
                fellAsleep = event.at
            case .wake:
                if let start = fellAsleep, event.at.timeIntervalSince(start) >= minimum {
                    spans.append(SleepSpan(start: start, end: event.at, wake: event, batteryUsed: used(levels, from: start, to: event.at)))
                }
                fellAsleep = nil
            }
        }
        return spans.reversed()
    }

    static func used(_ levels: [SeriesPoint], from start: Date, to end: Date) -> Double? {
        guard let before = levels.last(where: { $0.at <= start && $0.at >= start - readingWindow }),
              let after = levels.first(where: { $0.at >= end && $0.at <= end + readingWindow }) else {
            return nil
        }
        // Charged while asleep: nothing to say about drain.
        guard after.average <= before.average + 0.5 else {
            return nil
        }
        return max(0, before.average - after.average)
    }
}

extension Checkup {
    /// The last sleep drained the battery fast (D-213).
    static func heavySleep(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard let span = inputs.heavySleep, let used = span.batteryUsed, let rate = span.drainPerHour else {
            return []
        }
        let amount = Formatters.percent(used)
        let hourly = Formatters.percent(rate, fractionDigits: 1)
        return [CheckupItem(
            id: "heavySleep", area: .sleep, severity: .suggestion,
            title: String(localized: "Your Mac used \(amount) of its battery while asleep", bundle: .strings),
            detail: String(
                localized: "About \(hourly) an hour, more than resting should take. History → Sleep shows what woke it.",
                bundle: .strings
            )
        )]
    }
}
