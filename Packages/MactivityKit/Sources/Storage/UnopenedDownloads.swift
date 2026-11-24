import CoreServices
import Foundation

/// A file that arrived in Downloads and was never opened (1.8).
public struct UnopenedDownload: Hashable, Sendable, Identifiable {
    public var id: String {
        path
    }

    public let path: String
    public let size: UInt64
    /// When it arrived in Downloads.
    public let added: Date

    public init(path: String, size: UInt64, added: Date) {
        self.path = path
        self.size = size
        self.added = added
    }
}

/// Downloads you never opened (1.8, D-260): files at the top of Downloads that macOS has no
/// record of anyone opening since they arrived. Spotlight keeps that record (`kMDItemLastUsedDate`,
/// set when a file is opened in Finder or an app); a file it hasn't indexed has no record either
/// way and isn't listed. Left to their own cleanups: installers, archives and unfinished
/// downloads (`DownloadsLeftovers`), and apps, which someone may run from there.
public enum UnopenedDownloads {
    /// Newer than this, and you may still get to it.
    public static let minimumAge: TimeInterval = 7 * 86400
    /// Ticked when it's been waiting this long.
    public static let tickedAge: TimeInterval = 90 * 86400

    /// Pure: whether a file is listed, from what Spotlight says. `indexed` is false when Spotlight
    /// has no record of the file: then "never opened" can't be told from "not known".
    public static func isUnopened(name: String, indexed: Bool, lastUsed: Date?, added: Date, now: Date) -> Bool {
        guard indexed, lastUsed == nil, now.timeIntervalSince(added) >= minimumAge else {
            return false
        }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext != "app" && DownloadsLeftovers.kind(name: name) == nil
    }

    /// Pure: whether a row starts ticked.
    public static func startsTicked(_ item: UnopenedDownload, now: Date) -> Bool {
        now.timeIntervalSince(item.added) >= tickedAge
    }

    /// The unopened files at the top of `folder`, largest first. A missing folder is an empty list.
    public static func scan(
        _ folder: URL = DownloadsLeftovers.folder(),
        now: Date = Date()
    ) throws(ProtectedFolderError) -> [UnopenedDownload] {
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .addedToDirectoryDateKey, .isUbiquitousItemKey]
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw .noAccess
        }
        return entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isUbiquitousItem != true,
                  let size = values.totalFileAllocatedSize
            else {
                return nil
            }
            let spotlight = record(url.path)
            guard let added = spotlight.added ?? values.addedToDirectoryDate,
                  isUnopened(name: url.lastPathComponent, indexed: spotlight.indexed, lastUsed: spotlight.lastUsed, added: added, now: now)
            else {
                return nil
            }
            return UnopenedDownload(path: url.path, size: UInt64(size), added: added)
        }
        .sorted { ($0.size, $1.path) > ($1.size, $0.path) }
    }

    /// What Spotlight knows of one file: whether it's indexed (it has a content type), when it was
    /// last opened, and when it was added.
    static func record(_ path: String) -> (indexed: Bool, lastUsed: Date?, added: Date?) {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else {
            return (false, nil, nil)
        }
        return (
            MDItemCopyAttribute(item, kMDItemContentType) != nil,
            MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date,
            MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
        )
    }
}
