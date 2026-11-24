import CoreServices
import Foundation

/// A big file nothing has touched in a long time (1.6).
public struct ForgottenFile: Hashable, Sendable, Identifiable {
    public var id: String {
        path
    }

    public let path: String
    /// What it takes on disk.
    public let size: UInt64
    /// The latest of when it was opened, changed, or put in its folder.
    public let lastTouched: Date

    public init(path: String, size: UInt64, lastTouched: Date) {
        self.path = path
        self.size = size
        self.lastTouched = lastTouched
    }
}

/// Big files you forgot (1.6): files of 100 MB or more in the home folder that haven't been
/// opened, changed or moved into their folder for a year. Spotlight finds the big files in a
/// moment (walking the home folder takes minutes); each is then checked on disk.
///
/// Never listed, so a Trash can't break something: anything in `~/Library` (apps' own data),
/// in a hidden folder, inside a package (a Photos or Music library, an app, a virtual machine)
/// or inside a code project or build folder, where one file is part of a whole; anything in
/// iCloud, Desktop and Documents included when they sync; and anything that isn't a plain file.
public enum ForgottenFiles {
    public static let minimumSize: UInt64 = 100_000_000
    public static let unusedFor: TimeInterval = 365 * 86400

    /// Pure: the latest of the dates there are. Nil when there are none.
    public static func lastTouched(opened: Date?, modified: Date?, added: Date?) -> Date? {
        [opened, modified, added].compactMap(\.self).max()
    }

    /// Pure: untouched for `unusedFor`.
    public static func isForgotten(lastTouched: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastTouched) >= unusedFor
    }

    /// Pure: a path that may be listed: under `home`, not in `~/Library`, and with no hidden
    /// folder on the way. Packages are checked on disk, by `insidePackage`.
    public static func isListable(_ path: String, home: String) -> Bool {
        let home = (home as NSString).standardizingPath
        guard path.hasPrefix(home + "/"), !path.split(separator: "/").contains("..") else {
            return false
        }
        let inside = path.dropFirst(home.count + 1).split(separator: "/")
        guard let first = inside.first, first != "Library" else {
            return false
        }
        return !inside.contains { $0.hasPrefix(".") }
    }

    /// Folders whose contents a build or a package manager makes: never anyone's own files.
    static let buildFolders: Set<String> = [
        "node_modules", "build", "DerivedData", "target", "Pods", "vendor", "venv", "dist", "out", "Carthage",
    ]

    /// Pure: a build folder on the way from `home` to the file.
    public static func inBuildFolder(_ path: String, home: String) -> Bool {
        path.dropFirst(home.count).split(separator: "/").dropLast().contains { buildFolders.contains(String($0)) }
    }

    /// Whether the file is part of a code project: a folder between `home` and it holds `.git`.
    /// A file in a project belongs to it, even a big or duplicated one.
    static func insideProject(_ path: String, home: String) -> Bool {
        var folder = (path as NSString).deletingLastPathComponent
        while folder.count > home.count, folder.hasPrefix(home) {
            if FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) {
                return true
            }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return false
    }

    /// The checks on disk: not in a package, a project, or a build folder.
    static func isOwnFile(_ path: String, home: String) -> Bool {
        !inBuildFolder(path, home: home) && !insidePackage(path, home: home) && !insideProject(path, home: home)
    }

    /// Whether a folder between `home` and the file is a package (a library, an app, a bundle).
    static func insidePackage(_ path: String, home: String) -> Bool {
        var folder = (path as NSString).deletingLastPathComponent
        while folder.count > home.count, folder.hasPrefix(home) {
            let values = try? URL(fileURLWithPath: folder, isDirectory: true).resourceValues(forKeys: [.isPackageKey])
            if values?.isPackage == true {
                return true
            }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return false
    }

    /// The forgotten files in `home`, largest first. Empty when Spotlight has nothing (it's off,
    /// or still indexing).
    public static func scan(home: String = NSHomeDirectory(), now: Date = Date()) -> [ForgottenFile] {
        let home = (home as NSString).standardizingPath
        return spotlightCandidates(home: home).compactMap { candidate in
            check(candidate, home: home, now: now)
        }
        .sorted { $0.size > $1.size }
    }

    struct Candidate {
        let path: String
        let opened: Date?
        let added: Date?
    }

    /// Spotlight's big files under `home`, with when each was last opened and added.
    static func spotlightCandidates(home: String) -> [Candidate] {
        let text = "kMDItemFSSize >= \(minimumSize)" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, text, nil, nil) else {
            return []
        }
        MDQuerySetSearchScope(query, [home as CFString] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            return []
        }
        defer { MDQueryStop(query) }
        var found: [Candidate] = []
        for index in 0 ..< MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else {
                continue
            }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else {
                continue
            }
            found.append(Candidate(
                path: path,
                opened: MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date,
                added: MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
            ))
        }
        return found
    }

    /// The candidate as a forgotten file, if it is one, read fresh from disk.
    static func check(_ candidate: Candidate, home: String, now: Date) -> ForgottenFile? {
        guard isListable(candidate.path, home: home) else {
            return nil
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isUbiquitousItemKey]
        guard let values = try? URL(fileURLWithPath: candidate.path).resourceValues(forKeys: keys),
              values.isRegularFile == true,
              // iCloud's, as Desktop and Documents are when they sync: a Trash would delete it everywhere.
              values.isUbiquitousItem != true,
              // A file iCloud keeps only in the cloud takes almost nothing here.
              let size = values.totalFileAllocatedSize.map(UInt64.init), size >= minimumSize,
              let touched = lastTouched(opened: candidate.opened, modified: values.contentModificationDate, added: candidate.added),
              isForgotten(lastTouched: touched, now: now),
              isOwnFile(candidate.path, home: home)
        else {
            return nil
        }
        return ForgottenFile(path: candidate.path, size: size, lastTouched: touched)
    }
}
