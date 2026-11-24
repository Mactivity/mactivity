import Core
import Foundation
@testable import Sampling
import Testing

struct MemoryFixture: Decodable {
    let counts: VMPageCounts
    let pageSize: UInt64
    let totalBytes: UInt64
    let swapUsedBytes: UInt64
    let pressureLevel: Int
    let availableLevel: Int

    var stats: MemoryStats {
        MemoryMath.stats(
            counts: counts,
            pageSize: pageSize,
            totalBytes: totalBytes,
            swapUsedBytes: swapUsedBytes,
            pressureLevel: pressureLevel,
            availableLevel: availableLevel
        )
    }
}

@Suite("Memory math")
struct MemoryMathTests {
    let fixture: MemoryFixture

    init() throws {
        fixture = try Fixtures.load("memory-vm-m5pro.json")
    }

    @Test("App, wired, compressed, cached, and used match Activity Monitor's formulas")
    func breakdown() {
        let stats = fixture.stats
        #expect(stats.appBytes == 24_358_420_480)
        #expect(stats.wiredBytes == 4_023_599_104)
        #expect(stats.compressedBytes == 1_431_814_144)
        #expect(stats.cachedFilesBytes == 16_647_372_800)
        #expect(stats.usedBytes == 29_813_833_728)
        #expect(stats.usedBytes == stats.appBytes + stats.wiredBytes + stats.compressedBytes)
    }

    @Test("Total, swap, pressure, and available level pass through")
    func passThrough() {
        let stats = fixture.stats
        #expect(stats.totalBytes == 51_539_607_552)
        #expect(stats.swapUsedBytes == 1_082_851_328)
        #expect(stats.pressure == .normal)
        #expect(stats.availableLevel == 89)
        #expect(abs(stats.usedFraction - 29_813_833_728.0 / 51_539_607_552.0) < 1e-12)
    }

    @Test(
        "Pressure levels map 1/2/4 to normal/warning/critical, anything else to normal",
        arguments: [(1, MemoryPressure.normal), (2, .warning), (4, .critical), (0, .normal), (3, .normal), (-1, .normal)]
    )
    func pressure(level: Int, expected: MemoryPressure) {
        #expect(MemoryMath.pressure(level: level) == expected)
    }

    @Test("More purgeable than internal pages (a torn read) gives zero app memory, not a wrapped number")
    func purgeableExceedsInternal() {
        let counts = VMPageCounts(internalPages: 10, wiredPages: 1, compressorPages: 1, externalPages: 5, purgeablePages: 12)
        let stats = MemoryMath.stats(
            counts: counts, pageSize: 16384, totalBytes: 1 << 30, swapUsedBytes: 0, pressureLevel: 1, availableLevel: 50
        )
        #expect(stats.appBytes == 0)
        #expect(stats.usedBytes == 2 * 16384)
        #expect(stats.cachedFilesBytes == 17 * 16384)
    }

    @Test("The available level is clamped to 0...100")
    func availableClamped() {
        let counts = VMPageCounts(internalPages: 0, wiredPages: 0, compressorPages: 0, externalPages: 0, purgeablePages: 0)
        let high = MemoryMath.stats(counts: counts, pageSize: 1, totalBytes: 1, swapUsedBytes: 0, pressureLevel: 1, availableLevel: 140)
        let low = MemoryMath.stats(counts: counts, pageSize: 1, totalBytes: 1, swapUsedBytes: 0, pressureLevel: 1, availableLevel: -3)
        #expect(high.availableLevel == 100)
        #expect(low.availableLevel == 0)
    }
}

/// Smoke test of the syscall wrapper on this Mac. The math is covered by fixtures above.
@Suite("Memory sampler (live)")
struct MemorySamplerTests {
    @Test("Reads plausible figures")
    func plausible() async throws {
        let stats = try await MemorySampler().sample()
        #expect(stats.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(stats.usedBytes > 0)
        #expect(stats.usedBytes <= stats.totalBytes)
        #expect(stats.wiredBytes > 0)
        #expect(stats.appBytes + stats.wiredBytes + stats.compressedBytes == stats.usedBytes)
        #expect((0 ... 100).contains(stats.availableLevel))
        // Pages are 16 KB on Apple silicon, so every figure is a multiple of 16384.
        #expect(stats.wiredBytes % 16384 == 0)
    }
}
