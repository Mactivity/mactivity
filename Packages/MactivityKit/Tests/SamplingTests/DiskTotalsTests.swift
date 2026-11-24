import Core
import Foundation
@testable import Sampling
import Testing

@Suite("Disk totals (D-097)")
struct DiskTotalsTests {
    @Test("Operation counts come from the driver's Statistics, next to the bytes")
    func counters() throws {
        let reading = try #require(DiskMath.counters(statistics: [
            "Bytes (Read)": NSNumber(value: 972_790_000_000), "Bytes (Write)": NSNumber(value: 1_090_000_000_000),
            "Operations (Read)": NSNumber(value: 33_143_868), "Operations (Write)": NSNumber(value: 56_922_471),
        ]))
        #expect(reading.reads == 33_143_868)
        #expect(reading.writes == 56_922_471)
        let bytesOnly = try #require(DiskMath.counters(statistics: [
            "Bytes (Read)": NSNumber(value: 1),
            "Bytes (Write)": NSNumber(value: 2),
        ]))
        #expect(bytesOnly.reads == nil)
    }

    @Test("Totals add up every disk; operations only when every disk reports them")
    func totals() throws {
        let two: [UInt64: BlockCounters] = [
            1: BlockCounters(bytesRead: 100, bytesWritten: 200, reads: 10, writes: 20),
            2: BlockCounters(bytesRead: 1, bytesWritten: 2, reads: 3, writes: 4),
        ]
        let total = try #require(DiskMath.totals(two))
        #expect(total == DiskTotals(bytesRead: 101, bytesWritten: 202, reads: 13, writes: 24))
        var partial = two
        partial[3] = BlockCounters(bytesRead: 5, bytesWritten: 5)
        #expect(DiskMath.totals(partial)?.reads == nil)
        #expect(DiskMath.totals([:]) == nil)
    }

    @Test("Operations a second between two readings")
    func rates() {
        let before: [UInt64: BlockCounters] = [1: BlockCounters(bytesRead: 0, bytesWritten: 0, reads: 100, writes: 50)]
        let after: [UInt64: BlockCounters] = [1: BlockCounters(bytesRead: 0, bytesWritten: 0, reads: 300, writes: 70)]
        let rates = DiskMath.operations(previous: before, current: after, elapsedSeconds: 2)
        #expect(rates.reads == 100)
        #expect(rates.writes == 10)
    }
}
