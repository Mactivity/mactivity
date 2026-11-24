import Core
import Foundation
import IOKit

/// Volumes and free space from `FileManager`, system-wide throughput from IORegistry
/// `IOBlockStorageDriver` → "Statistics" (spec 6.4). Public API only.
public actor DiskSampler: DiskSource {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    /// How long a mounted-volume list is reused before asking FileManager again.
    static let volumeListLifetime: Duration = .seconds(30)
    /// How long a volume's "important usage" free space is reused. Reading it costs ~13 ms per
    /// volume on the M5 Pro (it asks the purgeable-space service): at 5 minutes that alone was 14%
    /// of idle CPU. Ticks in between track it by the change in plain available space, one `statfs`
    /// (see `DiskMath.freeBytes`), so only the purgeable part can drift, and it moves slowly.
    static let importantFreeLifetime: Duration = .seconds(1800)

    private static let fullKeys: Set<URLResourceKey> = [
        .volumeIsLocalKey,
        .volumeNameKey,
        .volumeUUIDStringKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
    ]

    /// What the last full (slow) read of one volume found.
    private struct VolumeBaseline {
        let id: String
        let name: String
        let totalBytes: UInt64
        let importantFree: UInt64?
        let availableFree: UInt64?
        /// The file system mounted there when read: a different disk plugged in at the same
        /// mount point ("/Volumes/Untitled", "NO NAME") isn't read with this one's figures (D-221).
        let fileSystemID: UInt64?
        let readAt: SuspendingClock.Instant
    }

    private let clock = SuspendingClock()
    private let driverMatching: CFDictionary?
    private var volumeURLs: [URL] = []
    private var volumesListedAt: SuspendingClock.Instant?
    /// Keyed by mount point path. A listed volume without a baseline gets a full read.
    private var baselines: [String: VolumeBaseline] = [:]
    private var previous: (counters: [UInt64: BlockCounters], at: SuspendingClock.Instant)?
    /// Whether each driver (by registry entry ID) sits on a disk image. Decided once per driver.
    private var isDiskImage: [UInt64: Bool] = [:]
    /// The physical drivers, retained, listed again every `volumeListLifetime` or as soon as one
    /// stops answering. Listing is an IORegistry match plus a Mach call per driver; every tick did
    /// it (D-086). A disk attached in between is counted from the next listing.
    private var drivers: [(id: UInt64, service: io_service_t)] = []
    private var driversListedAt: SuspendingClock.Instant?

    public init() {
        driverMatching = IORegistry.matching("IOBlockStorageDriver")
    }

    deinit {
        for driver in drivers {
            IOObjectRelease(driver.service)
        }
    }

    public func sample() async throws -> DiskStats {
        let now = clock.now
        let counters = readCounters(now: now)
        let elapsed = previous.map { (now - $0.at).seconds } ?? 0
        let rates = DiskMath.throughput(previous: previous?.counters, current: counters, elapsedSeconds: elapsed)
        let operations = DiskMath.operations(previous: previous?.counters, current: counters, elapsedSeconds: elapsed)
        previous = (counters, now)
        return DiskStats(
            volumes: readVolumes(now: now), readBPS: rates.readBPS, writeBPS: rates.writeBPS,
            totals: DiskMath.totals(counters), readsPerSecond: operations.reads, writesPerSecond: operations.writes
        )
    }

    // MARK: Volumes

    private func readVolumes(now: SuspendingClock.Instant) -> [VolumeStats] {
        if volumesListedAt.map({ now - $0 >= Self.volumeListLifetime }) ?? true {
            volumeURLs = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil,
                options: [.skipHiddenVolumes]
            ) ?? []
            volumesListedAt = now
            // Reading a network mount can hang for good if its server's gone (D-285), and this
            // is the shared sampling thread. The kernel's mount table says which are local
            // without asking any of them.
            volumeURLs = DiskMath.localOnly(volumeURLs, nonLocalMounts: Self.nonLocalMounts())
            let paths = Set(volumeURLs.map(\.path))
            baselines = baselines.filter { paths.contains($0.key) }
        }
        var bootID: String?
        let volumes = volumeURLs.compactMap { url -> VolumeStats? in
            guard let volume = volume(at: url, now: now) else {
                return nil
            }
            if url.path == "/" {
                bootID = volume.id
            }
            return volume
        }
        return DiskMath.ordered(volumes, bootID: bootID)
    }

    /// Current figures for one local volume; nil for network volumes and volumes that went away.
    private func volume(at url: URL, now: SuspendingClock.Instant) -> VolumeStats? {
        if let baseline = baselines[url.path], now - baseline.readAt < Self.importantFreeLifetime,
           let current = Self.fileSystem(url.path), current.id == baseline.fileSystemID {
            let available: UInt64? = current.available
            return VolumeStats(
                id: baseline.id,
                name: baseline.name,
                totalBytes: baseline.totalBytes,
                freeBytes: DiskMath.freeBytes(
                    importantAtBaseline: baseline.importantFree,
                    availableAtBaseline: baseline.availableFree,
                    availableNow: available,
                    totalBytes: baseline.totalBytes
                )
            )
        }
        guard let values = Self.resourceValues(url, Self.fullKeys),
              values.volumeIsLocal == true,
              let total = values.volumeTotalCapacity
        else {
            baselines[url.path] = nil
            return nil
        }
        let baseline = VolumeBaseline(
            id: values.volumeUUIDString ?? url.path,
            name: values.volumeName ?? url.lastPathComponent,
            totalBytes: UInt64(max(total, 0)),
            importantFree: values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) },
            // Same source as the per-tick reads, so the delta between them is consistent.
            availableFree: Self.availableBytes(url.path) ?? values.volumeAvailableCapacity.map { UInt64(max($0, 0)) },
            fileSystemID: Self.fileSystem(url.path)?.id,
            readAt: now
        )
        baselines[url.path] = baseline
        return VolumeStats(
            id: baseline.id,
            name: baseline.name,
            totalBytes: baseline.totalBytes,
            freeBytes: baseline.importantFree ?? baseline.availableFree ?? 0
        )
    }

    /// Space available to this user, straight from the file system: one system call, where URL
    /// resource values go through CFURL and its cache. Nil if the volume went away.
    static func availableBytes(_ path: String) -> UInt64? {
        fileSystem(path)?.available
    }

    /// The same one call, with the mounted file system's ID.
    static func fileSystem(_ path: String) -> (available: UInt64, id: UInt64)? {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else {
            return nil
        }
        let id = UInt64(UInt32(bitPattern: stats.f_fsid.val.0)) << 32 | UInt64(UInt32(bitPattern: stats.f_fsid.val.1))
        return (UInt64(stats.f_bavail) &* UInt64(stats.f_bsize), id)
    }

    /// Mount points the kernel doesn't call local. `MNT_NOWAIT` answers from what it has.
    private static func nonLocalMounts() -> Set<String> {
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
        var paths = Set<String>()
        for stat in stats.prefix(Int(filled)) where stat.f_flags & UInt32(MNT_LOCAL) == 0 {
            let path = withUnsafeBytes(of: stat.f_mntonname) { bytes in
                String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
            }
            paths.insert(path)
        }
        return paths
    }

    /// Fresh values: a URL caches resource values, so start from a clean copy each time.
    private static func resourceValues(_ url: URL, _ keys: Set<URLResourceKey>) -> URLResourceValues? {
        var url = url
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: keys)
    }

    // MARK: Throughput

    /// Cumulative counters for every physical block storage driver, keyed by registry entry ID.
    private func readCounters(now: SuspendingClock.Instant) -> [UInt64: BlockCounters] {
        if driversListedAt.map({ now - $0 >= Self.volumeListLifetime }) ?? true {
            listDrivers(now: now)
        }
        var counters: [UInt64: BlockCounters] = [:]
        var missing = false
        for driver in drivers {
            guard let statistics = IORegistry.property(driver.service, "Statistics") as? [String: Any],
                  let reading = DiskMath.counters(statistics: statistics)
            else {
                missing = true
                continue
            }
            counters[driver.id] = reading
        }
        if missing {
            // A disk went away: list again next tick. Its counter just drops out, as before.
            driversListedAt = nil
        }
        return counters
    }

    private func listDrivers(now: SuspendingClock.Instant) {
        for driver in drivers {
            IOObjectRelease(driver.service)
        }
        drivers = []
        driversListedAt = now
        guard let driverMatching else {
            return
        }
        var seen: Set<UInt64> = []
        IORegistry.forEachService(matching: driverMatching) { driver in
            guard let id = IORegistry.entryID(driver) else {
                return
            }
            seen.insert(id)
            guard !diskImage(driver, id: id) else {
                return
            }
            // `forEachService` releases each handle after the call; keep our own reference.
            IOObjectRetain(driver)
            drivers.append((id, driver))
        }
        // Forget drivers that went away so the cache can't grow across many image mounts.
        isDiskImage = isDiskImage.filter { seen.contains($0.key) }
    }

    private func diskImage(_ driver: io_service_t, id: UInt64) -> Bool {
        if let known = isDiskImage[id] {
            return known
        }
        let characteristics = IORegistry.withParent(of: driver) {
            IORegistry.property($0, "Protocol Characteristics") as? [String: Any]
        }
        let virtual = DiskMath.isVirtual(protocolCharacteristics: characteristics)
        isDiskImage[id] = virtual
        return virtual
    }
}
