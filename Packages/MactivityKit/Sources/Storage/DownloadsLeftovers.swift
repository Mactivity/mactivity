import Foundation

/// Installers and archives left in Downloads (D-118): disk images, installer packages and
/// archives kept after installing, and downloads that never finished. Only the folder's top
/// level, and never an app: someone may run one from there. Nothing here moves anything: the UI
/// shows them, asks, and moves the ticked ones through `StorageTrashing`.
public struct DownloadLeftover: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case diskImage, installer, archive, unfinished
    }

    public var id: String {
        path
    }

    public let path: String
    public let kind: Kind
    public let size: UInt64
    /// When it arrived in Downloads.
    public let added: Date

    public var name: String {
        (path as NSString).lastPathComponent
    }

    public init(path: String, kind: Kind, size: UInt64, added: Date) {
        self.path = path
        self.kind = kind
        self.size = size
        self.added = added
    }
}

public enum DownloadsLeftovers {
    public static func folder(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Pure: what kind of leftover a name is, or nil for anything else (documents, photos, apps).
    public static func kind(name: String) -> DownloadLeftover.Kind? {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "dmg", "iso", "sparseimage", "ipsw": return .diskImage
        case "pkg", "mpkg": return .installer
        case "zip", "xip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": return .archive
        case "download", "crdownload", "part", "partial": return .unfinished
        default: return nil
        }
    }

    /// Pure: whether a leftover starts ticked. Added over 30 days ago, or an unfinished download
    /// over a day old (one still running is newer than that).
    public static func startsTicked(_ item: DownloadLeftover, now: Date) -> Bool {
        let age = now.timeIntervalSince(item.added)
        return item.kind == .unfinished ? age > 86400 : age > 30 * 86400
    }

    /// The leftovers at the top of `folder`, largest first. A missing folder is an empty list.
    public static func scan(_ folder: URL = folder()) throws(ProtectedFolderError) -> [DownloadLeftover] {
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return []
        }
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey]
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
        var found: [DownloadLeftover] = []
        for url in entries {
            guard let kind = kind(name: url.lastPathComponent) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Safari's .download is a folder holding the partial file.
            let size = values?.isDirectory == true
                ? DeviceBackups.size(of: url)
                : UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            let added = values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast
            found.append(DownloadLeftover(path: url.path, kind: kind, size: size, added: added))
        }
        return found.sorted { ($0.size, $1.path) > ($1.size, $0.path) }
    }
}
