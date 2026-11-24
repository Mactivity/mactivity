@testable import Core
import Foundation
import Testing

@Suite("Power over a range (D-258)")
struct PowerSummaryTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func point(_ minutes: Double, _ average: Double, _ maximum: Double) -> SeriesPoint {
        SeriesPoint(at: start.addingTimeInterval(minutes * 60), average: average, maximum: maximum)
    }

    @Test("Average of the readings, peak of their highs")
    func averageAndPeak() throws {
        let summary = try #require(PowerSummary.read(
            [point(0, 6000, 9000), point(15, 10000, 31000), point(30, 8000, 12000)],
            rangeStart: start
        ))
        #expect(summary.averageMW == 8000)
        #expect(summary.peakMW == 31000)
        #expect(summary.since == nil)
    }

    @Test("Nothing recorded, no summary; points before the range and zeros are left out")
    func empty() {
        #expect(PowerSummary.read([], rangeStart: start) == nil)
        #expect(PowerSummary.read([point(-10, 9000, 9000), point(5, 0, 0)], rangeStart: start) == nil)
    }

    @Test("Recording that began inside the range says since when")
    func lateStart() throws {
        let summary = try #require(PowerSummary.read([point(120, 7000, 7000)], rangeStart: start))
        #expect(summary.since == start.addingTimeInterval(7200))
    }
}
