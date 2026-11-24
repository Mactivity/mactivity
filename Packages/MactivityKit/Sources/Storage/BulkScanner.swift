import Darwin
import Foundation
import os

/// Options for one scan.
public struct StorageScanOptions: Sendable {
    /// The home folder, for `~/Library` and the Developer lens.
    public var home: String
    /// Files at least this large get their own node; smaller ones are summed per folder.
    public var fileNodeThreshold: UInt64
    /// Threads reading folders at once.
    public var workers: Int

    public init(
        home: String = NSHomeDirectory(),
        fileNodeThreshold: UInt64 = 1_000_000,
        workers: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.home = home
        self.fileNodeThreshold = fileNodeThreshold
        self.workers = max(1, workers)
    }
}

/// The scan engine: `getattrlistbulk` over each folder, one `open` per folder, no `stat` per file.
///
/// - Sizes are `ATTR_FILE_ALLOCSIZE` (allocated bytes, all forks), so sparse and compressed
///   files count what they occupy.
/// - A file with more than one link is counted once per (device, file ID).
/// - Symlinks are counted as themselves and never followed (`O_NOFOLLOW`, and they're not folders).
/// - Mount points and autofs triggers (`ATTR_DIR_MOUNTSTATUS`) are never opened, and a folder
///   whose `fstat` device isn't its parent's is skipped. The one exception: scanning `/` enters
///   `/System/Volumes/Data` once.
/// - Firmlinks can't be told apart by device: the System and Data volumes of an APFS volume
///   group share one `st_dev`. So scanning `/` skips the firmlinks listed in
///   `/usr/share/firmlinks` (`/Users`, `/Applications`, …) and counts that data once, under
///   `/System/Volumes/Data`. Any other root has no firmlink duplicates to skip.
/// - A folder that won't open becomes an `.unreadable` node and is listed in `unreadable`.
///
/// Synchronous: call it from a background thread. Folders are jobs on a shared stack that a
/// pool of workers drains; a folder becomes a node when its last subfolder finishes.
final class BulkScanEngine: Sendable {
    static let dataVolume = "/System/Volumes/Data"
    private static let log = Logger(subsystem: "app.mactivity.storage", category: "scanner")
    private static let progressInterval = Duration.milliseconds(100)

    private let options: StorageScanOptions
    private let progress: @Sendable (StorageScanProgress) -> Void
    private let isCancelled: @Sendable () -> Bool
    private let started = ContinuousClock.now
    private let rootPath: String
    /// Firmlink paths to skip; only when scanning "/".
    private let firmlinks: Set<String>

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let jobs = OSAllocatedUnfairLock(initialState: [Job]())
    private let jobsAvailable = DispatchSemaphore(value: 0)
    /// Guards every `PendingFolder`'s mutable state.
    private let treeLock = OSAllocatedUnfairLock()
    private let result = OSAllocatedUnfairLock<StorageNode?>(initialState: nil)

    private struct FileKey: Hashable {
        let device: Int32
        let fileID: UInt64
    }

    private struct Shared {
        var files = 0
        var directories = 0
        var bytes: UInt64 = 0
        var nextProgress = ContinuousClock.now
        var hardLinks: Set<FileKey> = []
        var unreadable: [String] = []
        var skipped: [String] = []
    }

    /// Per-worker tallies, merged at the end.
    private struct Tally: Sendable {
        var categoryBytes = [UInt64](repeating: 0, count: StorageCategory.allCases.count)
        var categoryFiles = [Int](repeating: 0, count: StorageCategory.allCases.count)
        var categories = CategoryCache()

        mutating func add(_ other: Tally) {
            for index in categoryBytes.indices {
                categoryBytes[index] += other.categoryBytes[index]
                categoryFiles[index] += other.categoryFiles[index]
            }
        }
    }

    /// A folder to read.
    private struct Job: Sendable {
        let name: String
        let path: String
        /// The device to expect once it's open; nil adopts whatever it is (the Data volume).
        let device: Int32?
        let context: StorageCategory?
        let parent: PendingFolder?
    }

    init(
        root: String,
        options: StorageScanOptions,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (StorageScanProgress) -> Void
    ) {
        rootPath = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        firmlinks = rootPath == "/" ? Firmlinks.read() : []
        self.options = options
        self.isCancelled = isCancelled
        self.progress = progress
    }

    func scan() throws(StorageScanError) -> StorageScan {
        let startedAt = Date()
        var info = stat()
        guard lstat(rootPath, &info) == 0 else {
            throw .unreadableRoot(path: rootPath, errno: errno)
        }
        let probe = open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard probe >= 0 else {
            throw .unreadableRoot(path: rootPath, errno: errno)
        }
        close(probe)
        let name = rootPath == "/" ? (volumeName(rootPath) ?? "Macintosh HD") : (rootPath as NSString).lastPathComponent
        let context = CategoryRules.context(forFolder: name, path: rootPath, home: options.home, inherited: nil)
        push([Job(name: name, path: rootPath, device: info.st_dev, context: context, parent: nil)])
        let tally = runWorkers()
        if isCancelled() {
            throw .cancelled
        }
        let root = result.withLock { $0 } ?? .directory(name: name, path: rootPath, children: [])
        let state = shared.withLock { $0 }
        let categories = StorageCategory.allCases.enumerated().map { index, category in
            CategoryTotal(category: category, bytes: tally.categoryBytes[index], fileCount: tally.categoryFiles[index])
        }
        .sorted { $0.bytes > $1.bytes }
        let duration = ContinuousClock.now - started
        Self.log.info(
            "Scanned \(state.files) files in \(state.directories) folders under \(self.rootPath, privacy: .private) in \(duration)"
        )
        return StorageScan(
            root: root,
            startedAt: startedAt,
            duration: duration,
            fileCount: state.files,
            directoryCount: state.directories,
            categories: categories,
            largestFiles: StorageScan.largestFiles(in: root),
            unreadable: state.unreadable.sorted(),
            skipped: state.skipped.sorted(),
            home: options.home
        )
    }

    // MARK: Workers

    /// Runs the pool until the root folder is finished, then returns the merged tallies.
    private func runWorkers() -> Tally {
        let count = options.workers
        var tallies = [Tally](repeating: Tally(), count: count)
        tallies.withUnsafeMutableBufferPointer { buffer in
            let slots = Slots(buffer: buffer)
            DispatchQueue.concurrentPerform(iterations: count) { index in
                var tally = Tally()
                var reader = BulkReader()
                defer { reader.deallocate() }
                while true {
                    jobsAvailable.wait()
                    guard let job = jobs.withLock({ $0.popLast() }) else {
                        break
                    }
                    process(job, reader: &reader, tally: &tally)
                }
                slots.set(index, tally)
            }
        }
        var total = Tally()
        for tally in tallies {
            total.add(tally)
        }
        return total
    }

    private func push(_ newJobs: [Job]) {
        guard !newJobs.isEmpty else {
            return
        }
        jobs.withLock { $0.append(contentsOf: newJobs) }
        for _ in newJobs {
            jobsAvailable.signal()
        }
    }

    /// The root is done: wake every worker to find the stack empty and stop.
    private func finish(_ root: StorageNode?) {
        result.withLock { $0 = root }
        for _ in 0 ..< options.workers {
            jobsAvailable.signal()
        }
    }

    private func process(_ job: Job, reader: inout BulkReader, tally: inout Tally) {
        switch read(job, reader: &reader, tally: &tally) {
        case .skipped:
            deliver(nil, to: job.parent)
        case let .done(node):
            deliver(node, to: job.parent)
        case let .waiting(subfolders):
            push(subfolders)
        }
    }

    /// Hands a finished child to its parent, and finishes each ancestor whose last child it was.
    private func deliver(_ node: StorageNode?, to parent: PendingFolder?) {
        var node = node
        var parent = parent
        while let folder = parent {
            let child = node
            let isLast = treeLock.withLockUnchecked {
                if let child {
                    folder.children.append(child)
                }
                folder.remaining -= 1
                return folder.remaining == 0
            }
            guard isLast else {
                return
            }
            // No other thread touches a folder once its last child is in.
            node = .directory(name: folder.name, path: folder.path, children: folder.children)
            parent = folder.parent
        }
        finish(node)
    }

    // MARK: One folder

    private enum Outcome {
        case skipped
        case done(StorageNode)
        case waiting([Job])
    }

    /// What one folder holds, gathered while its entries stream in.
    private struct FolderContents {
        var children: [StorageNode] = []
        var subfolders: [(name: String, device: Int32?)] = []
        var smallBytes: UInt64 = 0
        var smallCount = 0
        var fileCount = 0
        var fileBytes: UInt64 = 0
    }

    private func read(_ job: Job, reader: inout BulkReader, tally: inout Tally) -> Outcome {
        let path = job.path
        if isCancelled() {
            return .done(.directory(name: job.name, path: path, children: []))
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            return .done(unreadable(name: job.name, path: path, errno: errno))
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            close(fd)
            return .done(unreadable(name: job.name, path: path, errno: errno))
        }
        if let expected = job.device, info.st_dev != expected {
            close(fd)
            skip(path)
            return .skipped
        }
        var contents = FolderContents()
        let readError = reader.readEntries(fd) { entry in
            add(entry, of: job, device: info.st_dev, to: &contents, tally: &tally)
        }
        close(fd)
        noteProgress(files: contents.fileCount, bytes: contents.fileBytes, path: path)
        if let readError, contents.children.isEmpty, contents.subfolders.isEmpty, contents.fileCount == 0 {
            return .done(unreadable(name: job.name, path: path, errno: readError))
        }
        if contents.smallCount > 0 {
            contents.children.append(StorageNode(
                name: smallFilesName(contents.smallCount),
                path: path,
                kind: .smallFiles,
                size: contents.smallBytes,
                fileCount: contents.smallCount
            ))
        }
        guard !contents.subfolders.isEmpty else {
            return .done(.directory(name: job.name, path: path, children: contents.children))
        }
        let folder = PendingFolder(
            name: job.name,
            path: path,
            parent: job.parent,
            children: contents.children,
            remaining: contents.subfolders.count
        )
        return .waiting(contents.subfolders.map { name, device in
            let childPath = join(path, name)
            return Job(
                name: name,
                path: childPath,
                device: device,
                context: CategoryRules.context(forFolder: name, path: childPath, home: options.home, inherited: job.context),
                parent: folder
            )
        })
    }

    private func add(_ entry: BulkReader.Entry, of job: Job, device: Int32, to contents: inout FolderContents, tally: inout Tally) {
        let entryPath = join(job.path, entry.name)
        if entry.error != 0 {
            contents.children.append(unreadable(name: entry.name, path: entryPath, errno: Int32(entry.error)))
            return
        }
        if entry.isDirectory {
            if entry.mountStatus & BulkReader.mountFlags == 0, !firmlinks.contains(entryPath) {
                contents.subfolders.append((entry.name, device))
            } else if rootPath == "/", entryPath == Self.dataVolume {
                // Scanning "/" counts the Data volume once, at its mount point.
                contents.subfolders.append((entry.name, nil))
            } else {
                // Never opened: another volume, a firmlink, or an autofs trigger that could hang.
                skip(entryPath)
            }
            return
        }
        if entry.linkCount > 1, !claimHardLink(FileKey(device: device, fileID: entry.fileID)) {
            return
        }
        let category = job.context ?? tally.categories.category(forFileNamed: entry.name)
        tally.categoryBytes[category.index] += entry.allocatedSize
        tally.categoryFiles[category.index] += 1
        contents.fileCount += 1
        contents.fileBytes += entry.allocatedSize
        if entry.allocatedSize >= options.fileNodeThreshold {
            contents.children.append(StorageNode(
                name: entry.name,
                path: entryPath,
                kind: .file,
                size: entry.allocatedSize,
                fileCount: 1,
                category: category
            ))
        } else {
            contents.smallBytes += entry.allocatedSize
            contents.smallCount += 1
        }
    }
}

extension BulkScanEngine {

    // MARK: Shared state

    private func skip(_ path: String) {
        shared.withLock { $0.skipped.append(path) }
    }

    private func unreadable(name: String, path: String, errno code: Int32) -> StorageNode {
        shared.withLock { $0.unreadable.append(path) }
        Self.log.debug("Not readable: \(path, privacy: .private) (errno \(code))")
        return StorageNode(name: name, path: path, kind: .unreadable, size: 0, fileCount: 0)
    }

    /// True the first time a (device, file ID) is seen.
    private func claimHardLink(_ key: FileKey) -> Bool {
        shared.withLock { $0.hardLinks.insert(key).inserted }
    }

    private func noteProgress(files: Int, bytes: UInt64, path: String) {
        let now = ContinuousClock.now
        let report: StorageScanProgress? = shared.withLock { state in
            state.files += files
            state.directories += 1
            state.bytes += bytes
            guard now >= state.nextProgress else {
                return nil
            }
            state.nextProgress = now + Self.progressInterval
            return StorageScanProgress(
                filesScanned: state.files,
                directoriesScanned: state.directories,
                bytesScanned: state.bytes,
                currentPath: path,
                elapsed: now - started
            )
        }
        if let report {
            progress(report)
        }
    }

    private func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    private func smallFilesName(_ count: Int) -> String {
        count == 1 ? "1 smaller file" : "\(count.formatted()) smaller files"
    }

    private func volumeName(_ path: String) -> String? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
    }
}

/// A folder read but waiting for its subfolders. Its mutable state is only touched under the
/// engine's `treeLock`, and by the one thread that delivers its last child.
private final class PendingFolder: @unchecked Sendable {
    let name: String
    let path: String
    let parent: PendingFolder?
    var children: [StorageNode]
    var remaining: Int

    init(name: String, path: String, parent: PendingFolder?, children: [StorageNode], remaining: Int) {
        self.name = name
        self.path = path
        self.parent = parent
        self.children = children
        self.remaining = remaining
    }
}

/// Write-only slots for `concurrentPerform`: each iteration writes its own index, and the
/// buffer outlives the call, so no two threads touch the same element.
private struct Slots<Element>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<Element>

    func set(_ index: Int, _ value: Element) {
        buffer[index] = value
    }
}
