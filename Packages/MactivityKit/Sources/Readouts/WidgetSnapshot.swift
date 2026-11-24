import Core
import Foundation

/// The few figures the desktop widgets show (E7), as the small JSON file the app writes into the
/// shared app group container. The widget extension is sandboxed and can't sample; this file is
/// all it sees.
///
/// Schema (version 1), keys sorted, dates ISO 8601:
/// `version`, `updatedAt`, `cpuPercent` (0–100), `cpuHistory` (per-minute CPU means, oldest
/// first, at most 30), `memoryUsedBytes`, `memoryTotalBytes`, `memoryPressure`
/// (normal | warning | critical), `battery` ({`percent`, `isCharging`, `onAC`} or absent on
/// desktops), `gpuPercent` (0–100, or absent when the GPU isn't read; the widget shows it where a
/// desktop has no battery), `topApps` (up to 3 by CPU, macOS row excluded: {`name`, `bundleID`,
/// `cpuPercent`, `memoryBytes`}). `gpuPercent` is optional, so version 1 files without it still read.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "widget-snapshot.json"
    /// The one widget kind (small, medium, large). The app reloads it by this name.
    public static let widgetKind = "app.mactivity.widget.system"
    /// The Today so far widget (D-200).
    public static let todayWidgetKind = "app.mactivity.widget.today"
    /// The app group, after the team prefix: `<TEAMID>.app.mactivity`.
    public static let groupSuffix = "app.mactivity"
    /// Past this age the widget stops showing figures and says "Open Mactivity".
    public static let staleAfter: TimeInterval = 90 * 60
    public static let historyLength = 30
    public static let topAppCount = 3

    public struct Battery: Codable, Equatable, Sendable {
        public var percent: Double
        public var isCharging: Bool
        public var onAC: Bool

        public init(percent: Double, isCharging: Bool, onAC: Bool) {
            self.percent = percent
            self.isCharging = isCharging
            self.onAC = onAC
        }
    }

    public struct TopApp: Codable, Equatable, Sendable {
        public var name: String
        public var bundleID: String?
        public var cpuPercent: Double
        public var memoryBytes: UInt64

        public init(name: String, bundleID: String?, cpuPercent: Double, memoryBytes: UInt64) {
            self.name = name
            self.bundleID = bundleID
            self.cpuPercent = cpuPercent
            self.memoryBytes = memoryBytes
        }
    }

    /// Today so far (D-200): the day's events for the ribbon, as Your day reads them. Absent in
    /// files from before it, and until the app has read the day.
    public struct Today: Codable, Equatable, Sendable {
        public var dayStart: Date
        public var activeSeconds: Double
        public var marks: [WidgetDayMark]
        /// As Overview counts them (D-219): every alert, repeats included, and agents' time with
        /// overlapping sessions once. Nil in files from before.
        public var alertCount: Int?
        public var agentSeconds: Double?

        public init(dayStart: Date, activeSeconds: Double, marks: [WidgetDayMark], alertCount: Int? = nil, agentSeconds: Double? = nil) {
            self.dayStart = dayStart
            self.activeSeconds = activeSeconds
            self.marks = marks
            self.alertCount = alertCount
            self.agentSeconds = agentSeconds
        }

        public init(_ result: DayStoryResult, dayStart: Date) {
            let alerts = result.events.reduce(0) { total, event in
                if case let .alert(_, _, count) = event.kind {
                    return total + count
                }
                return total
            }
            self.init(
                dayStart: dayStart, activeSeconds: result.activeSeconds,
                marks: result.events.map { WidgetDayMark(start: $0.start, end: $0.end, kind: $0.kind.code) },
                alertCount: alerts, agentSeconds: result.agentSeconds
            )
        }
    }

    public var version: Int
    public var updatedAt: Date
    public var cpuPercent: Double
    public var cpuHistory: [Double]
    public var memoryUsedBytes: UInt64
    public var memoryTotalBytes: UInt64
    public var memoryPressure: MemoryPressure
    public var battery: Battery?
    public var gpuPercent: Double?
    public var topApps: [TopApp]
    public var today: Today?

    public init(
        updatedAt: Date,
        cpuPercent: Double,
        cpuHistory: [Double],
        memoryUsedBytes: UInt64,
        memoryTotalBytes: UInt64,
        memoryPressure: MemoryPressure,
        battery: Battery?,
        gpuPercent: Double? = nil,
        topApps: [TopApp]
    ) {
        version = Self.currentVersion
        self.updatedAt = updatedAt
        self.cpuPercent = cpuPercent
        self.cpuHistory = cpuHistory
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryPressure = memoryPressure
        self.battery = battery
        self.gpuPercent = gpuPercent
        self.topApps = topApps
    }

    public init(snapshot: Snapshot, cpuHistory: [Double]) {
        let system = snapshot.system
        self.init(
            updatedAt: snapshot.at,
            cpuPercent: system.cpu.totalPercent,
            cpuHistory: Array(cpuHistory.suffix(Self.historyLength)),
            memoryUsedBytes: system.memory.usedBytes,
            memoryTotalBytes: system.memory.totalBytes,
            memoryPressure: system.memory.pressure,
            battery: system.battery.map { Battery(percent: $0.percent, isCharging: $0.isCharging, onAC: $0.source == .ac) },
            gpuPercent: system.gpu?.utilizationPercent,
            topApps: AppRanking.cpu.rank(snapshot.apps, limit: Self.topAppCount, includingSystem: false).map {
                TopApp(name: $0.app.name, bundleID: $0.app.bundleID, cpuPercent: $0.cpuPercent, memoryBytes: $0.memoryBytes)
            }
        )
    }

    public var memoryUsedPercent: Double {
        memoryTotalBytes == 0 ? 0 : Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100
    }

    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) >= Self.staleAfter
    }

    // MARK: Codec

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Nil for garbage, a truncated file, or a version this build doesn't know.
    public static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version == currentVersion
        else {
            return nil
        }
        return snapshot
    }

    /// Nil when the file is missing or unreadable, which the widget shows as "Open Mactivity".
    public static func load(from url: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return decode(data)
    }

    /// `<TEAMID>.app.mactivity`, or nil in ad-hoc builds, which have no team and so no usable
    /// app group (macOS only honors team-prefixed groups without a provisioning profile).
    public static func appGroupIdentifier(teamID: String?) -> String? {
        guard let teamID, !teamID.isEmpty else {
            return nil
        }
        return "\(teamID).\(groupSuffix)"
    }
}

/// One event on the widget's Today ribbon (D-200).
public struct WidgetDayMark: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date?
    /// `DayEvent.Kind.code`: "wake", "slowdown", "agent"…
    public var kind: String

    public init(start: Date, end: Date?, kind: String) {
        self.start = start
        self.end = end
        self.kind = kind
    }
}
