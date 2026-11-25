import Foundation

/// A cloud service's folder on this Mac (1.6): iCloud Drive, or one in `~/Library/CloudStorage`
/// (Dropbox, Google Drive, OneDrive, Box…), one per account.
public struct CloudFolder: Hashable, Sendable, Identifiable {
    public var id: String {
        path
    }

    public let name: String
    public let path: String
    /// iCloud Drive's own folder holds every app's iCloud data too.
    public let isICloud: Bool

    public init(name: String, path: String, isICloud: Bool) {
        self.name = name
        self.path = path
        self.isICloud = isICloud
    }
}

/// What a cloud folder keeps on this Mac: every downloaded byte, and the downloads of 1 MB or
/// more that could be removed, leaving the files in the cloud.
public struct CloudFolderUsage: Hashable, Sendable, Identifiable {
    public var id: String {
        folder.id
    }

    public let folder: CloudFolder
    public let localBytes: UInt64
    public let downloads: [ICloudDownload]

    public init(folder: CloudFolder, localBytes: UInt64, downloads: [ICloudDownload]) {
        self.folder = folder
        self.localBytes = localBytes
        self.downloads = downloads
    }
}

/// Cloud folders, sized (1.6). A file only in the cloud takes nothing here (macOS keeps a
/// placeholder), so a folder's local size is what its files actually take.
public enum CloudFolders {
    public static func cloudStorage(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    /// Pure: a name for a `~/Library/CloudStorage` folder. "GoogleDrive-robin@example.com" is
    /// "Google Drive (robin@example.com)"; "OneDrive-Personal" is "OneDrive (Personal)".
    public static func displayName(_ entry: String) -> String {
        let parts = entry.split(separator: "-", maxSplits: 1).map(String.init)
        let provider = switch parts.first ?? entry {
        case "GoogleDrive": "Google Drive"
        case "OneDrive": "OneDrive"
        case "Dropbox": "Dropbox"
        case "Box": "Box"
        case let other: other
        }
        guard parts.count > 1, parts[1] != provider else {
            return provider
        }
        return "\(provider) (\(parts[1]))"
    }

    /// The cloud folders this Mac has: iCloud Drive first, then the others by name.
    public static func folders(home: String = NSHomeDirectory(), iCloudDrive: String = "iCloud Drive") -> [CloudFolder] {
        var found: [CloudFolder] = []
        let iCloud = ICloudDownloads.folder(home: home)
        if FileManager.default.fileExists(atPath: iCloud.path) {
            found.append(CloudFolder(name: iCloudDrive, path: iCloud.path, isICloud: true))
        }
        let storage = cloudStorage(home: home)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
        found += entries.filter { !$0.hasPrefix(".") }.sorted().map { entry in
            CloudFolder(name: displayName(entry), path: storage.appendingPathComponent(entry).path, isICloud: false)
        }
        return found
    }

    /// The folder's local size and its removable downloads, largest first.
    public static func usage(
        of folder: CloudFolder, home: String = NSHomeDirectory(), iCloudDrive: String = "iCloud Drive"
    ) throws(ProtectedFolderError) -> CloudFolderUsage {
        let root = URL(fileURLWithPath: folder.path, isDirectory: true)
        let downloads = if folder.isICloud {
            try ICloudDownloads.scan(home: home, iCloudDrive: iCloudDrive)
        } else {
            try ICloudDownloads.scan(root: root, place: folder.name)
        }
        return try CloudFolderUsage(folder: folder, localBytes: localSize(root), downloads: downloads)
    }

    /// What the files in `root` take on this Mac, packages included.
    static func localSize(_ root: URL) throws(ProtectedFolderError) -> UInt64 {
        guard FileManager.default.isReadableFile(atPath: root.path) else {
            throw .noAccess
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: UInt64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

extension ICloudDownloads {
    /// Downloaded, uploaded files of 1 MB or more in one cloud folder, largest first; the same
    /// rules as iCloud Drive's (not inside packages, not still uploading).
    public static func scan(root: URL, place: String) throws(ProtectedFolderError) -> [ICloudDownload] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        guard FileManager.default.isReadableFile(atPath: root.path) else {
            throw .noAccess
        }
        let cheap: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let cloud: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey, .totalFileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: cheap, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var found: [ICloudDownload] = []
        for case let file as URL in files {
            guard let basics = try? file.resourceValues(forKeys: Set(cheap)), basics.isRegularFile == true,
                  let length = basics.fileSize, length >= 1_000_000,
                  let values = try? file.resourceValues(forKeys: cloud),
                  values.ubiquitousItemDownloadingStatus == .current, values.ubiquitousItemIsUploaded == true
            else {
                continue
            }
            let size = UInt64(values.totalFileAllocatedSize ?? length)
            if size >= 1_000_000 {
                found.append(ICloudDownload(path: file.path, place: place, size: size))
            }
        }
        return found.sorted { ($0.size, $1.path) > ($1.size, $0.path) }
    }

    /// Remove Download in any cloud folder: iCloud's, or one in `~/Library/CloudStorage`. The
    /// file stays in the cloud.
    public static func removeCloudDownload(_ path: String, home: String = NSHomeDirectory()) throws {
        let scope = CleanupScope(roots: [folder(home: home), CloudFolders.cloudStorage(home: home)], depth: .anywhere)
        guard scope.allows(path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        // Checked again right before (D-251): a file changed since the scan may not be in the
        // cloud yet, and Dropbox, Google Drive and OneDrive each decide what eviction does to it.
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey])
        guard values.ubiquitousItemIsUploaded == true, values.ubiquitousItemIsUploading != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}
