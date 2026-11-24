import Core
import Foundation
import Readouts
import WidgetKit

struct SystemEntry: TimelineEntry {
    enum State: Equatable {
        case figures(WidgetSnapshot)
        /// No team (ad-hoc build): there's no app group, so the widget can never get figures.
        case needsSignedBuild
        /// No file yet, or the last one is older than `WidgetSnapshot.staleAfter`.
        case openApp
    }

    let date: Date
    let state: State

    var hasFigures: Bool {
        if case .figures = state {
            return true
        }
        return false
    }
}

/// Reads the app's latest figures. The app asks WidgetKit to reload when they change
/// meaningfully (at most every 15 minutes), so the timeline never polls: one entry now, and one
/// that switches to "Open Mactivity" when those figures go stale.
struct SystemWidgetProvider: TimelineProvider {
    func placeholder(in _: Context) -> SystemEntry {
        SystemEntry(date: Date(), state: .figures(.sample))
    }

    func getSnapshot(in context: Context, completion: @escaping (SystemEntry) -> Void) {
        let now = Date()
        let entry = Self.entry(now: now)
        // The widget gallery shows real figures when there are some, else the sample.
        let showsSample = context.isPreview && !entry.hasFigures
        completion(showsSample ? SystemEntry(date: now, state: .figures(.sample)) : entry)
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<SystemEntry>) -> Void) {
        let now = Date()
        let entry = Self.entry(now: now)
        var entries = [entry]
        if case let .figures(snapshot) = entry.state {
            entries.append(SystemEntry(date: snapshot.updatedAt.addingTimeInterval(WidgetSnapshot.staleAfter), state: .openApp))
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    static func entry(now: Date) -> SystemEntry {
        guard let url = SharedFile.url else {
            return SystemEntry(date: now, state: .needsSignedBuild)
        }
        guard let snapshot = WidgetSnapshot.load(from: url), !snapshot.isStale(now: now) else {
            return SystemEntry(date: now, state: .openApp)
        }
        return SystemEntry(date: now, state: .figures(snapshot))
    }
}

/// The app group file, found the same way the app finds it.
enum SharedFile {
    /// Baked into the extension's Info.plist from `DEVELOPMENT_TEAM`; empty in ad-hoc builds.
    static var teamID: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "MactivityTeamID") as? String ?? ""
        return value.isEmpty ? nil : value
    }

    static var url: URL? {
        WidgetFeed.fileURL(teamID: teamID) { group in
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        }
    }
}

extension WidgetSnapshot {
    /// The widget gallery's preview and the redacted placeholder.
    static let sample = WidgetSnapshot(
        updatedAt: Date(),
        cpuPercent: 23,
        cpuHistory: [18, 22, 19, 25, 31, 28, 22, 20, 24, 35, 42, 30, 26, 22, 21, 24, 27, 23],
        memoryUsedBytes: 19_327_352_832,
        memoryTotalBytes: 51_539_607_552,
        memoryPressure: .normal,
        battery: Battery(percent: 87, isCharging: true, onAC: true),
        topApps: [
            TopApp(name: "Xcode", bundleID: "com.apple.dt.Xcode", cpuPercent: 12.6, memoryBytes: 6_657_199_308),
            TopApp(name: "Safari", bundleID: "com.apple.Safari", cpuPercent: 3.2, memoryBytes: 3_328_599_654),
            TopApp(name: "Mail", bundleID: "com.apple.mail", cpuPercent: 0.8, memoryBytes: 412_000_000),
        ]
    )
}
