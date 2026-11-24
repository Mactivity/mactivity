import Foundation

// Value types used by the non-sampling protocols in DataSources.swift.

// MARK: - Projects (spec 5.5, 6.12)

public struct ListeningPort: Hashable, Sendable, Codable, Identifiable {
    public enum Transport: String, Hashable, Sendable, Codable {
        case tcp4, tcp6
    }

    public let pid: Int32
    public let port: UInt16
    public let transport: Transport
    /// Local address, e.g. "127.0.0.1", "::", "*".
    public let address: String
    /// `pvi_cdir` of the owning process, when readable.
    public let workingDirectory: String?

    public var id: String {
        "\(pid):\(transport.rawValue):\(port)"
    }

    public init(pid: Int32, port: UInt16, transport: Transport, address: String, workingDirectory: String?) {
        self.pid = pid
        self.port = port
        self.transport = transport
        self.address = address
        self.workingDirectory = workingDirectory
    }
}

// MARK: - Audio (spec 5.7, M10)

/// One process playing audio, with the settings Mactivity applies to its app.
public struct AudioClient: Hashable, Sendable, Codable, Identifiable {
    public let pid: Int32
    public let app: AppIdentity.ID
    /// The app's level, 0...1. Kept while muted, so unmuting restores it.
    public let volume: Double
    public let isMuted: Bool
    /// The output device the app is sent to, by `kAudioDevicePropertyDeviceUID`. Nil follows the system default.
    public let outputDeviceUID: String?
    /// What the settings are remembered under: the bundle ID, else the executable path. Processes of one app
    /// share a key, and a change to one applies to all of them.
    public let settingsKey: String
    /// Remembered settings that couldn't be applied: Mactivity can't hear the app (audio-capture consent),
    /// so it plays untouched on its own output.
    public let needsPermission: Bool

    public var id: Int32 {
        pid
    }

    public var setting: AudioAppSetting {
        AudioAppSetting(volume: volume, isMuted: isMuted, outputDeviceUID: outputDeviceUID)
    }

    public init(
        pid: Int32,
        app: AppIdentity.ID,
        volume: Double,
        isMuted: Bool = false,
        outputDeviceUID: String? = nil,
        settingsKey: String? = nil,
        needsPermission: Bool = false
    ) {
        self.pid = pid
        self.app = app
        self.volume = volume
        self.isMuted = isMuted
        self.outputDeviceUID = outputDeviceUID
        self.settingsKey = settingsKey ?? app
        self.needsPermission = needsPermission
    }

    private enum CodingKeys: String, CodingKey {
        case pid, app, volume, isMuted, outputDeviceUID, settingsKey, needsPermission
    }

    /// Fields added after M10 are optional, so older fixtures still decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let app = try container.decode(AppIdentity.ID.self, forKey: .app)
        try self.init(
            pid: container.decode(Int32.self, forKey: .pid),
            app: app,
            volume: container.decode(Double.self, forKey: .volume),
            isMuted: container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            outputDeviceUID: container.decodeIfPresent(String.self, forKey: .outputDeviceUID),
            settingsKey: container.decodeIfPresent(String.self, forKey: .settingsKey),
            needsPermission: container.decodeIfPresent(Bool.self, forKey: .needsPermission) ?? false
        )
    }
}

/// What Mactivity applies to one app's audio, remembered across launches.
public struct AudioAppSetting: Hashable, Sendable, Codable {
    /// 0...1. Kept while muted.
    public var volume: Double
    public var isMuted: Bool
    /// `kAudioDevicePropertyDeviceUID` of the chosen output. Nil follows the system default.
    public var outputDeviceUID: String?

    /// 100%, unmuted, on the system default: the app plays exactly as it would without Mactivity.
    public static let untouched = AudioAppSetting()

    public init(volume: Double = 1, isMuted: Bool = false, outputDeviceUID: String? = nil) {
        self.volume = volume
        self.isMuted = isMuted
        self.outputDeviceUID = outputDeviceUID
    }

    public var isUntouched: Bool {
        volume >= 1 && !isMuted && outputDeviceUID == nil
    }

    /// What the app plays at: 0 while muted, else its level.
    public var effectiveVolume: Double {
        isMuted ? 0 : volume
    }
}

/// An output device an app can be sent to.
public struct AudioOutputDevice: Hashable, Sendable, Codable, Identifiable {
    /// `kAudioDevicePropertyDeviceUID`: stable across reconnects and reboots, unlike the `AudioObjectID`.
    public let uid: String
    public let name: String
    public let isDefault: Bool

    public var id: String {
        uid
    }

    public init(uid: String, name: String, isDefault: Bool) {
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
    }
}

// MARK: - History (spec 6.7)

public struct SeriesPoint: Hashable, Sendable, Codable {
    public let at: Date
    public let average: Double
    public let maximum: Double

    public init(at: Date, average: Double, maximum: Double) {
        self.at = at
        self.average = average
        self.maximum = maximum
    }
}

public struct AppTotal: Hashable, Sendable, Codable, Identifiable {
    public let app: AppIdentity
    /// Average for rate metrics over the range; the sum for counters ("written today").
    public let value: Double

    public var id: AppIdentity.ID {
        app.id
    }

    public init(app: AppIdentity, value: Double) {
        self.app = app
        self.value = value
    }
}

// MARK: - Alerts (spec 5.4, 6.8)

public struct Alert: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let rule: AlertRule
    public let app: AppIdentity
    public let firedAt: Date
    /// "Slack's memory keeps climbing"
    public let title: String
    /// The evidence: "Up 1.4 GB in an hour, now 3.3 GB."
    public let body: String

    public init(id: UUID = UUID(), rule: AlertRule, app: AppIdentity, firedAt: Date, title: String, body: String) {
        self.id = id
        self.rule = rule
        self.app = app
        self.firedAt = firedAt
        self.title = title
        self.body = body
    }
}

// MARK: - Termination (spec 5.8, CLAUDE.md rule 4)

public enum TerminationMode: String, Hashable, Sendable, Codable {
    /// Normal termination (`NSRunningApplication.terminate` / SIGTERM).
    case quit
    /// SIGKILL.
    case forceQuit
}

public enum TerminationTarget: Hashable, Sendable, Codable {
    case app(AppIdentity.ID, pids: [Int32])
    case process(Int32)
    /// A dev server: SIGTERM to the process group, then SIGKILL after 5 s (spec 6.12).
    case processGroup(Int32)
    /// A Docker container, stopped through the Docker Engine API (expansion E5).
    case container(id: String, name: String)
}

/// Proof that the user confirmed a termination in the UI.
///
/// Only the `ConfirmedAction` path in the UI target creates these: the initializer is
/// `package`-scoped, so nothing outside MactivityKit can build one, and inside the package the
/// only caller is `ConfirmedAction` (CLAUDE.md rule 4). A `ProcessTerminator` accepts nothing else.
public struct ConfirmedTermination: Hashable, Sendable {
    public let target: TerminationTarget
    public let mode: TerminationMode
    public let confirmedAt: Date

    package init(target: TerminationTarget, mode: TerminationMode, confirmedAt: Date) {
        self.target = target
        self.mode = mode
        self.confirmedAt = confirmedAt
    }
}

public struct TerminationResult: Hashable, Sendable, Codable {
    public let terminated: [Int32]
    /// PIDs still alive afterwards, e.g. root-owned processes without the helper.
    public let survivors: [Int32]

    public init(terminated: [Int32], survivors: [Int32]) {
        self.terminated = terminated
        self.survivors = survivors
    }
}

// MARK: - Battery health history (expansion E14)

/// One day of battery health: the day's last capacity and cycle readings, and time on battery.
public struct BatteryDay: Hashable, Sendable, Codable, Identifiable {
    /// Local midnight.
    public let day: Date
    public let maxCapacityPercent: Double?
    public let cycleCount: Int?
    public let minutesOnBattery: Double

    public var id: Date {
        day
    }

    public init(day: Date, maxCapacityPercent: Double?, cycleCount: Int?, minutesOnBattery: Double) {
        self.day = day
        self.maxCapacityPercent = maxCapacityPercent
        self.cycleCount = cycleCount
        self.minutesOnBattery = minutesOnBattery
    }
}

public protocol BatteryHistoryStore: Sendable {
    /// Oldest first, up to `days` days back.
    func batteryHistory(days: Int) async throws -> [BatteryDay]
}

// MARK: - A year at a glance, and export (D-093)

/// One local day of a metric, system-wide: History's year calendar.
public struct DayValue: Hashable, Sendable {
    /// Local midnight.
    public let day: Date
    /// Mean of the day's hourly averages.
    public let average: Double
    /// Highest hourly peak.
    public let maximum: Double

    public init(day: Date, average: Double, maximum: Double) {
        self.day = day
        self.average = average
        self.maximum = maximum
    }
}

/// Day-sized reads for the year calendar and the day it opens.
public protocol DailyHistoryStore: Sendable {
    /// One value per local day for the last `days` days, oldest first. Days without data are left out.
    func dailyValues(metric: Metric, days: Int) async throws -> [DayValue]
    /// A series between two dates (`app == nil`: system-wide), at the finest detail still kept there.
    func series(metric: Metric, app: AppIdentity.ID?, from: Date, to: Date) async throws -> [SeriesPoint]
    /// Apps ranked by their average between two dates, highest first. Never the system-wide row.
    func topApps(metric: Metric, from: Date, to: Date, limit: Int) async throws -> [AppTotal]
    /// Each app's total between two dates, summed over `metrics`: Σ average × bucket seconds, so
    /// bytes for the network rates (D-095). Highest first; never the system-wide row.
    func totals(metrics: [Metric], from: Date, to: Date, limit: Int) async throws -> [AppTotal]
    /// The whole Mac's total between two dates, summed over `metrics`.
    func systemTotal(metrics: [Metric], from: Date, to: Date) async throws -> Double
    /// When the oldest history still kept was recorded; nil before anything was (D-112).
    func firstRecorded() async throws -> Date?
}

/// A total over a span that history may not fully cover (D-112), from history and a counter
/// that has run since startup (the disks' own byte counts).
public struct SpanTotal: Hashable, Sendable {
    public let value: Double
    /// True when history starts inside the span, so the span's true total is at least `value`.
    public let isLowerBound: Bool

    public init(value: Double, isLowerBound: Bool) {
        self.value = value
        self.isLowerBound = isLowerBound
    }

    /// History starting within this long after a span's start still counts as covering it.
    static let slack: TimeInterval = 3600

    /// Pure. A span that began before startup is everything since startup, exactly, from the
    /// counter, plus history from the span's start to startup. One that began after startup is
    /// history alone, never more than the counter. Either is a lower bound when history starts
    /// inside the span: a fresh install knows its totals only since startup.
    /// `sinceStartup` is the disks' own byte counter, as they report it.
    public static func combine(
        spanStart: Date, boot: Date, sinceStartup counter: UInt64?, historyBeforeBoot: Double, historySinceStart: Double,
        firstRecorded: Date?
    ) -> SpanTotal {
        let covered = firstRecorded.map { $0.timeIntervalSince(spanStart) <= slack } ?? false
        // A closure, not `.map(Double.init)`: for a UInt64 that picks Double(bitPattern:), which
        // read a terabyte as 5e-312 and showed Today and 7 days as 0 B.
        guard let sinceStartup = counter.map({ Double($0) }) else {
            return SpanTotal(value: historySinceStart, isLowerBound: !covered)
        }
        if spanStart <= boot {
            return SpanTotal(value: historyBeforeBoot + sinceStartup, isLowerBound: !covered)
        }
        return SpanTotal(value: min(historySinceStart, sinceStartup), isLowerBound: !covered)
    }
}

// MARK: - Accessory batteries over time (D-094)

/// AirPods, mice, keyboards and trackpads, read on their own slow schedule so their history
/// doesn't depend on whether sensors are on screen.
public protocol PeripheralBatterySource: Sendable {
    func peripherals() async -> [PeripheralBattery]
}

public struct DeviceBatteryPoint: Hashable, Sendable {
    public let at: Date
    public let percent: Double

    public init(at: Date, percent: Double) {
        self.at = at
        self.percent = percent
    }
}

/// One accessory's recorded levels, oldest first, under its latest name.
public struct DeviceBatteryHistory: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: PeripheralBattery.Kind
    public let points: [DeviceBatteryPoint]

    public init(id: String, name: String, kind: PeripheralBattery.Kind, points: [DeviceBatteryPoint]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.points = points
    }

    /// When it was last charged, how fast it drains since, and how long that leaves.
    public func insight(now: Date) -> DeviceBatteryInsight {
        DeviceBatteryInsight(points: points, now: now)
    }
}

public struct DeviceBatteryInsight: Hashable, Sendable {
    /// The end of the latest charge: where a rise of at least `chargeRise` points topped out.
    public let lastCharged: Date?
    /// Percentage points a day since then. Nil until it has dropped `minimumDrop` over `minimumSpan`.
    public let drainPerDay: Double?
    /// At that rate, from the latest level.
    public let daysLeft: Double?

    static let chargeRise = 5.0
    static let minimumDrop = 3.0
    static let minimumSpan: TimeInterval = 6 * 3600

    public init(points: [DeviceBatteryPoint], now: Date) {
        guard let latest = points.last else {
            lastCharged = nil
            drainPerDay = nil
            daysLeft = nil
            return
        }
        // Walk back from the latest level to the peak it has been draining from, then check that
        // peak was reached by charging (a rise), not just the first reading.
        var peakIndex = points.count - 1
        while peakIndex > 0, points[peakIndex - 1].percent >= points[peakIndex].percent {
            peakIndex -= 1
        }
        var troughIndex = peakIndex
        while troughIndex > 0, points[troughIndex - 1].percent <= points[troughIndex].percent {
            troughIndex -= 1
        }
        let rose = points[peakIndex].percent - points[troughIndex].percent >= Self.chargeRise
        lastCharged = rose ? points[peakIndex].at : nil
        let peak = points[peakIndex]
        let drop = peak.percent - latest.percent
        let span = latest.at.timeIntervalSince(peak.at)
        if drop >= Self.minimumDrop, span >= Self.minimumSpan {
            let perDay = drop / (span / 86400)
            drainPerDay = perDay
            daysLeft = latest.percent / perDay
        } else {
            drainPerDay = nil
            daysLeft = nil
        }
    }
}

public protocol DeviceBatteryStore: Sendable {
    /// Keeps a reading when a level moved or an hour has passed since the device's last one.
    func recordDevices(_ devices: [PeripheralBattery], at date: Date) async throws
    /// Every device seen in the last `days` days, by name.
    func deviceHistory(days: Int) async throws -> [DeviceBatteryHistory]
}

// MARK: - Battery use by app (D-100)

/// What the battery was spent on between two dates, like iOS's Battery screen.
public struct BatteryUse: Hashable, Sendable {
    /// Each app's share of the Energy Impact while on battery, 0...1, highest first.
    public let apps: [AppTotal]
    /// Time on battery.
    public let onBatterySeconds: Double
    /// Percentage points the battery fell while on battery.
    public let drainedPercent: Double

    public init(apps: [AppTotal], onBatterySeconds: Double, drainedPercent: Double) {
        self.apps = apps
        self.onBatterySeconds = onBatterySeconds
        self.drainedPercent = drainedPercent
    }
}

public protocol BatteryUseStore: Sendable {
    func batteryUse(from: Date, to: Date, limit: Int) async throws -> BatteryUse
    /// When the Mac went on battery this time, from the minutes recorded in the last day: the
    /// first minute on battery after the last one plugged in. Nil when the last minute recorded
    /// was plugged in, or nothing was recorded.
    func unpluggedAt(now: Date) async throws -> Date?
}

/// Settings → History → Export History….
public protocol HistoryExporting: Sendable {
    /// Writes every hourly row kept, system-wide and per app, to `url` as CSV. Returns the row count.
    func exportCSV(to url: URL) throws -> Int
}
