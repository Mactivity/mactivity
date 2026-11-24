import Foundation

/// One hour row of the whole Mac: its processor average and the minutes of that hour it was awake
/// and recording (D-108).
public struct HourSample: Hashable, Sendable {
    public let at: Date
    /// Percent of the whole processor.
    public let cpu: Double
    public let coveredMinutes: Double

    public init(at: Date, cpu: Double, coveredMinutes: Double) {
        self.at = at
        self.cpu = cpu
        self.coveredMinutes = coveredMinutes
    }
}

/// The whole Mac's hours, for the weekday-by-hour grid (D-272).
public protocol HourRhythmStore: Sendable {
    /// Oldest first; only hours with samples.
    func wholeMacHours(from: Date, to: Date) async throws -> [HourSample]
}

/// Busiest hours (D-272): each day of the week by the hour, from the hour tier's whole-Mac rows,
/// on the Mac's own clock and first day of the week. Pure.
///
/// A cell averages only the minutes the Mac recorded in that weekday's hour, weighted by them. A
/// day without samples, or an hour asleep, adds nothing, so it doesn't count as idle: a cell with
/// no samples at all is blank, not 0%.
public struct BusiestHours: Hashable, Sendable {
    public struct Cell: Hashable, Sendable, Identifiable {
        /// 1 is Sunday, as `Calendar` numbers them.
        public let weekday: Int
        /// 0…23 on the Mac's clock.
        public let hour: Int
        /// Percent of the whole processor while it was awake then.
        public let average: Double
        public let minutes: Double
        /// How many different dates fed it.
        public let days: Int

        public var id: Int {
            weekday * 100 + hour
        }
    }

    public let cells: [Cell]
    /// The busiest and the quietest cell seen often enough to name. Nil until `minimumDays`.
    public let hardest: Cell?
    public let idlest: Cell?
    /// Dates with any samples.
    public let dayCount: Int
    /// The earliest sample.
    public let since: Date?

    /// A named cell needs this much behind it: one Tuesday's backup isn't "Tuesdays at 3".
    public static let namedMinutes = 120.0
    public static let namedDays = 2
    /// Fewer days of history than a week can't say anything about the week.
    public static let minimumDays = 7
    public static let weeks = 12

    public static func read(_ samples: [HourSample], calendar: Calendar = .current) -> BusiestHours {
        struct Key: Hashable {
            let weekday: Int
            let hour: Int
        }
        var weighted: [Key: Double] = [:]
        var minutes: [Key: Double] = [:]
        var dates: [Key: Set<Date>] = [:]
        var allDates: Set<Date> = []
        for sample in samples where sample.coveredMinutes > 0 && sample.cpu.isFinite {
            let key = Key(weekday: calendar.component(.weekday, from: sample.at), hour: calendar.component(.hour, from: sample.at))
            let day = calendar.startOfDay(for: sample.at)
            weighted[key, default: 0] += sample.cpu * sample.coveredMinutes
            minutes[key, default: 0] += sample.coveredMinutes
            dates[key, default: []].insert(day)
            allDates.insert(day)
        }
        let cells = minutes.map { key, total in
            Cell(
                weekday: key.weekday, hour: key.hour, average: (weighted[key] ?? 0) / total, minutes: total,
                days: dates[key]?.count ?? 0
            )
        }
        .sorted { ($0.weekday, $0.hour) < ($1.weekday, $1.hour) }
        let named = allDates.count >= minimumDays ? cells.filter { $0.minutes >= namedMinutes && $0.days >= namedDays } : []
        let hardest = named.max { ($0.average, $1.id) < ($1.average, $0.id) }
        let idlest = named.min { ($0.average, $0.id) < ($1.average, $1.id) }
        return BusiestHours(
            cells: cells, hardest: hardest, idlest: named.count > 1 ? idlest : nil, dayCount: allDates.count,
            since: samples.map(\.at).min()
        )
    }

    /// Weekdays in the order this Mac's calendar shows them, first day of the week first.
    public static func weekdays(calendar: Calendar = .current) -> [Int] {
        (0 ..< 7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }
}
