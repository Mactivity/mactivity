import AppKit
import Foundation

/// Bundle icons straight from `NSWorkspace`, uncached; `IconCache` caches them per path.
@MainActor
enum AppIconLookup {
    /// Resolves symlinks first: /Applications/Safari.app is a link into a cryptex, and the link's
    /// own icon carries an alias badge. A missing bundle gets the generic app icon; `.application`
    /// would give a blank document.
    static func icon(forPath path: String) -> NSImage {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: resolved) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        // A bundle with no icon of its own (Claude Code's claude.app, which the Claude app
        // downloads into its support folder) takes the icon of the app that owns that folder.
        if !hasOwnIcon(resolved), let owner = owningApp(of: resolved) {
            return NSWorkspace.shared.icon(forFile: owner)
        }
        return NSWorkspace.shared.icon(forFile: resolved)
    }

    /// Whether a bundle names an icon (a file or an asset-catalog icon) in its Info.plist.
    static func hasOwnIcon(_ bundlePath: String) -> Bool {
        guard bundlePath.hasSuffix(".app"), let info = Bundle(path: bundlePath)?.infoDictionary else {
            return true
        }
        return info["CFBundleIconFile"] != nil || info["CFBundleIconName"] != nil
    }

    /// Pure apart from the existence check: …/Library/Application Support/<Name>/… belongs to
    /// <Name>.app in /Applications or ~/Applications, when there is one.
    static func owningApp(of path: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        let parts = path.components(separatedBy: "/Library/Application Support/")
        guard parts.count >= 2, let folder = parts[1].split(separator: "/").first, !folder.isEmpty else {
            return nil
        }
        let home = parts[0]
        return ["/Applications/\(folder).app", "\(home)/Applications/\(folder).app"].first(where: exists)
    }

    static var executable: NSImage {
        NSWorkspace.shared.icon(for: .unixExecutable)
    }
}
