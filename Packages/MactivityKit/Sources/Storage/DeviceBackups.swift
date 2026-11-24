import Foundation

/// iPhone and iPad backups on this Mac, and the software updates Finder downloaded for them
/// (D-117). Backups live in ~/Library/Application Support/MobileSync/Backup, one folder per
/// device, the same list as Finder's Manage Backups; updates are .ipsw files in ~/Library/iTunes.
/// Nothing here moves anything: the UI shows them, asks, and moves the ticked ones through
/// `StorageTrashing`.
public struct DeviceBackup: Hashable, Sendable, Identifiable {
    public var id: String {
        path
    }

    public let path: String
    public let deviceName: String
    /// "iPhone 15 Pro", when the backup says.
    public let productName: String?
    /// "18.1", the system the device ran.
    public let systemVersion: String?
    public let date: Date?
    public let size: UInt64
    public let isEncrypted: Bool

    public init(
        path: String, deviceName: String, productName: String?, systemVersion: String?, date: Date?, size: UInt64, isEncrypted: Bool
    ) {
        self.path = path
        self.deviceName = deviceName
        self.productName = productName
        self.systemVersion = systemVersion
        self.date = date
        self.size = size
        self.isEncrypted = isEncrypted
    }
}

/// A downloaded iPhone or iPad software update. Finder downloads it again when it's needed.
public struct DeviceUpdateFile: Hashable, Sendable, Identifiable {
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

public struct DeviceBackupsScan: Hashable, Sendable {
    /// Newest first.
    public let backups: [DeviceBackup]
    /// Largest first.
    public let updates: [DeviceUpdateFile]

    public init(backups: [DeviceBackup], updates: [DeviceUpdateFile]) {
        self.backups = backups
        self.updates = updates
    }
}

public enum ProtectedFolderError: Error, Sendable, Equatable {
    /// macOS privacy protection: the folder needs Full Disk Access.
    case noAccess
}

public enum DeviceBackups {
    public static func backupsFolder(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
    }

    static func updateFolders(home: String) -> [URL] {
        let iTunes = URL(fileURLWithPath: home).appendingPathComponent("Library/iTunes", isDirectory: true)
        return ["iPhone Software Updates", "iPad Software Updates", "iPod Software Updates"].map {
            iTunes.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Every backup with its size, and every downloaded update. No backups folder is an empty
    /// list; a folder macOS won't let Mactivity list is `noAccess`.
    public static func scan(home: String = NSHomeDirectory()) throws(ProtectedFolderError) -> DeviceBackupsScan {
        let folder = backupsFolder(home: home)
        var backups: [DeviceBackup] = []
        if FileManager.default.fileExists(atPath: folder.path) {
            let entries: [String]
            do {
                entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            } catch {
                throw .noAccess
            }
            for entry in entries where !entry.hasPrefix(".") {
                let url = folder.appendingPathComponent(entry, isDirectory: true)
                let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")) as? [String: Any]
                let manifest = NSDictionary(contentsOf: url.appendingPathComponent("Manifest.plist")) as? [String: Any]
                guard info != nil || manifest != nil else {
                    continue
                }
                backups.append(backup(path: url.path, info: info ?? [:], manifest: manifest, size: size(of: url)))
            }
        }
        var updates: [DeviceUpdateFile] = []
        for folder in updateFolders(home: home) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )) ?? []
            for file in files where file.pathExtension.lowercased() == "ipsw" {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                updates.append(DeviceUpdateFile(
                    path: file.path, size: UInt64(values?.fileSize ?? 0), date: values?.contentModificationDate ?? .distantPast
                ))
            }
        }
        return DeviceBackupsScan(
            backups: backups.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) },
            updates: updates.sorted { $0.size > $1.size }
        )
    }

    /// Pure: a backup from its Info.plist and Manifest.plist. The folder's name (the device's
    /// identifier) stands in for a name the backup doesn't give.
    static func backup(path: String, info: [String: Any], manifest: [String: Any]?, size: UInt64) -> DeviceBackup {
        let lockdown = manifest?["Lockdown"] as? [String: Any]
        let name = (info["Display Name"] as? String) ?? (info["Device Name"] as? String)
            ?? (lockdown?["DeviceName"] as? String) ?? (path as NSString).lastPathComponent
        return DeviceBackup(
            path: path,
            deviceName: name,
            productName: info["Product Name"] as? String,
            systemVersion: (info["Product Version"] as? String) ?? (lockdown?["ProductVersion"] as? String),
            date: (info["Last Backup Date"] as? Date) ?? (manifest?["Date"] as? Date),
            size: size,
            isEncrypted: (manifest?["IsEncrypted"] as? Bool) ?? false
        )
    }

    /// Allocated size of everything under a folder.
    static func size(of folder: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: UInt64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}
