import Core
import Foundation

/// What Software Update has found (D-120): its own record in
/// /Library/Preferences/com.apple.SoftwareUpdate.plist, readable by everyone. Nothing is checked
/// or downloaded here, and nothing goes over the network; Software Update does that on its own
/// schedule.
public struct LiveSoftwareUpdates: SoftwareUpdateSource {
    let path: String
    let historyPath: String

    public init(
        path: String = "/Library/Preferences/com.apple.SoftwareUpdate.plist",
        historyPath: String = "/Library/Receipts/InstallHistory.plist"
    ) {
        self.path = path
        self.historyPath = historyPath
    }

    public func pending() async -> [PendingUpdate] {
        guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return []
        }
        return Self.parse(plist)
    }

    /// Pure: `RecommendedUpdates`, each with a "Display Name" and "Display Version".
    static func parse(_ plist: [String: Any]) -> [PendingUpdate] {
        let updates = plist["RecommendedUpdates"] as? [[String: Any]] ?? []
        return updates.compactMap { update in
            guard let name = (update["Display Name"] as? String) ?? (update["Identifier"] as? String), !name.isEmpty else {
                return nil
            }
            return PendingUpdate(name: name, version: update["Display Version"] as? String)
        }
    }
}

// MARK: - Installed updates (D-206)

extension LiveSoftwareUpdates {
    /// macOS updates from the installer's own log, /Library/Receipts/InstallHistory.plist
    /// (readable by everyone). For apps, the version in each bundle's Info.plist and when that file
    /// arrived: its status-change time, which an installer, Sparkle or the App Store sets when it
    /// puts the new bundle in place, and which unlike the modification time isn't copied from the
    /// build. Only an app's latest version is known this way. Nothing is written or sent anywhere.
    public func installed(apps: [AppIdentity], since: Date) async -> [InstalledUpdate] {
        var found: [InstalledUpdate] = []
        if let history = NSArray(contentsOfFile: historyPath) as? [[String: Any]] {
            found += Self.macOSUpdates(history, since: since)
        }
        for app in apps {
            if let update = Self.appUpdate(app, since: since) {
                found.append(update)
            }
        }
        return found.sorted { $0.installedAt > $1.installedAt }
    }

    /// Pure: the log's macOS entries ("macOS 27.0.1", by softwareupdated) since `since`.
    static func macOSUpdates(_ history: [[String: Any]], since: Date) -> [InstalledUpdate] {
        history.compactMap { entry in
            guard let name = entry["displayName"] as? String, name.hasPrefix("macOS "),
                  let date = entry["date"] as? Date, date >= since else {
                return nil
            }
            let version = (entry["displayVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(name.dropFirst("macOS ".count))
            return InstalledUpdate(app: nil, name: "macOS", version: version, installedAt: date)
        }
    }

    /// The app's current version, when it arrived after `since`. Apps only: their icon key is the
    /// bundle's path. Not the apps in /System, which arrive with macOS, all at once, and are
    /// macOS's update rather than their own.
    static func appUpdate(_ app: AppIdentity, since: Date) -> InstalledUpdate? {
        guard app.kind == .app, app.iconKey.hasSuffix(".app"), !app.iconKey.hasPrefix("/System/") else {
            return nil
        }
        let plist = URL(fileURLWithPath: app.iconKey).appendingPathComponent("Contents/Info.plist")
        guard let arrived = (try? plist.resourceValues(forKeys: [.attributeModificationDateKey]))?.attributeModificationDate,
              arrived >= since,
              let info = NSDictionary(contentsOf: plist),
              let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) else {
            return nil
        }
        return InstalledUpdate(app: app, name: app.name, version: version, installedAt: arrived)
    }
}
