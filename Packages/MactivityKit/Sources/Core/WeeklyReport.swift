import Foundation

/// Your week (D-102): the last seven days in a few figures, for History's card, its shareable
/// image, and the weekly notification.
public struct WeeklyReport: Hashable, Sendable {
    public let start: Date
    public let end: Date
    /// Time any app was in front.
    public let activeSeconds: Double
    /// The same for the week before, for "+12%".
    public let previousActiveSeconds: Double?
    /// Seconds in front, highest first.
    public let topApps: [AppTotal]
    /// Average asleep per night that it slept at all.
    public let averageSleepSeconds: Double?
    public let dataBytes: Double
    public let writtenBytes: Double
    public let crashes: Int
    /// The day the Mac was used most; by average CPU when time in use wasn't recorded (D-184).
    public let busiestDay: Date?
    public let charges: Int?
    /// When time in front started recording, if that was during the week (after an update or a
    /// fresh install): the time in use and top apps cover only the time since (D-108).
    public let recordingSince: Date?
    /// Time in use on each of the last seven calendar days, oldest first; today so far last.
    public let activeByDay: [DayTotal]
    /// Coding-agent time over the week (D-192), and the agent and project with the most; nil
    /// without agent history.
    public let agentSeconds: Double?
    public let topAgent: AgentWeek.Total?

    public init(
        start: Date, end: Date, activeSeconds: Double, previousActiveSeconds: Double?, topApps: [AppTotal],
        averageSleepSeconds: Double?, dataBytes: Double, writtenBytes: Double, crashes: Int, busiestDay: Date?, charges: Int?,
        recordingSince: Date? = nil, activeByDay: [DayTotal] = [], agentSeconds: Double? = nil, topAgent: AgentWeek.Total? = nil
    ) {
        self.start = start
        self.end = end
        self.activeSeconds = activeSeconds
        self.previousActiveSeconds = previousActiveSeconds
        self.topApps = topApps
        self.averageSleepSeconds = averageSleepSeconds
        self.dataBytes = dataBytes
        self.writtenBytes = writtenBytes
        self.crashes = crashes
        self.busiestDay = busiestDay
        self.charges = charges
        self.recordingSince = recordingSince
        self.activeByDay = activeByDay
        self.agentSeconds = agentSeconds
        self.topAgent = topAgent
    }

    /// The last seven calendar days ending with `end`'s, each as its own span: today runs to
    /// `end`, not midnight. An `end` at midnight (Monday's summary) closes the day before, so
    /// that week is Monday to Sunday, not six days and an empty one. Pure, for the loader and
    /// the tests.
    public static func days(ending end: Date, calendar: Calendar = .current) -> [DateInterval] {
        let today = calendar.startOfDay(for: end.addingTimeInterval(-1))
        return (0 ..< 7).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .day, value: -back, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: start) else {
                return nil
            }
            return DateInterval(start: start, end: min(next, max(start, end)))
        }
    }

    /// The day with the most time in use, if any day had some.
    public var mostInUse: DayTotal? {
        activeByDay.filter { $0.seconds > 0 }.max { $0.seconds < $1.seconds }
    }

    /// Pure: `firstFocus` when it's more than an hour into the week, else nil. An hour's slack
    /// keeps a Mac that was simply off first thing from being called a partial week.
    public static func recordingSince(firstFocus: Date?, weekStart: Date) -> Date? {
        guard let firstFocus, firstFocus.timeIntervalSince(weekStart) > 3600 else {
            return nil
        }
        return firstFocus
    }

    /// Change in time in use against the week before, as a fraction; nil without a week before.
    public var activeChange: Double? {
        guard let previous = previousActiveSeconds, previous >= 3600 else {
            return nil
        }
        return (activeSeconds - previous) / previous
    }

    /// Average asleep per night: each night runs noon to noon, and nights without any sleep
    /// (Mactivity wasn't running, or the Mac never slept) are left out.
    public static func averageSleep(_ events: [PowerEvent], from start: Date, to end: Date, calendar: Calendar = .current) -> Double? {
        var nights: [Double] = []
        var noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start) ?? start
        // A last window shorter than 12 hours (the card opened this afternoon) holds no night,
        // only maybe a lunchtime nap; noon to midnight still holds a night's first half (D-141).
        while noon < end, min(noon.addingTimeInterval(86400), end).timeIntervalSince(noon) >= 12 * 3600 {
            let next = noon.addingTimeInterval(86400)
            let asleep = SleepTimeline.asleep(events, from: noon, to: min(next, end)).reduce(0) { $0 + $1.duration }
            if asleep >= 3600 {
                nights.append(asleep)
            }
            noon = next
        }
        return nights.isEmpty ? nil : nights.reduce(0, +) / Double(nights.count)
    }
}

/// One calendar day's total, e.g. its time in use.
public struct DayTotal: Hashable, Sendable {
    public let day: Date
    public let seconds: Double

    public init(day: Date, seconds: Double) {
        self.day = day
        self.seconds = seconds
    }
}
