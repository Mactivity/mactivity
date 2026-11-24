import Foundation
import os

/// One scan's folder sizes, kept so the next scan can say what grew (D-208): folders of
/// `minimumSize` or more, down to `maxDepth` levels under the root.
public struct FolderSizes: Codable, Sendable, Equatable {
    public let root: String
    public let scannedAt: Date
    public let sizes: [String: UInt64]

    public init(root: String, scannedAt: Date, sizes: [String: UInt64]) {
        self.root = root
        self.scannedAt = scannedAt
        self.sizes = sizes
    }
}

/// A folder that grew since the last scan of the same place.
public struct FolderGrowth: Hashable, Sendable, Identifiable {
    public let path: String
    /// Its size then; nil when it was too small to keep, or didn't exist.
    public let before: UInt64?
    public let after: UInt64
    /// What this folder's growth adds beyond the folders listed inside it.
    public let grew: UInt64

    public init(path: String, before: UInt64?, after: UInt64, grew: UInt64) {
        self.path = path
        self.before = before
        self.after = after
        self.grew = grew
    }

    public var id: String {
        path
    }

    public var name: String {
        (path as NSString).lastPathComponent
    }
}

/// What grew between two scans (D-208). Pure, apart from the file the sizes are kept in.
public enum FolderGrowthLog {
    static let minimumSize: UInt64 = 200_000_000
    static let maxDepth = 6
    /// Growth under half a gigabyte isn't worth naming.
    public static let minimumGrowth: UInt64 = 500_000_000

    /// The folders worth remembering from `scan`.
    public static func sizes(_ scan: StorageScan) -> FolderSizes {
        let root = scan.root.path
        let rootDepth = depth(root)
        var sizes: [String: UInt64] = [:]
        scan.root.visit { node in
            guard node.kind == .directory, node.size >= minimumSize, depth(node.path) - rootDepth <= maxDepth else {
                return false
            }
            sizes[node.path] = node.size
            return true
        }
        return FolderSizes(root: root, scannedAt: scan.startedAt, sizes: sizes)
    }

    /// The folders that grew from `old` to `new`, biggest first. Each names the deepest folder
    /// that explains it: when DerivedData grew 9 GB, that's DerivedData, not Developer, Library
    /// and the home folder; a parent is listed only for growth its listed folders don't account for.
    public static func growth(from old: FolderSizes, to new: FolderSizes, limit: Int = 5) -> [FolderGrowth] {
        guard old.root == new.root else {
            return []
        }
        var remaining: [String: Int64] = [:]
        for (path, size) in new.sizes {
            remaining[path] = Int64(size) - Int64(old.sizes[path] ?? 0)
        }
        var picked: [FolderGrowth] = []
        for path in remaining.keys.sorted(by: { depth($0) > depth($1) || (depth($0) == depth($1) && $0 < $1) }) {
            guard let grew = remaining[path], grew >= Int64(minimumGrowth), let size = new.sizes[path] else {
                continue
            }
            picked.append(FolderGrowth(path: path, before: old.sizes[path], after: size, grew: UInt64(grew)))
            var ancestor = (path as NSString).deletingLastPathComponent
            while ancestor.count >= new.root.count, ancestor != path {
                remaining[ancestor]? -= grew
                let next = (ancestor as NSString).deletingLastPathComponent
                if next == ancestor {
                    break
                }
                ancestor = next
            }
        }
        return Array(picked.sorted { $0.grew > $1.grew }.prefix(limit))
    }

    static func depth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    // MARK: The file

    private static let log = Logger(subsystem: "app.mactivity.storage", category: "growth")

    /// Application Support/Mactivity/storage-sizes.json: each scanned place's latest sizes. On
    /// this Mac only, like the history beside it.
    public static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Mactivity", isDirectory: true)
            .appendingPathComponent("storage-sizes.json")
    }

    /// The sizes kept for `root`, then `new` kept in their place. Nil the first time a place is scanned.
    public static func exchange(_ new: FolderSizes, at url: URL) -> FolderSizes? {
        var all = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: FolderSizes].self, from: $0) } ?? [:]
        let previous = all[new.root]
        all[new.root] = new
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: url, options: .atomic)
        } catch {
            log.error("Couldn't keep folder sizes: \(error.localizedDescription, privacy: .public)")
        }
        return previous
    }
}
