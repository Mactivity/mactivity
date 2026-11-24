import Core
import Foundation

/// What `mactivity top` and the Top Apps shortcut sort by. Disk and network combine both
/// directions, so one flag answers "who is hitting the disk".
public enum AppRanking: String, CaseIterable, Hashable, Sendable, Codable {
    case cpu, memory, energy, disk, network

    public var title: String {
        switch self {
        case .cpu: String(localized: "CPU", bundle: .strings, comment: "What apps are ranked by.")
        case .memory: String(localized: "Memory", bundle: .strings, comment: "What apps are ranked by.")
        case .energy: String(localized: "Energy", bundle: .strings, comment: "What apps are ranked by.")
        case .disk: String(localized: "Disk", bundle: .strings, comment: "What apps are ranked by.")
        case .network: String(localized: "Network", bundle: .strings, comment: "What apps are ranked by.")
        }
    }

    /// The figure this ranking sorts by, or nil when the app has none (per-app network is
    /// unavailable on current macOS, spec 6.5 / D-024).
    public func value(of app: AppAggregate) -> Double? {
        switch self {
        case .cpu: app.cpuPercent
        case .memory: Double(app.memoryBytes)
        case .energy: app.energyMW
        case .disk: app.diskReadBPS + app.diskWriteBPS
        case .network:
            switch (app.netInBPS, app.netOutBPS) {
            case (nil, nil): nil
            case let (received, sent): (received ?? 0) + (sent ?? 0)
            }
        }
    }

    /// The figure formatted the way the app shows it. "–" when there is none.
    public func formatted(_ app: AppAggregate, locale: Locale = .current) -> String {
        guard let value = value(of: app) else {
            return "–"
        }
        switch self {
        case .cpu: return Formatters.percent(value, locale: locale)
        case .memory: return Formatters.memory(value, locale: locale)
        case .energy: return Formatters.power(milliwatts: value, locale: locale)
        case .disk, .network: return Formatters.rate(value, locale: locale)
        }
    }

    /// Highest first (`AppAggregate.ranked`). Apps without a figure sort last; ties break by
    /// name, then id, so output is stable.
    public func rank(_ apps: [AppAggregate], limit: Int, includingSystem: Bool = true) -> [AppAggregate] {
        let candidates = includingSystem ? apps : apps.filter { $0.app.kind != .system }
        return Array(AppAggregate.ranked(candidates, by: value(of:)).prefix(max(0, limit)))
    }
}
