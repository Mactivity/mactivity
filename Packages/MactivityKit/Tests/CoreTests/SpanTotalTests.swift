import Core
import Foundation
import Testing

@Suite("Span totals from history and the startup counters (D-112)")
struct SpanTotalTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var boot: Date {
        now.addingTimeInterval(-14 * 86400)
    }

    @Test("A span that began before startup: the counter since startup, plus history before it")
    func beforeBoot() {
        let start = now.addingTimeInterval(-30 * 86400)
        let total = SpanTotal.combine(
            spanStart: start, boot: boot, sinceStartup: 1_200_000_000_000, historyBeforeBoot: 3e11, historySinceStart: 1.4e12,
            firstRecorded: start.addingTimeInterval(-86400)
        )
        #expect(total == SpanTotal(value: 1.5e12, isLowerBound: false))
    }

    @Test("A fresh install: the counter is still exact since startup, so the figure is at least that")
    func freshInstall() {
        let start = now.addingTimeInterval(-365 * 86400)
        let total = SpanTotal.combine(
            spanStart: start, boot: boot, sinceStartup: 1_200_000_000_000, historyBeforeBoot: 0, historySinceStart: 1e9,
            firstRecorded: now.addingTimeInterval(-600)
        )
        #expect(total == SpanTotal(value: 1.2e12, isLowerBound: true))
    }

    @Test("A span that began after startup is history alone, never above the counter")
    func afterBoot() {
        let today = now.addingTimeInterval(-8 * 3600)
        let covered = SpanTotal.combine(
            spanStart: today, boot: boot, sinceStartup: 1_200_000_000_000, historyBeforeBoot: 0, historySinceStart: 1.6e11,
            firstRecorded: boot
        )
        #expect(covered == SpanTotal(value: 1.6e11, isLowerBound: false))
        let fresh = SpanTotal.combine(
            spanStart: today, boot: boot, sinceStartup: 1_200_000_000_000, historyBeforeBoot: 0, historySinceStart: 2e9,
            firstRecorded: now.addingTimeInterval(-600)
        )
        #expect(fresh == SpanTotal(value: 2e9, isLowerBound: true))
        #expect(SpanTotal.combine(
            spanStart: today, boot: boot, sinceStartup: 1_000_000_000, historyBeforeBoot: 0, historySinceStart: 2e9, firstRecorded: boot
        ).value == 1e9)
    }

    @Test("A real counter is read as bytes, not as a bit pattern (Today and 7 days read 0 B)")
    func counterIsBytes() {
        // The simulated Mac's counter and the history the Disk tab found for today.
        let today = now.addingTimeInterval(-8 * 3600)
        let total = SpanTotal.combine(
            spanStart: today, boot: boot, sinceStartup: 972_826_000_000, historyBeforeBoot: 0, historySinceStart: 15_876_274_438,
            firstRecorded: boot
        )
        #expect(total == SpanTotal(value: 15_876_274_438, isLowerBound: false))
        let month = SpanTotal.combine(
            spanStart: now.addingTimeInterval(-30 * 86400), boot: boot, sinceStartup: 972_826_000_000,
            historyBeforeBoot: 936_508_590_396, historySinceStart: 1_348_602_339_111, firstRecorded: boot.addingTimeInterval(-30 * 86400)
        )
        #expect(month.value == 936_508_590_396 + 972_826_000_000)
    }

    @Test("Without the counter, history alone; with no history at all, a lower bound")
    func noCounter() {
        let start = now.addingTimeInterval(-7 * 86400)
        #expect(SpanTotal.combine(
            spanStart: start, boot: boot, sinceStartup: nil, historyBeforeBoot: 0, historySinceStart: 5e10, firstRecorded: nil
        ) == SpanTotal(value: 5e10, isLowerBound: true))
    }
}
