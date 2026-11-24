import Foundation

/// What this Mac did over 7 or 30 days, for "Your next Mac" (D-181): the whole Mac's series from
/// History and what it has today. Everything is optional in practice: a series left empty
/// drops its part of the advice rather than guessing.
public struct UpgradeInputs: Sendable {
    public var days: Int
    public var installedMemory: UInt64
    public var performanceCores: Int
    public var diskCapacity: UInt64
    public var hasBattery: Bool
    /// The series' spacing: 900 for quarter-hours.
    public var bucketSeconds: TimeInterval = 900
    /// Whole-Mac CPU, percent.
    public var cpu: [SeriesPoint] = []
    /// Memory used, bytes.
    public var memoryUsed: [SeriesPoint] = []
    /// Memory pressure, percent (100 − `kern.memorystatus_level`).
    public var memoryPressure: [SeriesPoint] = []
    /// Swap used, bytes.
    public var swap: [SeriesPoint] = []
    /// GPU utilization, percent.
    public var gpu: [SeriesPoint] = []
    /// Thermal pressure rank, 0 nominal … 3 critical.
    public var thermal: [SeriesPoint] = []
    /// Share of each bucket on battery, 0…1.
    public var onBattery: [SeriesPoint] = []
    /// Battery charge, percent.
    public var batteryLevel: [SeriesPoint] = []
    /// Free space on the startup disk, per day.
    public var diskFree: [DayValue] = []
    /// The apps behind each, busiest first.
    public var cpuApps: [String] = []
    public var memoryApps: [String] = []
    public var gpuApps: [String] = []
    /// The desk over the span: displays and the lid (D-237); nil without a day of it.
    public var desk: DeskUsage?

    public init(days: Int, installedMemory: UInt64, performanceCores: Int, diskCapacity: UInt64, hasBattery: Bool) {
        self.days = days
        self.installedMemory = installedMemory
        self.performanceCores = performanceCores
        self.diskCapacity = diskCapacity
        self.hasBattery = hasBattery
    }
}

public struct UpgradeAdvice: Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case processor, memory, graphics, storage, battery
    }

    /// How well this Mac fits the work: what the next one needs to improve on.
    public enum Fit: Int, Hashable, Sendable, Comparable {
        case plenty, comfortable, tight, short

        public static func < (lhs: Fit, rhs: Fit) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Apple silicon comes in three classes; the generation doesn't change which one fits.
    public enum ChipClass: Int, Hashable, Sendable, Comparable {
        case base, pro, max

        public static func < (lhs: ChipClass, rhs: ChipClass) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Laptops for a Mac that has a battery, desktops for one that doesn't (D-187).
    public enum Form: Hashable, Sendable {
        case air, pro, mini, studio

        /// Product names, the same in every language.
        public var name: String {
            switch self {
            case .air: "MacBook Air"
            case .pro: "MacBook Pro"
            case .mini: "Mac mini"
            case .studio: "Mac Studio"
            }
        }

        /// The SF Symbol drawn beside the name.
        public var symbol: String {
            switch self {
            case .air, .pro: "laptopcomputer"
            case .mini: "macmini"
            case .studio: "macstudio"
            }
        }
    }

    /// Use as shares of what this Mac has: typical (median), busy (95th percentile), peak.
    public struct Usage: Hashable, Sendable {
        public let typical: Double
        public let busy: Double
        public let peak: Double
    }

    public struct Need: Hashable, Sendable, Identifiable {
        public var id: Kind {
            kind
        }

        public let kind: Kind
        public let fit: Fit
        /// What to buy: "32 GB", "Pro chip", "1 TB".
        public let verdict: String
        /// One sentence: what the history says.
        public let headline: String
        /// The figures behind it.
        public let evidence: [String]
        public let usage: Usage?
        /// The app that drove it most.
        public let topApp: String?
    }

    /// One hour of an average day, as shares of capacity in percent.
    public struct Hour: Hashable, Sendable, Identifiable {
        public var id: Int {
            hour
        }

        public let hour: Int
        public let cpu: Double
        public let memory: Double
        public let gpu: Double?
    }

    public var needs: [Need] = []
    public var form = Form.air
    /// Why that form, one sentence.
    public var formReason = ""
    public var chip = ChipClass.base
    public var memoryVerdict: UInt64 = 0
    public var storageVerdict: UInt64 = 0
    /// The average day, hour by hour.
    public var day: [Hour] = []
    /// The busiest stretch of the average day: its first and last hour.
    public var busiestHours: ClosedRange<Int>?
    /// How much history this rests on.
    public var hoursRecorded: Double = 0
    /// The desk it rests on too (D-237), and what it changes: notes under the pick, and another
    /// Mac worth weighing.
    public var desk: DeskUsage?
    public var deskNotes: [String] = []
    public var alternative: Alternative?

    public struct Alternative: Sendable, Hashable {
        public let form: Form
        public let reason: String
    }

    /// Under three days of history: a first look, said so on the page.
    public var isEarly: Bool {
        hoursRecorded < 72
    }

    public func need(_ kind: Kind) -> Need? {
        needs.first { $0.kind == kind }
    }
}
