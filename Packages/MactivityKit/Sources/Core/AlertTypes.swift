import Foundation

// Inputs, settings, and state for the alert engine (spec 5.4, 6.8). The engine itself lives in
// Alerts; these types are in Core so History can persist state and UI can edit settings.

/// One rule's on/off switch, threshold, and window.
///
/// `threshold` units depend on the rule: percent (0...100) for `.highCPU` and
/// `.accessoryBatteryLow`, bytes for `.growingMemory`, bytes per second for `.heavyDisk` and
/// `.heavyNetwork`, days for `.diskFilling`, a count for `.appCrashing`, bytes in 10 minutes for
/// `.hotspotData`, bytes free for `.diskLow`, minutes for `.overheating`, seconds offline for
/// `.connectionLost`, minutes at a full core for `.runawayProcess`, times its usual for `.outOfTheOrdinary`,
/// hours for `.agentLongSession`, bytes for `.agentMemory`;
/// `.notSleeping` has none.
public struct RuleSettings: Hashable, Sendable, Codable {
    public var isEnabled: Bool
    public var threshold: Double
    public var window: Duration

    public init(isEnabled: Bool, threshold: Double, window: Duration) {
        self.isEnabled = isEnabled
        self.threshold = threshold
        self.window = window
    }
}

/// Quiet hours as minutes since local midnight. `start > end` wraps midnight (22:00–07:00).
public struct QuietHours: Hashable, Sendable, Codable {
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// True when `date` falls inside quiet hours in `calendar`'s time zone. Start is inclusive,
    /// end exclusive. Equal start and end means no quiet hours.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute == endMinute {
            return false
        }
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }
}

public struct AlertSettings: Hashable, Sendable, Codable {
    public var rules: [AlertRule: RuleSettings]
    /// Minimum time between two alerts for the same app and rule.
    public var cooldown: Duration
    public var mutedAppIDs: Set<AppIdentity.ID>
    public var quietHours: QuietHours?
    /// Don't alert about the frontmost app (spec 5.4, e.g. Xcode compiling).
    public var exemptsFrontmostApp: Bool

    public init(
        rules: [AlertRule: RuleSettings],
        cooldown: Duration,
        mutedAppIDs: Set<AppIdentity.ID>,
        quietHours: QuietHours?,
        exemptsFrontmostApp: Bool
    ) {
        self.rules = rules
        self.cooldown = cooldown
        self.mutedAppIDs = mutedAppIDs
        self.quietHours = quietHours
        self.exemptsFrontmostApp = exemptsFrontmostApp
    }

    /// The spec 5.4 defaults: all four rules on, 60-minute cooldown, frontmost exemption on.
    public static let defaults = AlertSettings(
        rules: [
            .highCPU: RuleSettings(isEnabled: true, threshold: 70, window: .seconds(10 * 60)),
            .growingMemory: RuleSettings(isEnabled: true, threshold: 1_073_741_824, window: .seconds(60 * 60)),
            .heavyDisk: RuleSettings(isEnabled: true, threshold: 50_000_000, window: .seconds(5 * 60)),
            .heavyNetwork: RuleSettings(isEnabled: true, threshold: 10_000_000, window: .seconds(5 * 60)),
            .accessoryBatteryLow: RuleSettings(isEnabled: true, threshold: 15, window: .zero),
            .diskFilling: RuleSettings(isEnabled: true, threshold: 14, window: .zero),
            .appCrashing: RuleSettings(isEnabled: true, threshold: 3, window: .seconds(24 * 3600)),
            .notSleeping: RuleSettings(isEnabled: true, threshold: 0, window: .zero),
            .hotspotData: RuleSettings(isEnabled: true, threshold: 200_000_000, window: .seconds(10 * 60)),
            .diskLow: RuleSettings(isEnabled: true, threshold: 10_000_000_000, window: .zero),
            .overheating: RuleSettings(isEnabled: true, threshold: 5, window: .seconds(10 * 60)),
            .connectionLost: RuleSettings(isEnabled: false, threshold: 60, window: .zero),
            .runawayProcess: RuleSettings(isEnabled: true, threshold: 10, window: .zero),
            .outOfTheOrdinary: RuleSettings(isEnabled: true, threshold: 4, window: .zero),
            // Long sessions are normal for some: off until set. Memory past 8 GB rarely is (D-227).
            .agentLongSession: RuleSettings(isEnabled: false, threshold: 4, window: .zero),
            .agentMemory: RuleSettings(isEnabled: true, threshold: 8_589_934_592, window: .zero),
            .newStartupItem: RuleSettings(isEnabled: true, threshold: 0, window: .zero),
            // Percent of the budget; alerts only once a budget is set (D-235).
            .dataBudget: RuleSettings(isEnabled: true, threshold: 80, window: .zero),
            .vulnerableSoftware: RuleSettings(isEnabled: true, threshold: 0, window: .zero),
        ],
        cooldown: .seconds(60 * 60),
        mutedAppIDs: [],
        quietHours: nil,
        exemptsFrontmostApp: true
    )

    public func settings(for rule: AlertRule) -> RuleSettings {
        rules[rule] ?? Self.defaults.rules[rule] ?? RuleSettings(isEnabled: false, threshold: 0, window: .zero)
    }
}

extension AlertRule {
    public var title: String {
        switch self {
        case .highCPU: String(localized: "High CPU", bundle: .strings, comment: "Alert rule name.")
        case .growingMemory: String(localized: "Growing memory", bundle: .strings, comment: "Alert rule name.")
        case .heavyDisk: String(localized: "Heavy disk", bundle: .strings, comment: "Alert rule name: an app writing a lot to disk.")
        case .heavyNetwork: String(localized: "Heavy network", bundle: .strings, comment: "Alert rule name: an app using a lot of network.")
        case .accessoryBatteryLow: String(localized: "Accessory battery low", bundle: .strings, comment: "Alert rule name: AirPods, mouse…")
        case .diskFilling: String(localized: "Disk filling up", bundle: .strings, comment: "Alert rule name")
        case .appCrashing: String(localized: "App keeps crashing", bundle: .strings, comment: "Alert rule name")
        case .notSleeping: String(localized: "Mac awake all night", bundle: .strings, comment: "Alert rule name")
        case .hotspotData: String(
                localized: "Data on your hotspot", bundle: .strings,
                comment: "Alert rule name: an app using a lot of an iPhone hotspot's data"
            )
        case .diskLow: String(localized: "Disk space low", bundle: .strings, comment: "Alert rule name")
        case .overheating: String(localized: "Mac running hot", bundle: .strings, comment: "Alert rule name")
        case .connectionLost: String(
                localized: "Connection lost",
                bundle: .strings,
                comment: "Alert rule name: the internet connection dropped"
            )
        case .runawayProcess: String(
                localized: "Runaway dev process",
                bundle: .strings,
                comment: "Alert rule name: a node or python process stuck at full speed or leaking memory"
            )
        case .outOfTheOrdinary: String(
                localized: "Out of the ordinary",
                bundle: .strings,
                comment: "Alert rule name: an app doing far more than it usually does on this Mac"
            )
        case .agentLongSession: String(
                localized: "Long agent session",
                bundle: .strings,
                comment: "Alert rule name: a coding agent (Claude Code, Codex) running longer than set"
            )
        case .agentMemory: String(
                localized: "Agent memory",
                bundle: .strings,
                comment: "Alert rule name: a coding agent's processes holding more memory than set"
            )
        case .newStartupItem: String(
                localized: "New startup item",
                bundle: .strings,
                comment: "Alert rule name: something added itself to start with the Mac"
            )
        case .dataBudget: String(
                localized: "Data budget",
                bundle: .strings,
                comment: "Alert rule name: the month's data close to the budget set"
            )
        case .vulnerableSoftware: String(
                localized: "Software needing security updates",
                bundle: .strings,
                comment: "Alert rule name: an installed package with known vulnerabilities, or no longer supported"
            )
        }
    }

    /// The main-window tab an alert for this rule deep-links to.
    public var metric: Metric {
        switch self {
        case .highCPU: .cpu
        case .growingMemory: .memory
        case .heavyDisk: .diskWrite
        case .heavyNetwork, .hotspotData: .netIn
        case .accessoryBatteryLow, .notSleeping: .batteryLevel
        case .diskFilling, .diskLow: .diskFree
        case .overheating: .thermalPressure
        case .connectionLost: .netIn
        case .appCrashing, .runawayProcess, .outOfTheOrdinary, .agentLongSession: .cpu
        case .agentMemory: .memory
        case .newStartupItem: .cpu
        case .dataBudget: .netIn
        case .vulnerableSoftware: .cpu
        }
    }
}

/// One app's figures at one moment, as the alert engine sees them.
public struct AppActivityPoint: Hashable, Sendable, Codable {
    public let at: Date
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let diskWriteBPS: Double
    public let netInBPS: Double?
    public let netOutBPS: Double?

    public init(at: Date, cpuPercent: Double, memoryBytes: UInt64, diskWriteBPS: Double, netInBPS: Double?, netOutBPS: Double?) {
        self.at = at
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskWriteBPS = diskWriteBPS
        self.netInBPS = netInBPS
        self.netOutBPS = netOutBPS
    }
}

/// Recent activity for one app, oldest point first.
public struct AppActivityHistory: Hashable, Sendable {
    public let app: AppIdentity
    public let points: [AppActivityPoint]

    public init(app: AppIdentity, points: [AppActivityPoint]) {
        self.app = app
        self.points = points
    }
}

public struct AlertContext: Sendable {
    public let now: Date
    public let frontmostAppID: AppIdentity.ID?
    public let calendar: Calendar
    /// Each app's usual daily peak memory on this Mac, in bytes (D-218): growing memory doesn't
    /// alert while an app is still below what it reaches on an ordinary day.
    public let usualPeakMemory: [AppIdentity.ID: Double]

    public init(
        now: Date, frontmostAppID: AppIdentity.ID?, calendar: Calendar = .current, usualPeakMemory: [AppIdentity.ID: Double] = [:]
    ) {
        self.now = now
        self.frontmostAppID = frontmostAppID
        self.calendar = calendar
        self.usualPeakMemory = usualPeakMemory
    }
}

/// An app's usual daily peak memory (D-218): the median of its highest reading each day, once it
/// has 5 days. Pure.
public enum MemoryPeaks {
    public static let minimumDays = 5

    /// `points`: the app's memory series, any order; each point's maximum is its peak.
    public static func usual(_ points: [SeriesPoint], calendar: Calendar = .current) -> Double? {
        var peaks: [Date: Double] = [:]
        for point in points {
            let day = calendar.startOfDay(for: point.at)
            peaks[day] = max(peaks[day] ?? 0, point.maximum)
        }
        guard peaks.count >= minimumDays else {
            return nil
        }
        return Baselines.median(Array(peaks.values))
    }
}

public struct AlertKey: Hashable, Sendable, Codable {
    public let appID: AppIdentity.ID
    public let rule: AlertRule

    public init(appID: AppIdentity.ID, rule: AlertRule) {
        self.appID = appID
        self.rule = rule
    }
}

/// What the engine remembers between evaluations. Persisted so cooldowns survive relaunch.
public struct AlertState: Hashable, Sendable, Codable {
    public var lastFired: [AlertKey: Date]
    /// The figure an alert last fired at, for rules that shouldn't repeat until it moves on:
    /// growing memory's footprint in bytes (D-111).
    public var levelAtLastAlert: [AlertKey: Double]

    public init(lastFired: [AlertKey: Date] = [:], levelAtLastAlert: [AlertKey: Double] = [:]) {
        self.lastFired = lastFired
        self.levelAtLastAlert = levelAtLastAlert
    }

    private enum CodingKeys: String, CodingKey {
        case lastFired, levelAtLastAlert
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastFired = try container.decode([AlertKey: Date].self, forKey: .lastFired)
        levelAtLastAlert = try container.decodeIfPresent([AlertKey: Double].self, forKey: .levelAtLastAlert) ?? [:]
    }
}

public protocol AlertStateStore: Sendable {
    func loadAlertState() async throws -> AlertState
    func saveAlertState(_ state: AlertState) async throws
    /// The most recent alerts, newest first, for the Alerts tab.
    func recentAlerts(limit: Int) async throws -> [Alert]
    func recordAlert(_ alert: Alert) async throws
}
