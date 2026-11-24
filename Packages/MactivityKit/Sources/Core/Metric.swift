import Foundation

/// A figure that can be sorted, charted, and stored. Most are per app; sensors, thermal pressure,
/// and the D-095 figures are system-wide only, kept here so History stores them the same way.
public enum Metric: String, CaseIterable, Hashable, Sendable, Codable {
    case cpu, memory, energy, diskRead, diskWrite, netIn, netOut, gpu
    /// Activity Monitor's Energy Impact, from macOS's own coefficients (expansion E13).
    case energyImpact
    case cpuTemperature, gpuTemperature, fanSpeed
    /// `ThermalPressure` rank: 0 nominal … 3 critical (expansion E8).
    case thermalPressure
    /// The Mac's own battery, percent charged (D-095).
    case batteryLevel
    /// Memory pressure, percent: 100 minus `kern.memorystatus_level` (D-095).
    case memoryPressure
    /// Swap in use, bytes (D-095).
    case swapUsed
    /// Free space on the startup volume, bytes (D-095).
    case diskFree
    /// 1 on battery, 0 on power; a bucket's average is the share of it on battery (D-100).
    case onBattery
    /// What the whole Mac draws, display included, in milliwatts like `energy`: from the adapter
    /// or the battery (D-258). Nil on a Mac whose battery doesn't report it, and on a desktop.
    case powerDraw
    /// The Mac's own battery in °C while it charges (D-275). Nil at every other moment, so a
    /// bucket's average is only its time charging.
    case batteryTempCharging
    /// The same while it isn't charging: on battery, or plugged in at full or held short of it.
    case batteryTempInUse

    public var title: String {
        switch self {
        case .cpu: String(localized: "CPU", bundle: .strings)
        case .memory: String(localized: "Memory", bundle: .strings)
        case .energy: String(localized: "Energy", bundle: .strings)
        case .diskRead: String(localized: "Disk Read", bundle: .strings)
        case .diskWrite: String(localized: "Disk Write", bundle: .strings)
        case .netIn: String(localized: "Received", bundle: .strings, comment: "Metric: network bytes received.")
        case .netOut: String(localized: "Sent", bundle: .strings, comment: "Metric: network bytes sent.")
        case .gpu: String(localized: "GPU", bundle: .strings)
        case .energyImpact: String(localized: "Energy Impact", bundle: .strings, comment: "Activity Monitor's term for its energy score.")
        case .cpuTemperature: String(localized: "CPU temperature", bundle: .strings)
        case .gpuTemperature: String(localized: "GPU temperature", bundle: .strings)
        case .fanSpeed: String(localized: "Fan speed", bundle: .strings)
        case .thermalPressure: String(localized: "Thermal pressure", bundle: .strings)
        case .batteryLevel: String(localized: "Battery level", bundle: .strings)
        case .memoryPressure: String(localized: "Memory pressure", bundle: .strings)
        case .swapUsed: String(localized: "Swap used", bundle: .strings)
        case .diskFree: String(localized: "Free space", bundle: .strings, comment: "Metric: free space on the startup disk")
        case .onBattery: String(localized: "On battery", bundle: .strings, comment: "Metric: share of time on battery power")
        case .powerDraw: String(localized: "Power draw", bundle: .strings, comment: "Metric: the whole Mac's power, in watts")
        case .batteryTempCharging: String(
                localized: "While charging", bundle: .strings, comment: "Metric: the battery's temperature while it charges"
            )
        case .batteryTempInUse: String(
                localized: "In use", bundle: .strings, comment: "Metric: the battery's temperature while it isn't charging"
            )
        }
    }

    /// Only the system-wide rows have these.
    public var isSystemOnly: Bool {
        switch self {
        case .cpuTemperature, .gpuTemperature, .fanSpeed, .thermalPressure,
             .batteryLevel, .memoryPressure, .swapUsed, .diskFree, .onBattery, .powerDraw, .batteryTempCharging, .batteryTempInUse: true
        default: false
        }
    }
}

/// A history range for the History strip (spec 4.3). Named `HistoryRange`, not the spec's
/// `Range`, so it doesn't shadow `Swift.Range` (D-007).
public enum HistoryRange: String, CaseIterable, Hashable, Sendable, Codable, Identifiable {
    case h12, h24, d7, d30, d90, y1

    public var id: String {
        rawValue
    }

    public var duration: Duration {
        switch self {
        case .h12: .seconds(12 * 3600)
        case .h24: .seconds(24 * 3600)
        case .d7: .seconds(7 * 24 * 3600)
        case .d30: .seconds(30 * 24 * 3600)
        case .d90: .seconds(90 * 24 * 3600)
        case .y1: .seconds(365 * 24 * 3600)
        }
    }

    /// Segmented-control label, e.g. "12 h".
    public var label: String {
        switch self {
        case .h12: String(localized: "12 h", bundle: .strings, comment: "History range: 12 hours (h = hours).")
        case .h24: String(localized: "24 h", bundle: .strings, comment: "History range: 24 hours (h = hours).")
        case .d7: String(localized: "7 d", bundle: .strings, comment: "History range: 7 days (d = days).")
        case .d30: String(localized: "30 d", bundle: .strings, comment: "History range: 30 days (d = days).")
        case .d90: String(localized: "90 d", bundle: .strings, comment: "History range: 90 days (d = days).")
        case .y1: String(localized: "1 y", bundle: .strings, comment: "History range: 1 year (y = year).")
        }
    }
}

/// How long history is kept (Settings → History, D-089). Minutes are kept 48 hours and
/// quarter-hours 30 days whatever this is; hourly rows are kept this many days.
public enum HistoryRetention {
    public static let defaultDays = 365
    public static let choices = [7, 14, 30, 90, 365]
}

/// The status word on a headline card (spec 4.3, 7.3).
public enum MetricStatus: String, Hashable, Sendable, Codable, Comparable {
    case normal, elevated, critical

    /// Looked up once: the menu bar shows it every tick.
    public var title: String {
        switch self {
        case .normal: Self.normalTitle
        case .elevated: Self.elevatedTitle
        case .critical: Self.criticalTitle
        }
    }

    private static let normalTitle = String(localized: "Normal", bundle: .strings, comment: "Status of a metric, e.g. memory pressure.")
    private static let elevatedTitle = String(localized: "Elevated", bundle: .strings, comment: "Status of a metric, e.g. memory pressure.")
    private static let criticalTitle = String(localized: "Critical", bundle: .strings, comment: "Status of a metric, e.g. memory pressure.")

    /// CPU thresholds (D-008): elevated at 50%, critical at 85%, the same
    /// line the strain state uses (`StrainDetector.cpuThreshold`).
    public init(cpuPercent: Double) {
        switch cpuPercent {
        case StrainDetector.cpuThreshold...: self = .critical
        case 50...: self = .elevated
        default: self = .normal
        }
    }

    /// Startup disk free space: critical under 5%, the line the strain state uses
    /// (`StrainDetector.diskFreeThreshold`), elevated under twice that.
    public init(diskFreeFraction free: Double) {
        switch free {
        case ..<StrainDetector.diskFreeThreshold: self = .critical
        case ..<(StrainDetector.diskFreeThreshold * 2): self = .elevated
        default: self = .normal
        }
    }

    public init(memoryPressure: MemoryPressure) {
        switch memoryPressure {
        case .normal: self = .normal
        case .warning: self = .elevated
        case .critical: self = .critical
        }
    }

    private var rank: Int {
        switch self {
        case .normal: 0
        case .elevated: 1
        case .critical: 2
        }
    }

    public static func < (lhs: MetricStatus, rhs: MetricStatus) -> Bool {
        lhs.rank < rhs.rank
    }
}
