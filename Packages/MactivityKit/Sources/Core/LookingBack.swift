import Foundation

/// Looking back (1.7, D-254): a month or a year of History in a few figures. Your month and
/// Your year are the same recap over a different span.
public struct PeriodRecap: Sendable, Equatable {
    public enum Span: String, Sendable, CaseIterable, Hashable {
        case month, year
    }

    public let span: Span
    /// The month or year, to now when it isn't over.
    public let interval: DateInterval
    /// Time in front of the Mac, and over the span before, when History reaches back that far.
    public let activeSeconds: Double
    public let previousActiveSeconds: Double?
    /// The days used most, most first, at most three.
    public let busiestDays: [DayTotal]
    /// For a year: the month used most.
    public let busiestMonth: DayTotal?
    /// Time in front, by app, most first.
    public let topApps: [AppTotal]
    /// Apps used for half an hour or more that weren't used at all in the span before.
    public let came: [AppTotal]
    /// Apps used an hour or more in the span before that weren't used at all in this one.
    public let went: [AppTotal]
    /// Coding agents' time, each quarter-hour once, and the project they worked in most.
    public let agentSeconds: Double
    public let topAgentProject: String?
    public let slowdowns: Int
    /// App crashes, for a month (macOS keeps crash reports about a month).
    public let crashes: Int?
    public let dataBytes: Double
    public let writtenBytes: Double
    public let notes: Int
    /// When time in use started recording, if that was during the span.
    public let recordingSince: Date?

    public init(
        span: Span, interval: DateInterval, activeSeconds: Double, previousActiveSeconds: Double?, busiestDays: [DayTotal],
        busiestMonth: DayTotal?, topApps: [AppTotal], came: [AppTotal], went: [AppTotal], agentSeconds: Double,
        topAgentProject: String?, slowdowns: Int, crashes: Int?, dataBytes: Double, writtenBytes: Double, notes: Int,
        recordingSince: Date?
    ) {
        self.span = span
        self.interval = interval
        self.activeSeconds = activeSeconds
        self.previousActiveSeconds = previousActiveSeconds
        self.busiestDays = busiestDays
        self.busiestMonth = busiestMonth
        self.topApps = topApps
        self.came = came
        self.went = went
        self.agentSeconds = agentSeconds
        self.topAgentProject = topAgentProject
        self.slowdowns = slowdowns
        self.crashes = crashes
        self.dataBytes = dataBytes
        self.writtenBytes = writtenBytes
        self.notes = notes
        self.recordingSince = recordingSince
    }

    /// Up or down against the span before, as a fraction; nil without enough to compare.
    public var activeChange: Double? {
        guard let previous = previousActiveSeconds, previous >= 3600, recordingSince == nil else {
            return nil
        }
        return (activeSeconds - previous) / previous
    }

    /// Nothing recorded: the card says so instead of a page of zeros.
    public var isEmpty: Bool {
        activeSeconds < 60 && topApps.isEmpty && dataBytes == 0
    }
}

public enum LookingBack {
    /// New this month: in front for at least this long.
    public static let cameAfter: TimeInterval = 30 * 60
    /// Gone this month: in front at least this long the month before.
    public static let wentAfter: TimeInterval = 3600

    /// Pure: the month or year holding `date`, cut at `now` when it's the current one.
    public static func interval(_ span: PeriodRecap.Span, containing date: Date, now: Date, calendar: Calendar = .current)
        -> DateInterval {
        let component: Calendar.Component = span == .month ? .month : .year
        let whole = calendar.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 86400)
        return DateInterval(start: whole.start, end: max(whole.start, min(whole.end, now)))
    }

    /// Pure: the whole span before `interval`'s (the month or year before, in full).
    public static func previous(_ span: PeriodRecap.Span, before interval: DateInterval, calendar: Calendar = .current) -> DateInterval {
        let component: Calendar.Component = span == .month ? .month : .year
        let start = calendar.date(byAdding: component, value: -1, to: interval.start) ?? interval.start
        return DateInterval(start: start, end: interval.start)
    }

    /// Pure: apps that came (used now, not at all before) and went (used before, not at all now).
    public static func cameAndWent(current: [AppTotal], previous: [AppTotal]) -> (came: [AppTotal], went: [AppTotal]) {
        let before = Set(previous.map(\.app.id))
        let now = Set(current.map(\.app.id))
        let came = current.filter { $0.value >= cameAfter && !before.contains($0.app.id) }
        let went = previous.filter { $0.value >= wentAfter && !now.contains($0.app.id) }
        return (Array(came.prefix(5)), Array(went.prefix(5)))
    }

    /// Pure: the days used most, at most `count`, most first; days with nothing left out.
    public static func busiest(_ days: [DayTotal], count: Int = 3) -> [DayTotal] {
        Array(days.filter { $0.seconds > 0 }.sorted { ($0.seconds, $1.day) > ($1.seconds, $0.day) }.prefix(count))
    }

    /// Pure: agents' time with two at once counted once (D-219), and the project worked in most.
    public static func agents(_ rows: [AgentUsage]) -> (seconds: Double, project: String?) {
        let minutes = Dictionary(grouping: rows, by: \.start).values.reduce(0) { $0 + ($1.map(\.minutes).max() ?? 0) }
        let byProject = Dictionary(grouping: rows.filter { !$0.project.isEmpty }, by: \.project)
            .mapValues { $0.reduce(0) { $0 + $1.minutes } }
        return (Double(minutes) * 60, byProject.max { $0.value < $1.value }?.key)
    }
}
