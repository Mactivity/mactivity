import Foundation

/// One row of time in front (D-098): an app in use, from when to when.
public struct FocusStretch: Hashable, Sendable {
    public let app: AppIdentity
    public let start: Date
    public let end: Date

    public init(app: AppIdentity, start: Date, end: Date) {
        self.app = app
        self.start = start
        self.end = end
    }
}

/// A run in one app, with glances at others left inside it.
public struct FocusStreak: Hashable, Sendable {
    public let app: AppIdentity
    public let start: Date
    public let end: Date
    /// Time in the app itself: the glances away don't count.
    public let seconds: TimeInterval
    /// The app that took over and ended it. Nil when the person stepped away instead.
    public let brokenBy: AppIdentity?

    public init(app: AppIdentity, start: Date, end: Date, seconds: TimeInterval, brokenBy: AppIdentity?) {
        self.app = app
        self.start = start
        self.end = end
        self.seconds = seconds
        self.brokenBy = brokenBy
    }
}

/// Focus streaks (D-271): the longest stretches in one app before switching, each day, and the
/// apps that break them up most. Pure, over the `focus` table's rows.
public enum FocusStreaks {
    /// Time away from an app that doesn't end its streak, in one go. Half of the stretches on
    /// one Mac (47% of 2,366) are under this, and they're 8% of the time in front: copying
    /// something, checking a message. Past it, at a minute, the same data starts merging real
    /// visits, and at 15 s a look at a message still ends an hour's work.
    public static let glance: TimeInterval = 30
    /// A streak shorter than this isn't one worth breaking: a minute in Safari and on to Mail
    /// doesn't count against Mail.
    public static let worthBreaking: TimeInterval = 300

    /// Pure: every streak in these rows, oldest first. A streak ends when more than `glance` passes
    /// away from its app, whether in other apps or with nothing in front: the recorder ends a
    /// stretch at sleep, a lock, or five minutes without input, and that's stepping away, not
    /// switching. Rows can arrive in any order and can overlap by a moment at a launch.
    public static func streaks(_ stretches: [FocusStretch]) -> [FocusStreak] {
        let rows = stretches.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var found: [FocusStreak] = []
        var index = 0
        while index < rows.count {
            let first = rows[index]
            var seconds = first.end.timeIntervalSince(first.start)
            var end = first.end
            var last = index
            var next = index + 1
            while next < rows.count, rows[next].start.timeIntervalSince(end) <= glance {
                if rows[next].app.id == first.app.id {
                    seconds += max(0, rows[next].end.timeIntervalSince(max(rows[next].start, end)))
                    end = max(end, rows[next].end)
                    last = next
                }
                next += 1
            }
            found.append(FocusStreak(
                app: first.app, start: first.start, end: end, seconds: seconds, brokenBy: breaker(rows, after: last, end: end)
            ))
            index = last + 1
        }
        return found
    }

    /// The first app after a streak that stayed longer than a glance, with no break in use on the
    /// way to it: a look at Finder on the way to Mail is Mail's doing. Nil when the person stepped
    /// away.
    private static func breaker(_ rows: [FocusStretch], after last: Int, end: Date) -> AppIdentity? {
        var previousEnd = end
        var next = last + 1
        while next < rows.count, rows[next].start.timeIntervalSince(previousEnd) <= glance {
            if rows[next].end.timeIntervalSince(rows[next].start) > glance {
                return rows[next].app
            }
            previousEnd = max(previousEnd, rows[next].end)
            next += 1
        }
        return nil
    }

    /// One local day's longest streaks.
    public struct Day: Hashable, Sendable {
        /// Local midnight.
        public let day: Date
        /// Longest first, at most `shownPerDay`.
        public let longest: [FocusStreak]
    }

    public struct Breaker: Hashable, Sendable {
        public let app: AppIdentity
        public let count: Int
    }

    public struct Report: Hashable, Sendable {
        /// Days the Mac was in use, newest first.
        public let days: [Day]
        /// Most first, at most `shownBreakers`.
        public let breakers: [Breaker]
    }

    public static let shownPerDay = 3
    public static let shownBreakers = 5

    /// Pure: the report over these rows. A streak over midnight belongs to the day it began.
    public static func report(_ stretches: [FocusStretch], calendar: Calendar = .current) -> Report {
        let all = streaks(stretches)
        let byDay = Dictionary(grouping: all) { calendar.startOfDay(for: $0.start) }
        let days = byDay.keys.sorted(by: >).map { day in
            Day(day: day, longest: Array((byDay[day] ?? []).sorted(by: longerFirst).prefix(shownPerDay)))
        }
        var counts: [AppIdentity.ID: (app: AppIdentity, count: Int)] = [:]
        for streak in all where streak.seconds >= worthBreaking {
            if let breaker = streak.brokenBy {
                counts[breaker.id, default: (breaker, 0)].count += 1
            }
        }
        let breakers = counts.values
            .sorted { ($0.count, $1.app.name) > ($1.count, $0.app.name) }
            .prefix(shownBreakers)
            .map { Breaker(app: $0.app, count: $0.count) }
        return Report(days: days, breakers: breakers)
    }

    private static func longerFirst(_ lhs: FocusStreak, _ rhs: FocusStreak) -> Bool {
        (lhs.seconds, rhs.start) > (rhs.seconds, lhs.start)
    }
}
