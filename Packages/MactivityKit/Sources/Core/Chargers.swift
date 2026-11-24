import Foundation

/// How far along the charge was. Batteries fill fastest when low and slow right down near full,
/// so a fill speed means nothing without this.
public enum ChargeBand: Int, CaseIterable, Hashable, Sendable {
    case low, middle, high

    public init(percent: Double) {
        switch percent {
        case ..<50: self = .low
        case ..<80: self = .middle
        default: self = .high
        }
    }
}

/// What a moment on a charger was like: only moments alike are compared (D-274).
public struct ChargeCondition: Hashable, Sendable {
    /// Nil while plugged in and not charging: full, or held short of full.
    public let band: ChargeBand?
    /// The battery at `warmFrom` or more: macOS slows charging as it warms. Nil if it isn't known.
    public let isWarm: Bool?
    /// The Mac itself drawing `busyFrom` or more, which leaves less of a small charger for the battery.
    public let isBusy: Bool

    public static let warmFrom = 35.0
    public static let busyFrom = 20.0

    public init(band: ChargeBand?, isWarm: Bool?, isBusy: Bool) {
        self.band = band
        self.isWarm = isWarm
        self.isBusy = isBusy
    }
}

/// One local day of one charger rating in one condition: a row of `charger_use` (D-274).
public struct ChargerUse: Hashable, Sendable {
    /// Local midnight.
    public let day: Date
    public let ratingWatts: Int
    public let condition: ChargeCondition
    public var seconds: Double = 0
    /// Net percentage points the battery gained.
    public var percentGained: Double = 0
    /// Σ delivered watts × seconds, and the seconds with a reading, for the average.
    public var deliveredWattSeconds: Double = 0
    public var deliveredSeconds: Double = 0
    public var peakWatts: Double?

    public init(
        day: Date, ratingWatts: Int, condition: ChargeCondition, seconds: Double = 0, percentGained: Double = 0,
        deliveredWattSeconds: Double = 0, deliveredSeconds: Double = 0, peakWatts: Double? = nil
    ) {
        self.day = day
        self.ratingWatts = ratingWatts
        self.condition = condition
        self.seconds = seconds
        self.percentGained = percentGained
        self.deliveredWattSeconds = deliveredWattSeconds
        self.deliveredSeconds = deliveredSeconds
        self.peakWatts = peakWatts
    }
}

public protocol ChargerHistoryStore: Sendable {
    /// Oldest first, up to `days` days back.
    func chargerUse(days: Int) async throws -> [ChargerUse]
}

/// Turns one snapshot after another into `ChargerUse` (D-274). No new reads: every figure is one
/// the battery sampler already takes each tick. Pure, for the store and the fixtures.
public struct ChargerTally: Sendable {
    /// A longer gap between snapshots is the Mac asleep. Nothing is counted across it, neither the
    /// time nor the charge, so charging in sleep doesn't flatter or hurt a charger.
    public static let longestCountedInterval: TimeInterval = 60

    private struct Key: Hashable {
        let day: Date
        let rating: Int
        let condition: ChargeCondition
    }

    private struct Moment {
        let at: Date
        let percent: Double
        let rating: Int
        let isCharging: Bool
    }

    private var unsaved: [Key: ChargerUse] = [:]
    private var last: Moment?

    public init() {}

    public var hasUnsaved: Bool {
        !unsaved.isEmpty
    }

    public mutating func add(_ battery: BatteryStats?, at: Date, calendar: Calendar = .current) {
        guard let battery, battery.source == .ac, let watts = battery.adapterWatts, watts >= 1 else {
            last = nil
            return
        }
        let rating = Int(watts.rounded())
        defer { last = Moment(at: at, percent: battery.percent, rating: rating, isCharging: battery.isCharging) }
        guard let last, last.rating == rating else {
            return
        }
        let elapsed = at.timeIntervalSince(last.at)
        guard elapsed > 0, elapsed <= Self.longestCountedInterval else {
            return
        }
        let condition = ChargeCondition(
            band: battery.isCharging ? ChargeBand(percent: last.percent) : nil,
            isWarm: battery.temperatureCelsius.map { $0 >= ChargeCondition.warmFrom },
            isBusy: (battery.systemLoadWatts ?? 0) >= ChargeCondition.busyFrom
        )
        let key = Key(day: calendar.startOfDay(for: at), rating: rating, condition: condition)
        var use = unsaved[key] ?? ChargerUse(day: key.day, ratingWatts: rating, condition: condition)
        use.seconds += elapsed
        if battery.isCharging, last.isCharging {
            use.percentGained += battery.percent - last.percent
        }
        if let delivered = battery.adapterInputWatts, delivered > 0 {
            use.deliveredWattSeconds += delivered * elapsed
            use.deliveredSeconds += elapsed
            use.peakWatts = max(use.peakWatts ?? 0, delivered)
        }
        unsaved[key] = use
    }

    /// What's accumulated since the last call; the store adds it to its rows.
    public mutating func drain() -> [ChargerUse] {
        defer { unsaved = [:] }
        return Array(unsaved.values)
    }

    /// Puts back what a failed write didn't save.
    public mutating func restore(_ uses: [ChargerUse]) {
        for use in uses {
            let key = Key(day: use.day, rating: use.ratingWatts, condition: use.condition)
            var merged = unsaved[key] ?? ChargerUse(day: use.day, ratingWatts: use.ratingWatts, condition: use.condition)
            merged.seconds += use.seconds
            merged.percentGained += use.percentGained
            merged.deliveredWattSeconds += use.deliveredWattSeconds
            merged.deliveredSeconds += use.deliveredSeconds
            merged.peakWatts = [merged.peakWatts, use.peakWatts].compactMap(\.self).max()
            unsaved[key] = merged
        }
    }
}

/// Chargers compared (D-274): what each power rating really delivers and how fast it fills the
/// battery. Pure. Two chargers are told apart only by rating, since that's all a Mac reports, so
/// two of the same rating count as one.
public struct ChargerComparison: Hashable, Sendable {
    public struct Charger: Hashable, Sendable, Identifiable {
        public let ratingWatts: Int
        public let chargingSeconds: Double
        /// The average while charging, and the highest ever: a lightly loaded Mac at full asks
        /// little of any charger, so the time at full doesn't lower what it can deliver.
        public let averageDeliveredWatts: Double?
        public let peakDeliveredWatts: Double?
        /// Percent an hour by charge level, when `minimumBandSeconds` were spent there. These
        /// mix warm and cool, light and busy: for reading, not for judging. `verdicts` judges.
        public let fillSpeed: [ChargeBand: Double]

        public var id: Int {
            ratingWatts
        }
    }

    public enum Verdict: Hashable, Sendable {
        /// Like for like, `faster` filled it this many times as fast as `slower`.
        case faster(faster: Int, slower: Int, ratio: Double, matchedSeconds: Double)
        case aboutTheSame(first: Int, second: Int, matchedSeconds: Double)
        /// Not yet: how much of `minimumMatchedSeconds` they have.
        case tooLittle(first: Int, second: Int, matchedSeconds: Double)
    }

    public let chargers: [Charger]
    public let verdicts: [Verdict]
    /// The first day anything was recorded.
    public let since: Date?

    /// Shown only after this long at that charge level.
    public static let minimumBandSeconds = 600.0
    /// A condition counts for a pair only when each spent this long in it: under that, a single
    /// percent's rounding moves the answer.
    public static let minimumCellSeconds = 900.0
    /// In all, like for like, before anything is said.
    public static let minimumMatchedSeconds = 3600.0
    public static let minimumMatchedPercent = 20.0
    /// Closer than this is the same charger for anyone's purposes.
    public static let clearDifference = 1.15

    private struct Tally {
        var seconds = 0.0
        var percent = 0.0

        var perHour: Double {
            seconds > 0 ? percent / seconds * 3600 : 0
        }
    }

    public static func read(_ uses: [ChargerUse]) -> ChargerComparison {
        let byRating = Dictionary(grouping: uses, by: \.ratingWatts)
        let chargers = byRating.keys.sorted(by: >).compactMap { rating -> Charger? in
            byRating[rating].map { charger(rating, $0) }
        }
        var verdicts: [Verdict] = []
        let ratings = chargers.map(\.ratingWatts)
        for (index, first) in ratings.enumerated() {
            for second in ratings.dropFirst(index + 1) {
                verdicts.append(verdict(first, byRating[first] ?? [], second, byRating[second] ?? []))
            }
        }
        return ChargerComparison(chargers: chargers, verdicts: verdicts, since: uses.map(\.day).min())
    }

    private static func charger(_ rating: Int, _ uses: [ChargerUse]) -> Charger {
        let charging = uses.filter { $0.condition.band != nil }
        let seconds = charging.reduce(0.0) { $0 + $1.deliveredSeconds }
        let energy = charging.reduce(0.0) { $0 + $1.deliveredWattSeconds }
        var speed: [ChargeBand: Double] = [:]
        for band in ChargeBand.allCases {
            let tally = tally(charging.filter { $0.condition.band == band })
            if tally.seconds >= minimumBandSeconds {
                speed[band] = tally.perHour
            }
        }
        return Charger(
            ratingWatts: rating,
            chargingSeconds: charging.reduce(0) { $0 + $1.seconds },
            averageDeliveredWatts: seconds > 0 ? energy / seconds : nil,
            peakDeliveredWatts: uses.compactMap(\.peakWatts).max(),
            fillSpeed: speed
        )
    }

    private static func tally(_ uses: [ChargerUse]) -> Tally {
        uses.reduce(into: Tally()) { tally, use in
            tally.seconds += use.seconds
            tally.percent += use.percentGained
        }
    }

    private static func cells(_ uses: [ChargerUse]) -> [ChargeCondition: Tally] {
        Dictionary(grouping: uses.filter { $0.condition.band != nil }, by: \.condition).mapValues(tally)
    }

    /// Compares only conditions both chargers spent real time in, each weighted by the smaller of
    /// their two times there, so neither's easiest moments carry it.
    private static func verdict(_ first: Int, _ firstUses: [ChargerUse], _ second: Int, _ secondUses: [ChargerUse]) -> Verdict {
        let firstCells = cells(firstUses)
        let secondCells = cells(secondUses)
        var matched = 0.0
        var firstSpeed = 0.0
        var secondSpeed = 0.0
        var firstPercent = 0.0
        var secondPercent = 0.0
        for (condition, a) in firstCells {
            guard let b = secondCells[condition], a.seconds >= minimumCellSeconds, b.seconds >= minimumCellSeconds else {
                continue
            }
            let weight = min(a.seconds, b.seconds)
            matched += weight
            firstSpeed += a.perHour * weight
            secondSpeed += b.perHour * weight
            firstPercent += a.percent
            secondPercent += b.percent
        }
        guard matched >= minimumMatchedSeconds, firstPercent >= minimumMatchedPercent, secondPercent >= minimumMatchedPercent,
              firstSpeed > 0, secondSpeed > 0
        else {
            return .tooLittle(first: first, second: second, matchedSeconds: matched)
        }
        let ratio = max(firstSpeed, secondSpeed) / min(firstSpeed, secondSpeed)
        guard ratio >= clearDifference else {
            return .aboutTheSame(first: first, second: second, matchedSeconds: matched)
        }
        return firstSpeed > secondSpeed
            ? .faster(faster: first, slower: second, ratio: ratio, matchedSeconds: matched)
            : .faster(faster: second, slower: first, ratio: ratio, matchedSeconds: matched)
    }
}

/// How warm the battery ran over a range (D-275): each side's average and peak, in °C. Pure.
public struct BatteryTemperatureSummary: Hashable, Sendable {
    public struct Side: Hashable, Sendable {
        public let average: Double
        public let peak: Double
    }

    public let charging: Side?
    public let inUse: Side?
    /// When recording began, if that was well inside the range: the figures cover less than it.
    public let since: Date?

    /// Nil without a reading in the range.
    public static func read(charging: [SeriesPoint], inUse: [SeriesPoint], rangeStart: Date) -> BatteryTemperatureSummary? {
        func side(_ points: [SeriesPoint]) -> Side? {
            guard !points.isEmpty else {
                return nil
            }
            return Side(
                average: points.map(\.average).reduce(0, +) / Double(points.count),
                peak: points.map { max($0.maximum, $0.average) }.max() ?? 0
            )
        }
        let charging = charging.filter { $0.at >= rangeStart }
        let inUse = inUse.filter { $0.at >= rangeStart }
        guard let first = (charging + inUse).map(\.at).min() else {
            return nil
        }
        let late = first.timeIntervalSince(rangeStart) > PowerSummary.lateStart
        return BatteryTemperatureSummary(charging: side(charging), inUse: side(inUse), since: late ? first : nil)
    }
}
