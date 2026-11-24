@testable import Core
import Foundation
import Testing

/// Each sleep and the battery it used (D-213).
struct SleepDrainTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("A night's sleep used the level before it less the level after; a charge isn't drain; short naps are left out")
    func spans() throws {
        let events = [
            PowerEvent(at: t0, kind: .sleep), PowerEvent(at: t0 + 8 * 3600, kind: .wake, reason: "EC.LidOpen"),
            PowerEvent(at: t0 + 9 * 3600, kind: .sleep), PowerEvent(at: t0 + 9 * 3600 + 600, kind: .wake, reason: "x"),
            PowerEvent(at: t0 + 10 * 3600, kind: .sleep), PowerEvent(at: t0 + 12 * 3600, kind: .wake, reason: "y"),
        ]
        let levels = [
            SeriesPoint(at: t0 - 60, average: 80, maximum: 80), SeriesPoint(at: t0 + 8 * 3600 + 60, average: 68, maximum: 68),
            SeriesPoint(at: t0 + 10 * 3600 - 60, average: 66, maximum: 66), SeriesPoint(at: t0 + 12 * 3600 + 60, average: 90, maximum: 90),
        ]
        let spans = SleepDrain.spans(events, levels: levels)
        #expect(spans.count == 2, "the 10-minute nap is left out")
        let night = try #require(spans.last)
        #expect(night.batteryUsed == 12)
        #expect(night.drainPerHour == 1.5)
        #expect(night.isHeavyDrain)
        #expect(night.wake.reason == "EC.LidOpen")
        #expect(spans.first?.batteryUsed == nil, "it charged")
    }

    @Test("No readings near the sleep, no figure; a light night isn't heavy")
    func edges() {
        let events = [PowerEvent(at: t0, kind: .sleep), PowerEvent(at: t0 + 8 * 3600, kind: .wake)]
        #expect(SleepDrain.spans(events, levels: []).first?.batteryUsed == nil)
        let light = [SeriesPoint(at: t0, average: 80, maximum: 80), SeriesPoint(at: t0 + 8 * 3600, average: 77, maximum: 77)]
        #expect(SleepDrain.spans(events, levels: light).first?.isHeavyDrain == false)
        // 4% in half an hour isn't judged: too short to tell drain from minutes awake.
        let nap = [PowerEvent(at: t0, kind: .sleep), PowerEvent(at: t0 + 1800, kind: .wake)]
        let fast = [SeriesPoint(at: t0, average: 80, maximum: 80), SeriesPoint(at: t0 + 1800, average: 76, maximum: 76)]
        #expect(SleepDrain.spans(nap, levels: fast).first?.isHeavyDrain == false)
    }
}
