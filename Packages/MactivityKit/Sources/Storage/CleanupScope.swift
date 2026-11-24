import Foundation

/// Where a cleanup may move things from (D-123). Each cleanup checks every path against its scope
/// right before the Trash, so a wrong path, from any bug upstream, is refused instead of moved.
public struct CleanupScope: Sendable, Hashable {
    public enum Depth: Sendable, Hashable {
        /// Only a root's direct contents: the top of Downloads, one backup folder per device.
        case topLevel
        /// Anything inside a root, at any depth: Messages' and Mail's attachment folders.
        case anywhere
        /// A root itself or anything inside it: DerivedData, a package manager's cache.
        case rootOrInside
    }

    public let roots: [String]
    public let depth: Depth
    /// Other places, each with its own depth, for a cleanup that moves from more than one kind
    /// of folder (D-282).
    public var alternatives: [CleanupScope] = []

    public init(roots: [URL], depth: Depth) {
        self.roots = roots.map { Self.clean($0.path) }
        self.depth = depth
    }

    /// Pure: whether `path` is inside the scope. Tidied first ("//", "/./"), and refused outright
    /// if it climbs with "..": a path that needs that is never one a scan produced.
    public func allows(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            return false
        }
        let tidy = Self.clean(path)
        let inside = roots.contains { root in
            switch depth {
            case .topLevel:
                (tidy as NSString).deletingLastPathComponent == root
            case .anywhere:
                tidy.hasPrefix(root + "/")
            case .rootOrInside:
                tidy == root || tidy.hasPrefix(root + "/")
            }
        }
        return inside || alternatives.contains { $0.allows(path) }
    }

    private static func clean(_ path: String) -> String {
        let tidy = (path as NSString).standardizingPath
        return tidy.count > 1 && tidy.hasSuffix("/") ? String(tidy.dropLast()) : tidy
    }

    // MARK: Each cleanup's

    public static func messages(home: String = NSHomeDirectory()) -> CleanupScope {
        CleanupScope(roots: [MessagesAttachments.folder(home: home)], depth: .anywhere)
    }

    public static func mail(home: String = NSHomeDirectory()) -> CleanupScope {
        CleanupScope(roots: [MailDownloads.folder(home: home)], depth: .anywhere)
    }

    /// A backup is a folder straight inside Backup; an update, a file straight inside its folder.
    public static func backups(home: String = NSHomeDirectory()) -> CleanupScope {
        CleanupScope(roots: [DeviceBackups.backupsFolder(home: home)] + DeviceBackups.updateFolders(home: home), depth: .topLevel)
    }

    public static func downloads(home: String = NSHomeDirectory()) -> CleanupScope {
        CleanupScope(roots: [DownloadsLeftovers.folder(home: home)], depth: .topLevel)
    }

    public static func screenshots(
        home: String = NSHomeDirectory(),
        setting: String? = ScreenCaptures.screenshotSetting()
    ) -> CleanupScope {
        CleanupScope(roots: ScreenCaptures.folders(home: home, setting: setting), depth: .topLevel)
    }

    /// Big files you forgot (1.6): anywhere in the home folder's own folders, never in Library or
    /// a hidden folder, checked again right before the Trash like every scope.
    public static func forgotten(home: String = NSHomeDirectory()) -> CleanupScope {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        let roots = names
            .filter { $0 != "Library" && !$0.hasPrefix(".") }
            .map { URL(fileURLWithPath: home).appendingPathComponent($0) }
        return CleanupScope(roots: roots, depth: .anywhere)
    }

    /// The rebuildable locations themselves (DerivedData, the caches), not their parents.
    public static func developer(home: String = NSHomeDirectory()) -> CleanupScope {
        let roots = DeveloperLens.locations
            .filter { DeveloperLens.rebuildable.contains($0.kind) && !$0.path.hasPrefix("/") }
            .map { URL(fileURLWithPath: home).appendingPathComponent($0.path) }
        return CleanupScope(roots: roots, depth: .rootOrInside)
    }
}
