import Core
import Foundation
import os

/// Where the storage map's data comes from (spec E10, CLAUDE.md rule 1). The view only sees
/// this protocol; `LiveStorageScanner` reads the disk, `SimulatedStorageScanner` makes it up.
public protocol StorageScanning: Sendable {
    /// The home folder: the default scan root and the anchor for the Developer lens.
    var home: URL { get }

    /// Capacity, free, and purgeable space of the volume holding `url`.
    func volumeSummary(for url: URL) -> VolumeSummary?

    /// Whether Mactivity can read Full Disk Access–protected locations.
    func fullDiskAccess() -> FullDiskAccessStatus

    /// Scans `root`, yielding progress about ten times a second and then `.finished`. Cancelling
    /// the consuming task (or dropping the stream) stops the scan within a folder or two; the
    /// stream then ends with `StorageScanError.cancelled`.
    func scan(_ root: URL) -> AsyncThrowingStream<StorageScanEvent, any Error>

    /// Known rebuildable developer locations and every `node_modules` in `scan`.
    func developerLens(for scan: StorageScan?) async -> [DeveloperItem]

    /// Moves confirmed items to the Trash: the real Trash for the live scanner, nothing for the
    /// simulated one.
    var trasher: any StorageTrashing { get }

    /// Where each scan's folder sizes are kept for What grew (D-208); nil keeps nothing (the
    /// simulated scanner, tests, previews).
    var folderSizesURL: URL? { get }

    /// Time Machine's backups (D-216); nil when no backup disk is set up.
    func timeMachine() -> TimeMachineStatus?
}

/// The real scanner: `getattrlistbulk` on a dedicated thread (see `BulkScanEngine`).
public struct LiveStorageScanner: StorageScanning {
    private static let log = Logger(subsystem: "app.mactivity.storage", category: "scanner")

    public let home: URL
    private let options: StorageScanOptions

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), fileNodeThreshold: UInt64 = 1_000_000) {
        self.home = home
        options = StorageScanOptions(home: home.path, fileNodeThreshold: fileNodeThreshold)
    }

    public var trasher: any StorageTrashing {
        StorageTrasher(home: home.path)
    }

    public var folderSizesURL: URL? {
        FolderGrowthLog.defaultURL()
    }

    /// Time Machine's settings, `/Library/Preferences/com.apple.TimeMachine`. Through the
    /// preferences system: macOS's privacy protection keeps the file itself from apps without Full
    /// Disk Access, but its values are readable this way, as `defaults read` reads them.
    public func timeMachine() -> TimeMachineStatus? {
        let domain = "/Library/Preferences/com.apple.TimeMachine" as CFString
        var plist: [String: Any] = [:]
        for key in ["Destinations", "AutoBackup"] {
            if let value = CFPreferencesCopyAppValue(key as CFString, domain) {
                plist[key] = value
            }
        }
        return TimeMachineStatus.parse(plist)
    }

    public func volumeSummary(for url: URL) -> VolumeSummary? {
        VolumeInfo.summary(for: url)
    }

    public func fullDiskAccess() -> FullDiskAccessStatus {
        VolumeInfo.fullDiskAccess(home: home.path)
    }

    public func scan(_ root: URL) -> AsyncThrowingStream<StorageScanEvent, any Error> {
        let options = options
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: StorageScanEvent.self, throwing: (any Error).self)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        continuation.onTermination = { _ in
            cancelled.withLock { $0 = true }
        }
        let path = root.standardizedFileURL.path
        let thread = Thread {
            let engine = BulkScanEngine(
                root: path,
                options: options,
                isCancelled: { cancelled.withLock { $0 } },
                progress: { continuation.yield(.progress($0)) }
            )
            do {
                let result = try engine.scan()
                continuation.yield(.finished(result))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        thread.name = "app.mactivity.storage.scan"
        thread.qualityOfService = .utility
        thread.stackSize = 8 << 20
        thread.start()
        return stream
    }

    public func developerLens(for scan: StorageScan?) async -> [DeveloperItem] {
        let home = home.path
        return await withCheckedContinuation { continuation in
            let thread = Thread {
                let items = DeveloperLens.discover(home: home, scan: scan) { path in
                    Self.measure(path, home: home)
                }
                continuation.resume(returning: items)
            }
            thread.name = "app.mactivity.storage.lens"
            thread.qualityOfService = .utility
            thread.stackSize = 8 << 20
            thread.start()
        }
    }

    /// Allocated size of a file or folder, or nil if it isn't there.
    /// A file's or folder's allocated size, as Storage measures it; nil if it isn't there.
    public static func allocatedSize(_ path: String) -> UInt64? {
        measure(path, home: NSHomeDirectory())
    }

    static func measure(_ path: String, home: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return nil
        }
        if info.st_mode & S_IFMT != S_IFDIR {
            return UInt64(max(0, info.st_blocks)) * 512
        }
        let engine = BulkScanEngine(
            root: path,
            options: StorageScanOptions(home: home, fileNodeThreshold: .max),
            isCancelled: { false },
            progress: { _ in }
        )
        do {
            return try engine.scan().root.size
        } catch {
            log.debug("Couldn't measure \(path, privacy: .private): \(String(describing: error))")
            return nil
        }
    }
}
