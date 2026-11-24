import Foundation

// The parts of purgeable space Mactivity can show (D-125). macOS frees purgeable space on its
// own when it needs room; these are the parts a person can see and act on sooner.

/// A file iCloud keeps a copy of on this Mac, already uploaded. Removing the download, as
/// Finder's Remove Download does, leaves it in iCloud and on every other device.
public struct ICloudDownload: Hashable, Sendable, Identifiable {
    public var id: String {
        path
    }

    public let path: String
    /// "iCloud Drive", or the app whose iCloud folder it's in ("WhatsApp").
    public let place: String
    public let size: UInt64

    public var name: String {
        (path as NSString).lastPathComponent
    }

    public init(path: String, place: String, size: UInt64) {
        self.path = path
        self.place = place
        self.size = size
    }
}

public enum ICloudDownloads {
    public static func folder(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Mobile Documents", isDirectory: true)
    }

    /// Pure: whose iCloud folder a container is. "com~apple~CloudDocs" is iCloud Drive itself;
    /// "57T9237FN3~net~whatsapp~WhatsApp" is WhatsApp's.
    public static func place(container: String, iCloudDrive: String) -> String {
        guard container != "com~apple~CloudDocs" else {
            return iCloudDrive
        }
        return container.split(separator: "~").last.map(String.init) ?? container
    }

    /// The folders someone sees in Finder's iCloud Drive: iCloud Drive itself, and each app's
    /// Documents. An app's other iCloud data (a chat database, settings) is the app's to manage,
    /// and removing its download could upset the app.
    static func visibleFolder(container: String, root: URL) -> URL {
        let url = root.appendingPathComponent(container, isDirectory: true)
        return container == "com~apple~CloudDocs" ? url : url.appendingPathComponent("Documents", isDirectory: true)
    }

    /// Downloaded, uploaded files in the folders Finder shows, largest first, from 1 MB. Files
    /// still uploading, or only in iCloud, aren't listed: removing those would lose something or
    /// free nothing. Not inside packages: a book or a playground is the app's bundle of thousands
    /// of small files (19,000 on one Mac, 14 s to ask iCloud about each), and removing part of
    /// one would break it. iCloud is asked only about files of 1 MB or more.
    public static func scan(
        home: String = NSHomeDirectory(),
        iCloudDrive: String = "iCloud Drive"
    ) throws(ProtectedFolderError) -> [ICloudDownload] {
        let root = folder(home: home)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        let containers: [String]
        do {
            containers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            throw .noAccess
        }
        let cheap: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let iCloud: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey, .totalFileAllocatedSizeKey]
        var found: [ICloudDownload] = []
        for container in containers where !container.hasPrefix(".") {
            let place = place(container: container, iCloudDrive: iCloudDrive)
            let url = visibleFolder(container: container, root: root)
            guard FileManager.default.fileExists(atPath: url.path), let files = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: cheap,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let file as URL in files {
                guard let basics = try? file.resourceValues(forKeys: Set(cheap)), basics.isRegularFile == true,
                      let length = basics.fileSize, length >= 1_000_000,
                      let values = try? file.resourceValues(forKeys: iCloud),
                      values.ubiquitousItemDownloadingStatus == .current, values.ubiquitousItemIsUploaded == true
                else {
                    continue
                }
                let size = UInt64(values.totalFileAllocatedSize ?? length)
                if size >= 1_000_000 {
                    found.append(ICloudDownload(path: file.path, place: place, size: size))
                }
            }
        }
        return found.sorted { ($0.size, $1.path) > ($1.size, $0.path) }
    }

    /// Finder's Remove Download: the file stays in iCloud. Only inside iCloud's folder.
    public static func removeDownload(_ path: String, home: String = NSHomeDirectory()) throws {
        guard CleanupScope(roots: [folder(home: home)], depth: .anywhere).allows(path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: path))
    }
}

/// Local Time Machine snapshots on the startup disk: macOS keeps them about a day, and deletes
/// them sooner when it needs the space. Listed, never deleted: that would be a permanent delete.
public enum LocalSnapshots {
    /// Pure: dates from `tmutil listlocalsnapshots /`, one "com.apple.TimeMachine.2026-09-28-101010.local" per line.
    public static func dates(fromListing listing: String) -> [Date] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return listing.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else {
                return nil
            }
            return formatter.date(from: String(line[range]))
        }
        .sorted()
    }

    /// The snapshots now, oldest first; empty when there are none or tmutil can't say.
    public static func current() -> [Date] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return dates(fromListing: String(bytes: data, encoding: .utf8) ?? "")
    }
}
