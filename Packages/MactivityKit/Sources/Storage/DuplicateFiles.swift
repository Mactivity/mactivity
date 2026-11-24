import CoreServices
import CryptoKit
import Darwin
import Foundation

/// A file with at least one exact copy elsewhere (1.6), and the copy kept.
public struct DuplicateFile: Hashable, Sendable, Identifiable {
    public var id: String {
        path
    }

    public let path: String
    /// The copy that stays: the one this duplicates.
    public let original: String
    /// What moving it to the Trash gives back: only the blocks it doesn't share with a clone.
    public let reclaimable: UInt64
    public let modified: Date

    public init(path: String, original: String, reclaimable: UInt64, modified: Date) {
        self.path = path
        self.original = original
        self.reclaimable = reclaimable
        self.modified = modified
    }
}

/// Duplicate files (1.6): exact copies among the files of 1 MB or more in the home folder's own
/// folders, the same ones Big Files You Forgot may list (never Library, a hidden folder, a
/// package, a code project, a build folder or iCloud Drive). Spotlight finds the files; same-size files are compared by a sample
/// of their content, then by a full SHA-256, so only true copies count.
///
/// APFS can clone a file: the copy shares the original's blocks and takes no extra room. What a
/// duplicate frees is its private size, and copies that free nothing aren't listed.
public enum DuplicateFiles {
    public static let minimumSize: UInt64 = 1_000_000

    public struct Candidate: Hashable, Sendable {
        public let path: String
        public let size: UInt64
        public let created: Date
        public let modified: Date
        /// The file on disk (device and inode): two paths to one file are hard links, not copies.
        public let file: FileIdentity?

        public init(path: String, size: UInt64, created: Date, modified: Date, file: FileIdentity? = nil) {
            self.path = path
            self.size = size
            self.created = created
            self.modified = modified
            self.file = file
        }
    }

    public struct FileIdentity: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    /// A plain file's identity, without following a symbolic link; nil for anything else.
    static func identity(_ path: String) -> (file: FileIdentity, size: UInt64)? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return (FileIdentity(device: info.st_dev, inode: info.st_ino), UInt64(max(0, info.st_size)))
    }

    /// Pure: one path per file on disk, so a hard link is never offered as a copy of itself.
    static func distinctFiles(_ candidates: [Candidate]) -> [Candidate] {
        var seen: Set<FileIdentity> = []
        return candidates.filter { candidate in
            guard let file = candidate.file else {
                return true
            }
            return seen.insert(file).inserted
        }
    }

    /// Checked again right before the Trash (D-251): `path` is still a copy of `original`, so
    /// the copy that stays is still there. Both plain files, separate on disk, the same size and
    /// the same sampled content.
    public static func stillCopy(_ path: String, of original: String) -> Bool {
        guard path != original, let copy = identity(path), let kept = identity(original),
              copy.file != kept.file, copy.size == kept.size, let sampled = sample(path)
        else {
            return false
        }
        return sampled == sample(original)
    }

    /// Pure: which copy to keep. Not one in Downloads if there's another; then the oldest; then
    /// the shortest path, so the choice doesn't change from scan to scan.
    public static func keeper(of copies: [Candidate], home: String) -> Candidate? {
        let downloads = (home as NSString).appendingPathComponent("Downloads") + "/"
        return copies.min { lhs, rhs in
            let lhsDownloads = lhs.path.hasPrefix(downloads)
            let rhsDownloads = rhs.path.hasPrefix(downloads)
            if lhsDownloads != rhsDownloads {
                return !lhsDownloads
            }
            if lhs.created != rhs.created {
                return lhs.created < rhs.created
            }
            return lhs.path.count != rhs.path.count ? lhs.path.count < rhs.path.count : lhs.path < rhs.path
        }
    }

    /// Pure: the sizes worth comparing: two files or more of the same size.
    public static func sameSize(_ candidates: [Candidate]) -> [[Candidate]] {
        Dictionary(grouping: candidates, by: \.size).values.filter { $0.count > 1 }.map { $0 }
    }

    /// Every extra copy, the largest saving first. `progress` gets the files compared so far
    /// and how many there are.
    public static func scan(
        home: String = NSHomeDirectory(),
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) -> [DuplicateFile] {
        let home = (home as NSString).standardizingPath
        let groups = sameSize(distinctFiles(candidates(home: home)))
        let total = groups.reduce(0) { $0 + $1.count }
        var done = 0
        var found: [DuplicateFile] = []
        for group in groups {
            // A quick sample first, then the whole file, only among the ones that still match.
            for sampled in Dictionary(grouping: group, by: { sample($0.path) }).values where sampled.count > 1 {
                for copies in Dictionary(grouping: sampled, by: { fullHash($0.path) }).values where copies.count > 1 {
                    found += extras(copies, home: home)
                }
            }
            done += group.count
            progress(done, total)
        }
        return found.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// The copies other than the one kept, each with what it frees. Ones that free nothing (an
    /// APFS clone, a hard link) are left out.
    static func extras(_ copies: [Candidate], home: String) -> [DuplicateFile] {
        guard let keep = keeper(of: copies, home: home) else {
            return []
        }
        return copies.filter { $0 != keep }.compactMap { copy in
            let freed = privateSize(copy.path) ?? copy.size
            return freed > 0 ? DuplicateFile(path: copy.path, original: keep.path, reclaimable: freed, modified: copy.modified) : nil
        }
    }

    /// Files of `minimumSize` or more that Big Files You Forgot would also allow, from Spotlight.
    static func candidates(home: String) -> [Candidate] {
        let text = "kMDItemFSSize >= \(minimumSize)" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, text, nil, nil) else {
            return []
        }
        MDQuerySetSearchScope(query, [home as CFString] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            return []
        }
        defer { MDQueryStop(query) }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .isUbiquitousItemKey,
        ]
        var found: [Candidate] = []
        for index in 0 ..< MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else {
                continue
            }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  ForgottenFiles.isListable(path, home: home),
                  let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isUbiquitousItem != true,
                  let size = values.fileSize, UInt64(size) >= minimumSize,
                  ForgottenFiles.isOwnFile(path, home: home)
            else {
                continue
            }
            found.append(Candidate(
                path: path, size: UInt64(size),
                created: values.creationDate ?? .distantPast, modified: values.contentModificationDate ?? .distantPast,
                file: identity(path)?.file
            ))
        }
        return found
    }

    /// SHA-256 of the first, middle and last 64 KB: cheap, and different files almost always differ.
    static func sample(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }
        let chunk = 64 * 1024
        guard let end = try? handle.seekToEnd() else {
            return nil
        }
        var hasher = SHA256()
        for offset in [0, end / 2, end > UInt64(chunk) ? end - UInt64(chunk) : 0] {
            try? handle.seek(toOffset: offset)
            if let data = try? handle.read(upToCount: chunk) {
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the whole file, read a megabyte at a time.
    static func fullHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes only this file holds: an APFS clone's shared blocks don't count.
    /// `ATTR_CMNEXT_PRIVATESIZE` through `getattrlist`; nil where the volume can't say.
    static func privateSize(_ path: String) -> UInt64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // FSOPT_ATTR_CMN_EXTENDED: forkattr holds the extended common attributes.
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
        // The reply: a UInt32 length, then the off_t, packed at 4-byte alignment.
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = buffer.count
        let status = buffer.withUnsafeMutableBytes { getattrlist(path, &request, $0.baseAddress, count, options) }
        guard status == 0 else {
            return nil
        }
        let size = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: off_t.self) }
        return UInt64(max(0, size))
    }
}
