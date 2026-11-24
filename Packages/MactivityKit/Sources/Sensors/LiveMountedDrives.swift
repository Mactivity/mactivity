import Core
import Darwin
import Foundation
import os

/// External and network drives (D-284, D-285). No polling: everything here runs when a card asks
/// or macOS says something mounted. Only the mount table, `statfs` on the mount point, and
/// `diskutil` are used; nothing on a drive is listed or opened.
public actor LiveMountedDrives: MountedDriveSource {
    private static let log = Logger(subsystem: "app.mactivity.sensors", category: "drives")

    private let memory: URL?
    private let health: any DriveHealthSource
    private let table: @Sendable () -> [MountEntry]
    private let info: @Sendable (String) -> DiskInfo?
    private let reader: MountReader
    private let now: @Sendable () -> Date
    private var infoCache: [String: DiskInfo] = [:]
    private var remembered: [ExternalDrive]?

    public init(health: any DriveHealthSource = LiveDriveHealth()) {
        self.init(
            memory: Self.defaultMemoryURL(), health: health, table: { MountTable.read() },
            info: { Self.diskInfo($0) }, read: { MountTable.space($0) }, timeout: .seconds(3), now: { Date() }
        )
    }

    init(
        memory: URL?, health: any DriveHealthSource, table: @escaping @Sendable () -> [MountEntry],
        info: @escaping @Sendable (String) -> DiskInfo?, read: @escaping @Sendable (String) -> DriveSpace?, timeout: Duration,
        now: @escaping @Sendable () -> Date
    ) {
        self.memory = memory
        self.health = health
        self.table = table
        self.info = info
        reader = MountReader(timeout: timeout, read: read)
        self.now = now
    }

    /// Application Support/Mactivity/external-drives.json: on this Mac only, like the history.
    static func defaultMemoryURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Mactivity", isDirectory: true)
            .appendingPathComponent("external-drives.json")
    }

    // MARK: External

    public func externalDrives() async -> [ExternalDrive] {
        let candidates = ExternalDrives.candidates(table())
        let paths = Set(candidates.map(\.path))
        infoCache = infoCache.filter { paths.contains($0.key) }
        var found: [(entry: MountEntry, info: DiskInfo)] = []
        for entry in candidates {
            if let cached = infoCache[entry.path] {
                found.append((entry, cached))
            } else if let read = await readInfo(entry.path), read.isExternalDrive {
                infoCache[entry.path] = read
                found.append((entry, read))
            }
        }
        // Reports are read only for a drive to match them with.
        let reports = found.isEmpty ? [] : await health.drives()
        let moment = now()
        var connected: [ExternalDrive] = []
        let models = found.map(\.info.model)
        for (entry, info) in found {
            let report = ExternalDrives.report(for: info.model, reports: reports, mountedModels: models)
            let verdict = ExternalDrives.health(smartStatus: info.smartStatus, report: report)
            let space: DriveSpace = if case let .figures(fresh) = await reader.read(entry.path) {
                fresh
            } else {
                DriveSpace(totalBytes: entry.totalBytes, availableBytes: entry.availableBytes)
            }
            connected.append(ExternalDrive(
                id: info.volumeUUID ?? "\(info.name ?? entry.path)#\(entry.totalBytes)",
                name: info.name ?? (entry.path as NSString).lastPathComponent,
                format: info.format ?? entry.fileSystem, model: info.model, connection: info.connection, space: space,
                health: verdict.0, percentUsed: verdict.percentUsed, lastSeen: moment, isConnected: true
            ))
        }
        let all = ExternalDrives.merged(remembered: loadMemory(), connected: connected)
        if all != loadMemory() {
            saveMemory(all)
        }
        return all
    }

    public func forgetExternalDrive(id: String) async {
        let kept = loadMemory().filter { $0.id != id }
        saveMemory(kept)
    }

    /// `diskutil` asks the disk daemon, which can wait on a drive that's stopped answering. Off
    /// this actor, with a time limit.
    private func readInfo(_ path: String) async -> DiskInfo? {
        let info = info
        return await Task.detached(priority: .utility) { info(path) }.value
    }

    private func loadMemory() -> [ExternalDrive] {
        if let remembered {
            return remembered
        }
        guard let memory, let data = try? Data(contentsOf: memory),
              let drives = try? JSONDecoder().decode([ExternalDrive].self, from: data)
        else {
            return []
        }
        remembered = drives
        return drives
    }

    private func saveMemory(_ drives: [ExternalDrive]) {
        remembered = drives
        guard let memory else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: memory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(drives).write(to: memory, options: .atomic)
        } catch {
            Self.log.error("Couldn't keep external drives: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func diskInfo(_ path: String) -> DiskInfo? {
        guard let info = readDiskInfo(path) else {
            return nil
        }
        guard info.model == nil, info.isExternalDrive, let store = info.physicalStore else {
            return info
        }
        return info.withModel(readDiskInfo(store)?.model)
    }

    private static func readDiskInfo(_ target: String) -> DiskInfo? {
        Subprocess.output("/usr/sbin/diskutil", ["info", "-plist", target], timeout: 5).flatMap { DiskInfo.parse(plist: $0) }
    }

    // MARK: Network

    public func networkDrives() async -> [NetworkDrive] {
        var drives: [NetworkDrive] = []
        for entry in NetworkDrives.mounts(table()) {
            let lastKnown = entry.totalBytes > 0 ? DriveSpace(totalBytes: entry.totalBytes, availableBytes: entry.availableBytes) : nil
            let status: NetworkDrive.Status
            switch await reader.read(entry.path) {
            case let .figures(space): status = .responding(space)
            case .notResponding: status = .notResponding(lastKnown: lastKnown)
            // Unmounted since the table was read.
            case .gone: continue
            }
            drives.append(NetworkDrive(
                path: entry.path, name: (entry.path as NSString).lastPathComponent,
                server: NetworkDrives.server(fromSource: entry.source), kind: .of(fileSystem: entry.fileSystem), status: status
            ))
        }
        return drives.sorted { $0.name < $1.name }
    }

    public func nfsCounters() async -> NFSCounters? {
        guard NetworkDrives.mounts(table()).contains(where: { NetworkDrive.Kind.of(fileSystem: $0.fileSystem) == .nfs }) else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            Subprocess.output("/usr/bin/nfsstat", ["-c", "-f", "JSON"], timeout: 5).flatMap { NFSCounters.parse(json: $0) }
        }.value
    }
}

/// Reads a mount point on a thread of its own, with a time limit (D-285). `statfs` on a dead
/// network mount can sit in the kernel for minutes or for good, and nothing can cancel it, so:
/// the caller gets "not responding" when the time's up, and the thread is left to finish. Until it
/// does, that mount gets no second thread, so a dead share costs one blocked thread however long
/// the card stays open.
actor MountReader {
    enum Outcome: Equatable {
        case figures(DriveSpace)
        /// It answered: there's nothing there any more.
        case gone
        case notResponding
    }

    private let timeout: Duration
    private let read: @Sendable (String) -> DriveSpace?
    private var waiting: Set<String> = []

    init(timeout: Duration, read: @escaping @Sendable (String) -> DriveSpace?) {
        self.timeout = timeout
        self.read = read
    }

    func read(_ path: String) async -> Outcome {
        guard !waiting.contains(path) else {
            return .notResponding
        }
        waiting.insert(path)
        let read = read
        let timeout = timeout
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let thread = Thread { [weak self] in
                let found = read(path)
                once.resume(found.map(Outcome.figures) ?? .gone)
                Task { await self?.finished(path) }
            }
            thread.name = "Mactivity mount read"
            thread.stackSize = 128 * 1024
            thread.start()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.seconds) {
                once.resume(.notResponding)
            }
        }
    }

    private func finished(_ path: String) {
        waiting.remove(path)
    }

    private final class Once: Sendable {
        private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Outcome, Never>?>

        init(_ continuation: CheckedContinuation<Outcome, Never>) {
            self.continuation = OSAllocatedUnfairLock(initialState: continuation)
        }

        func resume(_ outcome: Outcome) {
            let waiting = continuation.withLock { value in
                defer { value = nil }
                return value
            }
            waiting?.resume(returning: outcome)
        }
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// The kernel's mount table.
public enum MountTable {
    /// `getfsstat` with `MNT_NOWAIT`: answered from what the kernel already has, so it can't wait
    /// on a dead network mount.
    public static func read() -> [MountEntry] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else {
            return []
        }
        var stats = Array(repeating: statfs(), count: Int(count) + 8)
        let filled = stats.withUnsafeMutableBufferPointer { buffer in
            getfsstat(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else {
            return []
        }
        return stats.prefix(Int(filled)).map(entry)
    }

    private static func entry(_ stat: statfs) -> MountEntry {
        let flags = stat.f_flags
        return MountEntry(
            path: text(stat.f_mntonname), fileSystem: text(stat.f_fstypename), source: text(stat.f_mntfromname),
            isLocal: flags & UInt32(MNT_LOCAL) != 0, isBrowsable: flags & UInt32(MNT_DONTBROWSE) == 0,
            totalBytes: UInt64(stat.f_blocks) &* UInt64(stat.f_bsize), availableBytes: UInt64(stat.f_bavail) &* UInt64(stat.f_bsize)
        )
    }

    private static func text(_ tuple: some Any) -> String {
        withUnsafeBytes(of: tuple) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
    }

    /// Fresh figures for one mount point: this is the call that can hang, so only ever from
    /// `MountReader`. Nil if it's gone.
    static func space(_ path: String) -> DriveSpace? {
        var stat = statfs()
        guard statfs(path, &stat) == 0 else {
            return nil
        }
        return DriveSpace(
            totalBytes: UInt64(stat.f_blocks) &* UInt64(stat.f_bsize), availableBytes: UInt64(stat.f_bavail) &* UInt64(stat.f_bsize)
        )
    }
}

/// A short command's standard output, or nil when it can't start, fails, or runs past `timeout`.
private enum Subprocess {
    static func output(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else {
            return nil
        }
        let killer = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
