import Foundation

/// App launch times (D-215): from an app's process starting to macOS saying it finished launching.
public struct AppLaunch: Hashable, Sendable {
    public let at: Date
    public let appID: AppIdentity.ID
    public let name: String
    public let seconds: Double

    public init(at: Date, appID: AppIdentity.ID, name: String, seconds: Double) {
        self.at = at
        self.appID = appID
        self.name = name
        self.seconds = seconds
    }

    /// Kept: not in the first minutes after the Mac started, when everything opens at once and
    /// every app waits; not a launch held up for minutes (a dialog, a debugger).
    public static func isWorthKeeping(seconds: Double, uptime: TimeInterval) -> Bool {
        uptime >= 300 && seconds > 0 && seconds <= 120
    }
}

public protocol AppLaunchStore: Sendable {
    func recordLaunch(_ launch: AppLaunch) async throws
    /// Launches in the span, oldest first.
    func launches(from: Date, to: Date) async throws -> [AppLaunch]
}

/// Each app's usual launch, and whether it got slower (D-215). Pure.
public struct AppLaunchTimes: Hashable, Sendable, Identifiable {
    public let appID: AppIdentity.ID
    public let name: String
    public let count: Int
    /// The median launch in the last 14 days, and in the three weeks before; nil without 3 each.
    public let recent: Double?
    public let earlier: Double?

    public var id: AppIdentity.ID {
        appID
    }

    /// Half again as long or more, and a second or more longer.
    public var isSlower: Bool {
        guard let recent, let earlier else {
            return false
        }
        return recent >= earlier * 1.5 && recent - earlier >= 1
    }

    public static func byApp(_ launches: [AppLaunch], now: Date) -> [AppLaunchTimes] {
        let recentStart = now.addingTimeInterval(-14 * 86400)
        let earlierStart = now.addingTimeInterval(-35 * 86400)
        return Dictionary(grouping: launches, by: \.appID).compactMap { id, launches -> AppLaunchTimes? in
            let recent = launches.filter { $0.at >= recentStart }.map(\.seconds)
            let earlier = launches.filter { $0.at >= earlierStart && $0.at < recentStart }.map(\.seconds)
            guard let latest = launches.max(by: { $0.at < $1.at }) else {
                return nil
            }
            return AppLaunchTimes(
                appID: id, name: latest.name, count: launches.count,
                recent: recent.count >= 3 ? Baselines.median(recent) : nil,
                earlier: earlier.count >= 3 ? Baselines.median(earlier) : nil
            )
        }
        // Slowest to open first.
        .sorted { ($0.recent ?? 0) > ($1.recent ?? 0) }
    }
}

extension Checkup {
    /// Apps taking noticeably longer to open than they used to (D-215).
    static func slowerLaunches(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard let first = inputs.slowerLaunches.first, let recent = first.recent, let earlier = first.earlier else {
            return []
        }
        let names = inputs.slowerLaunches.prefix(3).map(\.name).formatted(.list(type: .and))
        let now = Formatters.seconds(recent)
        let was = Formatters.seconds(earlier)
        return [CheckupItem(
            id: "slowerLaunches", area: .launches, severity: .suggestion,
            title: String(localized: "Slower to open lately: \(names)", bundle: .strings),
            detail: String(
                localized: "\(first.name) takes \(now) to open, against \(was) before. A recent update or a crowded login can do that.",
                bundle: .strings
            )
        )]
    }
}
