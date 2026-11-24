import AppKit
import Core
import Foundation

/// Which crash reports Checkup, Your week and the crash alert count (D-108, D-115): crashes of an
/// app or extension, of the version still installed. Crashes of an older version were fixed by
/// the update, or at least came before it. History → Crashes still lists every report.
@MainActor
public enum CrashFilter {
    public static func relevant(_ reports: [CrashReport]) -> [CrashReport] {
        var installed: [String: String?] = [:]
        return reports.filter { report in
            guard report.isAppCrash else {
                return false
            }
            guard let bundleID = report.bundleID else {
                return true
            }
            let version: String?
            if let cached = installed[bundleID] {
                version = cached
            } else {
                version = installedVersion(of: bundleID)
                // `updateValue`, not a subscript: assigning nil would remove the key.
                installed.updateValue(version, forKey: bundleID)
            }
            return report.isCurrent(installedVersion: version)
        }
    }

    /// The installed copy's version, read from its Info.plist each time: `Bundle` caches its
    /// dictionary for the life of the process, so it would miss an update.
    static func installedVersion(of bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        else {
            return nil
        }
        return info["CFBundleShortVersionString"] as? String
    }
}
