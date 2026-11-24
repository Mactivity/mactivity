import Core
import Foundation
@testable import Sampling
import Testing

struct DiskFixture: Decodable {
    let elapsedSeconds: Double
    /// JSON object keys are strings; the sampler keys by registry entry ID.
    let previous: [String: BlockCounters]
    let current: [String: BlockCounters]
    let expectedReadBPS: Double
    let expectedWriteBPS: Double

    static func byID(_ counters: [String: BlockCounters]) -> [UInt64: BlockCounters] {
        Dictionary(uniqueKeysWithValues: counters.compactMap { key, value in UInt64(key).map { ($0, value) } })
    }
}

@Suite("Disk math")
struct DiskMathTests {
    let fixture: DiskFixture
    let raw: [String: Any]

    init() throws {
        fixture = try Fixtures.load("disk-block-counters-m5pro.json")
        raw = try JSONFixture.object("disk-block-counters-m5pro.json")
    }

    @Test("Throughput is the per-driver delta over elapsed time; new and vanished drivers add nothing")
    func throughput() {
        let rates = DiskMath.throughput(
            previous: DiskFixture.byID(fixture.previous),
            current: DiskFixture.byID(fixture.current),
            elapsedSeconds: fixture.elapsedSeconds
        )
        #expect(rates.readBPS == fixture.expectedReadBPS)
        #expect(rates.writeBPS == fixture.expectedWriteBPS)
    }

    @Test("The first reading is 0 B/s")
    func firstReading() {
        let rates = DiskMath.throughput(previous: nil, current: DiskFixture.byID(fixture.current), elapsedSeconds: 0)
        #expect(rates.readBPS == 0)
        #expect(rates.writeBPS == 0)
    }

    @Test("A counter going backwards (disk ejected and replaced) is 0 for that tick, per direction")
    func backwards() {
        let before: [UInt64: BlockCounters] = [1: BlockCounters(bytesRead: 5000, bytesWritten: 1000)]
        let after: [UInt64: BlockCounters] = [1: BlockCounters(bytesRead: 100, bytesWritten: 3000)]
        let rates = DiskMath.throughput(previous: before, current: after, elapsedSeconds: 1)
        #expect(rates.readBPS == 0)
        #expect(rates.writeBPS == 2000)
    }

    @Test("No elapsed time is 0 B/s, not infinity")
    func noElapsedTime() {
        let counters: [UInt64: BlockCounters] = [1: BlockCounters(bytesRead: 1, bytesWritten: 1)]
        let more: [UInt64: BlockCounters] = [1: BlockCounters(bytesRead: 100, bytesWritten: 100)]
        let rates = DiskMath.throughput(previous: counters, current: more, elapsedSeconds: 0)
        #expect(rates.readBPS == 0)
        #expect(rates.writeBPS == 0)
    }

    @Test("Counters come from a real driver's Statistics dictionary")
    func countersFromStatistics() throws {
        let statistics = try #require(raw["nvmeStatistics"] as? [String: Any])
        #expect(DiskMath.counters(statistics: statistics) == BlockCounters(
            bytesRead: 670_544_699_392, bytesWritten: 699_461_193_728, reads: 20_894_120, writes: 40_628_668
        ))
        #expect(DiskMath.counters(statistics: ["Bytes (Read)": 5]) == nil)
    }

    @Test("Disk images are recognised by their Virtual Interface interconnect")
    func diskImages() throws {
        let characteristics = try #require(raw["protocolCharacteristics"] as? [String: [String: Any]])
        #expect(!DiskMath.isVirtual(protocolCharacteristics: characteristics["nvme"]))
        #expect(!DiskMath.isVirtual(protocolCharacteristics: characteristics["sdCard"]))
        #expect(DiskMath.isVirtual(protocolCharacteristics: characteristics["diskImage"]))
        #expect(DiskMath.isVirtual(protocolCharacteristics: characteristics["diskImageInKernel"]))
        #expect(!DiskMath.isVirtual(protocolCharacteristics: nil))
    }

    @Test("The boot volume comes first, then the rest by name in Finder order")
    func volumeOrder() {
        func volume(_ id: String, _ name: String) -> VolumeStats {
            VolumeStats(id: id, name: name, totalBytes: 100, freeBytes: 50)
        }
        let volumes = [volume("c", "Backup 10"), volume("boot", "Macintosh HD"), volume("a", "archive"), volume("b", "Backup 9")]
        let ordered = DiskMath.ordered(volumes, bootID: "boot")
        #expect(ordered.map(\.name) == ["Macintosh HD", "archive", "Backup 9", "Backup 10"])
        #expect(DiskMath.ordered(volumes, bootID: nil).map(\.name) == ["archive", "Backup 9", "Backup 10", "Macintosh HD"])
    }

    @Test("Between full reads, important-usage free space moves with available capacity")
    func freeBytesTracking() {
        // Real "/" figures from the M5 Pro: 721409559968 important, 704143114240 available.
        let total: UInt64 = 994_610_155_520
        let important: UInt64 = 721_409_559_968
        let available: UInt64 = 704_143_114_240
        // 1 GB written since the full read.
        #expect(
            DiskMath.freeBytes(
                importantAtBaseline: important, availableAtBaseline: available,
                availableNow: available - 1_000_000_000, totalBytes: total
            ) == important - 1_000_000_000
        )
        // 2 GB deleted.
        #expect(
            DiskMath.freeBytes(
                importantAtBaseline: important, availableAtBaseline: available,
                availableNow: available + 2_000_000_000, totalBytes: total
            ) == important + 2_000_000_000
        )
        // No fresh reading: the baseline stands.
        #expect(
            DiskMath.freeBytes(importantAtBaseline: important, availableAtBaseline: available, availableNow: nil, totalBytes: total)
                == important
        )
        // No important figure: plain available capacity.
        #expect(DiskMath.freeBytes(importantAtBaseline: nil, availableAtBaseline: 5, availableNow: 7, totalBytes: total) == 7)
        // Clamped to 0...total.
        #expect(DiskMath.freeBytes(importantAtBaseline: 10, availableAtBaseline: 100, availableNow: 0, totalBytes: total) == 0)
        #expect(DiskMath.freeBytes(importantAtBaseline: 90, availableAtBaseline: 0, availableNow: 50, totalBytes: 100) == 100)
    }
}

/// Smoke test of the FileManager and IORegistry wrappers on this Mac.
@Suite("Disk sampler (live)")
struct DiskSamplerTests {
    @Test("Lists the boot volume first and reports non-negative throughput")
    func plausible() async throws {
        let sampler = DiskSampler()
        let first = try await sampler.sample()
        #expect(first.readBPS == 0)
        #expect(first.writeBPS == 0)
        try await Task.sleep(for: .milliseconds(200))
        let stats = try await sampler.sample()
        let boot = try #require(stats.bootVolume)
        #expect(boot.totalBytes > 0)
        #expect(boot.freeBytes <= boot.totalBytes)
        #expect(boot.freeBytes > 0)
        #expect(stats.readBPS >= 0)
        #expect(stats.writeBPS >= 0)
        // Well under what an internal SSD can do (~10 GB/s): a sign deltas aren't since-boot totals.
        #expect(stats.readBPS < 20e9)
        #expect(stats.writeBPS < 20e9)
    }

    @Test("statfs available space matches URL resource values within 1%")
    func statfsMatchesFoundation() throws {
        let fromStatfs = try #require(DiskSampler.availableBytes("/"))
        let fromURL = try #require(URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity)
        let difference = abs(Double(fromStatfs) - Double(fromURL))
        #expect(difference <= Double(fromURL) * 0.01)
        #expect(DiskSampler.availableBytes("/no/such/volume") == nil)
    }
}
