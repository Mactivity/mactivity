import Foundation

/// An attachment Mail saved to open it (D-119). Mail keeps the message and downloads the
/// attachment again from the mail server when it's opened next.
public struct MailDownload: Hashable, Sendable, Identifiable {
    public var id: String {
        path
    }

    public let path: String
    public let size: UInt64
    public let date: Date

    public var name: String {
        (path as NSString).lastPathComponent
    }

    public init(path: String, size: UInt64, date: Date) {
        self.path = path
        self.size = size
        self.date = date
    }
}

public enum MailDownloads {
    public static func folder(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(
            "Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
            isDirectory: true
        )
    }

    /// Every file Mail saved, largest first. No folder (Mail never saved one) is an empty list.
    public static func scan(_ folder: URL = folder()) throws(ProtectedFolderError) -> [MailDownload] {
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return []
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw .noAccess
        }
        // When the file arrived, not when it was last edited: a copy keeps its source's
        // modification date, so a video edited two years ago and sent yesterday read as two
        // years old (D-140).
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileSizeKey, .addedToDirectoryDateKey,
            .creationDateKey, .contentModificationDateKey,
        ]
        // A package attachment (.pages, .rtfd) is one item: moving files from inside it would
        // leave a broken document behind (D-140).
        guard let files = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw .noAccess
        }
        var found: [MailDownload] = []
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true || values.isPackage == true else {
                continue
            }
            let size = values.isPackage == true
                ? DeviceBackups.size(of: url) : UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            found.append(MailDownload(
                path: url.path, size: size,
                date: values.addedToDirectoryDate ?? values.creationDate ?? values.contentModificationDate ?? .distantPast
            ))
        }
        return found.sorted { ($0.size, $1.path) > ($1.size, $0.path) }
    }
}

/// The home folder's Trash (D-119). Mactivity only reads its size and opens it in Finder; the
/// person empties it (permanent deletes are never Mactivity's to make).
public enum TrashFolder {
    public static func folder(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".Trash", isDirectory: true)
    }

    /// Everything in the Trash, or nil when macOS won't let Mactivity look (Full Disk Access).
    public static func size(_ folder: URL = folder()) -> UInt64? {
        guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil else {
            return nil
        }
        return DeviceBackups.size(of: folder)
    }
}
