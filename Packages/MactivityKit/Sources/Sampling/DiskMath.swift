import Core
import Foundation

/// Cumulative bytes and operations one `IOBlockStorageDriver` has done since it attached.
public struct BlockCounters: Hashable, Sendable, Codable {
    public let bytesRead: UInt64
    public let bytesWritten: UInt64
    /// "Operations (Read)" and "(Write)": nil when the driver doesn't report them.
    public let reads: UInt64?
    public let writes: UInt64?

    public init(bytesRead: UInt64, bytesWritten: UInt64, reads: UInt64? = nil, writes: UInt64? = nil) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.reads = reads
        self.writes = writes
    }
}

/// Pure disk math (spec 6.4), kept apart from IOKit and FileManager so it runs on fixtures.
public enum DiskMath {
    /// Pure: the volumes to read, without the mounts the kernel doesn't call local (D-285).
    public static func localOnly(_ volumes: [URL], nonLocalMounts: Set<String>) -> [URL] {
        volumes.filter { !nonLocalMounts.contains($0.path) }
    }

    /// Read and write throughput between two readings, keyed by the driver's registry entry ID.
    /// See `CounterMath.rate` for how new, vanished, and backwards counters count.
    public static func throughput(
        previous: [UInt64: BlockCounters]?,
        current: [UInt64: BlockCounters],
        elapsedSeconds: Double
    ) -> (readBPS: Double, writeBPS: Double) {
        (
            CounterMath.rate(
                previous: previous?.mapValues(\.bytesRead),
                current: current.mapValues(\.bytesRead),
                elapsedSeconds: elapsedSeconds
            ),
            CounterMath.rate(
                previous: previous?.mapValues(\.bytesWritten),
                current: current.mapValues(\.bytesWritten),
                elapsedSeconds: elapsedSeconds
            )
        )
    }

    /// Counters from a driver's "Statistics" dictionary. Nil if either byte count is missing.
    public static func counters(statistics: [String: Any]) -> BlockCounters? {
        guard let read = PropertyValue.uint64(statistics["Bytes (Read)"]),
              let written = PropertyValue.uint64(statistics["Bytes (Write)"])
        else {
            return nil
        }
        return BlockCounters(
            bytesRead: read, bytesWritten: written,
            reads: PropertyValue.uint64(statistics["Operations (Read)"]),
            writes: PropertyValue.uint64(statistics["Operations (Write)"])
        )
    }

    /// Summed over every driver (D-097). Operation counts only when every driver has them.
    public static func totals(_ counters: [UInt64: BlockCounters]) -> DiskTotals? {
        guard !counters.isEmpty else {
            return nil
        }
        let all = Array(counters.values)
        let reads = all.allSatisfy { $0.reads != nil } ? all.reduce(UInt64(0)) { $0 &+ ($1.reads ?? 0) } : nil
        let writes = all.allSatisfy { $0.writes != nil } ? all.reduce(UInt64(0)) { $0 &+ ($1.writes ?? 0) } : nil
        return DiskTotals(
            bytesRead: all.reduce(0) { $0 &+ $1.bytesRead },
            bytesWritten: all.reduce(0) { $0 &+ $1.bytesWritten },
            reads: reads, writes: writes
        )
    }

    /// Operations a second between two readings, like `throughput`. Nil without operation counts.
    public static func operations(
        previous: [UInt64: BlockCounters]?,
        current: [UInt64: BlockCounters],
        elapsedSeconds: Double
    ) -> (reads: Double?, writes: Double?) {
        func rate(_ path: KeyPath<BlockCounters, UInt64?>) -> Double? {
            guard current.values.allSatisfy({ $0[keyPath: path] != nil }) else {
                return nil
            }
            return CounterMath.rate(
                previous: previous?.compactMapValues { $0[keyPath: path] },
                current: current.compactMapValues { $0[keyPath: path] },
                elapsedSeconds: elapsedSeconds
            )
        }
        return (rate(\.reads), rate(\.writes))
    }

    /// Whether a block device is a disk image, from its "Protocol Characteristics" dictionary.
    ///
    /// A disk image's reads and writes land on the disk holding the image file as well, so
    /// counting both would double them. Disk images report "Virtual Interface".
    public static func isVirtual(protocolCharacteristics: [String: Any]?) -> Bool {
        (protocolCharacteristics?["Physical Interconnect"] as? String) == "Virtual Interface"
    }

    /// Free space for the "important usage" figure (what Finder shows: available plus purgeable),
    /// between full reads. The purgeable part changes slowly, so the important figure from the last
    /// full read moves by however much plain available capacity has moved since. Clamped to
    /// 0...total. Without an important figure it's plain available capacity.
    public static func freeBytes(
        importantAtBaseline: UInt64?,
        availableAtBaseline: UInt64?,
        availableNow: UInt64?,
        totalBytes: UInt64
    ) -> UInt64 {
        guard let important = importantAtBaseline else {
            return min(availableNow ?? availableAtBaseline ?? 0, totalBytes)
        }
        guard let before = availableAtBaseline, let now = availableNow else {
            return min(important, totalBytes)
        }
        let adjusted = Int64(clamping: important) &+ (Int64(clamping: now) &- Int64(clamping: before))
        return UInt64(min(max(adjusted, 0), Int64(clamping: totalBytes)))
    }

    /// The boot volume first (the UI treats `DiskStats.volumes.first` as the boot volume),
    /// then the rest by name, in Finder order.
    public static func ordered(_ volumes: [VolumeStats], bootID: String?) -> [VolumeStats] {
        volumes.sorted { lhs, rhs in
            if (lhs.id == bootID) != (rhs.id == bootID) {
                return lhs.id == bootID
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
