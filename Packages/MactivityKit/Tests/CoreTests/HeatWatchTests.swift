import Core
import Foundation
import Testing

@Suite("Hot minutes for the overheating alert (D-149)")
struct HeatWatchTests {
    private let start = Date(timeIntervalSince1970: 1_790_600_000)

    @Test("Every 10 s, hot for 6 minutes: 6 hot minutes")
    func counts() {
        var watch = HeatWatch()
        var minutes = 0.0
        for step in 0 ... 60 {
            minutes = watch.record(step < 36 ? .serious : .nominal, at: start + Double(step * 10))
        }
        #expect(abs(minutes - 6) < 0.01)
    }

    @Test("Only the last 10 minutes count")
    func window() {
        var watch = HeatWatch()
        for step in 0 ..< 60 {
            _ = watch.record(.critical, at: start + Double(step * 10))
        }
        let later = watch.record(.nominal, at: start + 1200)
        #expect(later < 0.01)
    }

    @Test("A gap (sleep) counts as a minute at most, and fair isn't hot")
    func gap() {
        var watch = HeatWatch()
        _ = watch.record(.serious, at: start)
        #expect(abs(watch.record(.nominal, at: start + 500) - 1) < 0.01)
        var fair = HeatWatch()
        _ = fair.record(.fair, at: start)
        #expect(fair.record(.fair, at: start + 60) == 0)
    }
}
