import Core
import Foundation

/// The `vm_statistics64` page counts the memory figures are built from.
public struct VMPageCounts: Hashable, Sendable, Codable {
    /// Anonymous (not file-backed) pages, `internal_page_count`.
    public let internalPages: UInt64
    public let wiredPages: UInt64
    /// Pages the compressor occupies, `compressor_page_count` (not the pages stored in it).
    public let compressorPages: UInt64
    /// File-backed pages, `external_page_count`.
    public let externalPages: UInt64
    public let purgeablePages: UInt64

    public init(internalPages: UInt64, wiredPages: UInt64, compressorPages: UInt64, externalPages: UInt64, purgeablePages: UInt64) {
        self.internalPages = internalPages
        self.wiredPages = wiredPages
        self.compressorPages = compressorPages
        self.externalPages = externalPages
        self.purgeablePages = purgeablePages
    }
}

/// Pure memory math over page counts (spec 6.3), kept apart from the syscalls so it runs on fixtures.
public enum MemoryMath {
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical. Anything else is normal.
    public static func pressure(level: Int) -> MemoryPressure {
        switch level {
        case 2: .warning
        case 4: .critical
        default: .normal
        }
    }

    /// Activity Monitor's breakdown. App = internal − purgeable; wired; compressed; cached files =
    /// external + purgeable; used = app + wired + compressed.
    public static func stats(
        counts: VMPageCounts,
        pageSize: UInt64,
        totalBytes: UInt64,
        swapUsedBytes: UInt64,
        pressureLevel: Int,
        availableLevel: Int
    ) -> MemoryStats {
        // Purgeable pages are counted in internal; guard the subtraction against a torn read.
        let appPages = counts.internalPages > counts.purgeablePages ? counts.internalPages - counts.purgeablePages : 0
        let app = appPages &* pageSize
        let wired = counts.wiredPages &* pageSize
        let compressed = counts.compressorPages &* pageSize
        let cached = (counts.externalPages &+ counts.purgeablePages) &* pageSize
        return MemoryStats(
            totalBytes: totalBytes,
            usedBytes: app &+ wired &+ compressed,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedFilesBytes: cached,
            swapUsedBytes: swapUsedBytes,
            pressure: pressure(level: pressureLevel),
            availableLevel: min(max(availableLevel, 0), 100)
        )
    }
}
