import Foundation

// Value types for the storage map (expansion E10). Sizes are allocated bytes, so sparse files,
// APFS compression, and hard links read the way the disk sees them.

// MARK: - Categories

/// What a file is, for the Categories tab. Decided by the folder it's in first (an app bundle,
/// a Library, a developer folder), then by its UTType.
public enum StorageCategory: String, CaseIterable, Sendable, Hashable, Codable, Identifiable {
    case apps
    case documents
    case photosAndVideo
    case audio
    case archives
    case developer
    case systemAndLibrary
    case other

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .apps: String(localized: "Apps", bundle: .strings, comment: "Storage category")
        case .documents: String(localized: "Documents", bundle: .strings, comment: "Storage category")
        case .photosAndVideo: String(localized: "Photos & video", bundle: .strings, comment: "Storage category")
        case .audio: String(localized: "Audio", bundle: .strings, comment: "Storage category")
        case .archives: String(localized: "Archives", bundle: .strings, comment: "Storage category")
        case .developer: String(localized: "Developer", bundle: .strings, comment: "Storage category")
        case .systemAndLibrary: String(localized: "System & library", bundle: .strings, comment: "Storage category")
        case .other: String(localized: "Other", bundle: .strings, comment: "Storage category")
        }
    }

    /// SF Symbol for rows and legends.
    public var symbol: String {
        switch self {
        case .apps: "app.badge"
        case .documents: "doc.text"
        case .photosAndVideo: "photo.on.rectangle"
        case .audio: "music.note"
        case .archives: "archivebox"
        case .developer: "hammer"
        case .systemAndLibrary: "gearshape"
        case .other: "questionmark.folder"
        }
    }
}

/// One category's share of a scan.
public struct CategoryTotal: Sendable, Hashable, Identifiable {
    public let category: StorageCategory
    public let bytes: UInt64
    public let fileCount: Int

    public var id: StorageCategory {
        category
    }

    public init(category: StorageCategory, bytes: UInt64, fileCount: Int) {
        self.category = category
        self.bytes = bytes
        self.fileCount = fileCount
    }
}

// MARK: - Tree

/// A folder, a file, or a bucket in the size tree. Immutable once the scanner returns it, so it
/// crosses actors freely. Children are sorted largest first.
public final class StorageNode: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        case directory
        case file
        /// Files below the scan's `fileNodeThreshold`, summed into one bucket per folder so a
        /// million-file scan doesn't keep a million nodes. `fileCount` says how many.
        case smallFiles
        /// A folder the scanner couldn't open (EPERM, EACCES: usually TCC). Its size is unknown,
        /// not zero; the view says so.
        case unreadable
    }

    public let name: String
    /// Absolute path. For `.smallFiles`, the folder that holds them.
    public let path: String
    public let kind: Kind
    public let size: UInt64
    /// Files at or below this node, counting a hard-linked file once.
    public let fileCount: Int
    /// Files only.
    public let category: StorageCategory?
    public let children: [StorageNode]

    public var id: String {
        kind == .smallFiles ? path + "/\u{1}small" : path
    }

    public var isDirectory: Bool {
        kind == .directory
    }

    /// Can be revealed or moved to the Trash: a real item on disk.
    public var isItem: Bool {
        kind == .directory || kind == .file
    }

    public init(
        name: String,
        path: String,
        kind: Kind,
        size: UInt64,
        fileCount: Int,
        category: StorageCategory? = nil,
        children: [StorageNode] = []
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
        self.category = category
        self.children = children
    }

    /// A folder whose size and count are its children's.
    public static func directory(name: String, path: String, children: [StorageNode]) -> StorageNode {
        let sorted = children.sorted { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
        return StorageNode(
            name: name,
            path: path,
            kind: .directory,
            size: sorted.reduce(0) { $0 + $1.size },
            fileCount: sorted.reduce(0) { $0 + $1.fileCount },
            children: sorted
        )
    }

    /// The descendant at `path`, walking down by components. nil if it's not in this tree.
    public func node(atPath target: String) -> StorageNode? {
        if target == path {
            return self
        }
        let prefix = path == "/" ? "/" : path + "/"
        guard target.hasPrefix(prefix) else {
            return nil
        }
        let rest = target.dropFirst(prefix.count)
        let first = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? String(rest)
        guard let child = children.first(where: { $0.name == first && $0.kind != .smallFiles }) else {
            return nil
        }
        return child.node(atPath: target)
    }

    /// Every node below this one, depth first. `body` returns false to skip a node's children.
    public func visit(_ body: (StorageNode) -> Bool) {
        var stack: [StorageNode] = [self]
        while let node = stack.popLast() {
            if body(node) {
                stack.append(contentsOf: node.children)
            }
        }
    }

    /// This tree without the item at `path`, with every ancestor's size and count reduced.
    /// Returns self when the path isn't in the tree.
    public func removing(path target: String) -> StorageNode {
        guard target != path else {
            return self
        }
        let prefix = path == "/" ? "/" : path + "/"
        guard target.hasPrefix(prefix), let index = children.firstIndex(where: {
            $0.kind != .smallFiles && (target == $0.path || target.hasPrefix($0.path + "/"))
        }) else {
            return self
        }
        var newChildren = children
        if children[index].path == target {
            newChildren.remove(at: index)
        } else {
            newChildren[index] = children[index].removing(path: target)
        }
        return .directory(name: name, path: path, children: newChildren)
    }

    public static func == (lhs: StorageNode, rhs: StorageNode) -> Bool {
        lhs === rhs || (lhs.id == rhs.id && lhs.size == rhs.size && lhs.kind == rhs.kind)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Scan

/// A finished scan.
public struct StorageScan: Sendable {
    public let root: StorageNode
    public let startedAt: Date
    public let duration: Duration
    public let fileCount: Int
    public let directoryCount: Int
    /// Largest first; every category appears, empty ones with zero.
    public let categories: [CategoryTotal]
    /// The 100 largest files, largest first.
    public let largestFiles: [StorageNode]
    /// Folders that couldn't be opened, as paths. The "Not readable" bucket.
    public let unreadable: [String]
    /// Mount points and firmlinks the scan didn't cross, as paths.
    public let skipped: [String]
    /// The home folder the scan used for its category rules and the Developer lens.
    public let home: String

    public init(
        root: StorageNode,
        startedAt: Date,
        duration: Duration,
        fileCount: Int,
        directoryCount: Int,
        categories: [CategoryTotal],
        largestFiles: [StorageNode],
        unreadable: [String],
        skipped: [String],
        home: String
    ) {
        self.root = root
        self.startedAt = startedAt
        self.duration = duration
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.categories = categories
        self.largestFiles = largestFiles
        self.unreadable = unreadable
        self.skipped = skipped
        self.home = home
    }

    public static let largestFileLimit = 100

    /// The top `limit` file nodes in `root`, largest first.
    public static func largestFiles(in root: StorageNode, limit: Int = largestFileLimit) -> [StorageNode] {
        var files: [StorageNode] = []
        root.visit { node in
            if node.kind == .file {
                files.append(node)
            }
            return node.kind == .directory
        }
        files.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        return Array(files.prefix(limit))
    }

    /// This scan after the item at `path` went to the Trash. Category totals are adjusted for a
    /// file; a folder's category mix isn't kept, so `categoriesAreStale` says to rescan.
    public func removing(path: String) -> StorageScan {
        guard let removed = root.node(atPath: path), removed !== root else {
            return self
        }
        var categories = categories
        if removed.kind == .file, let category = removed.category,
           let index = categories.firstIndex(where: { $0.category == category }) {
            let total = categories[index]
            categories[index] = CategoryTotal(
                category: category,
                bytes: total.bytes - min(total.bytes, removed.size),
                fileCount: max(0, total.fileCount - 1)
            )
        }
        var copy = StorageScan(
            root: root.removing(path: path),
            startedAt: startedAt,
            duration: duration,
            fileCount: fileCount - removed.fileCount,
            directoryCount: directoryCount,
            categories: categories,
            largestFiles: largestFiles.filter { $0.path != path && !$0.path.hasPrefix(path + "/") },
            unreadable: unreadable.filter { $0 != path && !$0.hasPrefix(path + "/") },
            skipped: skipped,
            home: home
        )
        copy.categoriesAreStale = categoriesAreStale || removed.kind == .directory
        return copy
    }

    /// True after a folder was trashed from this scan: the Categories tab asks for a rescan.
    public private(set) var categoriesAreStale = false
}

/// How far a running scan has got.
public struct StorageScanProgress: Sendable, Hashable {
    public let filesScanned: Int
    public let directoriesScanned: Int
    public let bytesScanned: UInt64
    /// The folder being read, for the progress line.
    public let currentPath: String
    public let elapsed: Duration

    public init(filesScanned: Int, directoriesScanned: Int, bytesScanned: UInt64, currentPath: String, elapsed: Duration) {
        self.filesScanned = filesScanned
        self.directoriesScanned = directoriesScanned
        self.bytesScanned = bytesScanned
        self.currentPath = currentPath
        self.elapsed = elapsed
    }
}

public enum StorageScanEvent: Sendable {
    case progress(StorageScanProgress)
    case finished(StorageScan)
}

public enum StorageScanError: Error, Sendable, Equatable {
    /// The root itself couldn't be opened.
    case unreadableRoot(path: String, errno: Int32)
    case cancelled
}

// MARK: - Volume

/// Capacity from the volume's resource values (spec E10). Used + purgeable + free = capacity.
public struct VolumeSummary: Sendable, Hashable {
    public let name: String
    /// Where it's mounted: "/" for the startup disk.
    public let mountPath: String
    /// "APFS", "ExFAT".
    public let format: String
    public let capacity: UInt64
    /// `volumeAvailableCapacity`: free right now, not counting purgeable space.
    public let available: UInt64
    /// `volumeAvailableCapacityForImportantUsage`: free once macOS purges caches it can recreate.
    public let availableForImportantUsage: UInt64

    public init(name: String, mountPath: String, format: String, capacity: UInt64, available: UInt64, availableForImportantUsage: UInt64) {
        self.name = name
        self.mountPath = mountPath
        self.format = format
        self.capacity = capacity
        self.available = available
        self.availableForImportantUsage = availableForImportantUsage
    }

    /// Space macOS can free on demand (caches, iCloud-evictable files): important − available.
    public var purgeable: UInt64 {
        availableForImportantUsage > available ? availableForImportantUsage - available : 0
    }

    public var free: UInt64 {
        min(available, capacity)
    }

    /// Everything that isn't free or purgeable, APFS snapshots included.
    public var used: UInt64 {
        capacity - min(capacity, free + purgeable)
    }

    /// Why snapshots aren't broken out. Reading them needs root (`tmutil`, `diskutil apfs`).
    public static let snapshotNote = String(
        localized: "Includes APFS snapshots. Measuring them needs administrator access, so Mactivity doesn't guess.",
        bundle: .strings,
        comment: "Tooltip on the used space of a disk"
    )
}

// MARK: - Permissions

public enum FullDiskAccessStatus: Sendable, Hashable {
    case granted
    /// A protected location returned EPERM: macOS will refuse or prompt per folder.
    case denied
    /// No protected location was there to try.
    case unknown
}

// MARK: - Developer lens

/// A known, rebuildable developer location and what it costs to get it back.
public struct DeveloperItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case derivedData, archives, deviceSupport, simulatorDevices, simulatorRuntimes
        case nodeModules, homebrewCache, pipCache, npmCache, yarnCache, gradleCaches, cargoRegistry, dockerDisk
    }

    public let kind: Kind
    public let title: String
    public let path: String
    public let size: UInt64
    /// What deleting it costs: "Xcode rebuilds it on the next build".
    public let note: String
    public let symbol: String

    public var id: String {
        path
    }

    public init(kind: Kind, title: String, path: String, size: UInt64, note: String, symbol: String) {
        self.kind = kind
        self.title = title
        self.path = path
        self.size = size
        self.note = note
        self.symbol = symbol
    }
}
