@testable import Core
import Foundation
import Testing

/// The days before an update beside the days after (D-206).
struct UpdateImpactTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private func date(_ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour)) ?? Date()
    }

    private func days(_ values: [Int: Double]) -> [DayValue] {
        values.map { DayValue(day: date($0.key), average: $0.value, maximum: $0.value) }
    }

    private var chrome: InstalledUpdate {
        let app = AppIdentity(id: "com.google.Chrome", name: "Chrome", bundleID: nil, iconKey: "x", kind: .app)
        return InstalledUpdate(app: app, name: "Chrome", version: "155.0", installedAt: date(8, hour: 14))
    }

    @Test("A third more memory after the update is notable and heavier; the update's own day is left out")
    func heavier() throws {
        let memory = days([3: 1.2e9, 5: 1.2e9, 7: 1.3e9, 8: 9e9, 9: 1.6e9, 10: 1.6e9, 12: 1.7e9])
        let cpu = days([3: 4, 5: 4.2, 7: 4.1, 9: 4.3, 10: 4, 12: 4.2])
        let impact = try #require(UpdateComparison.impact(chrome, daily: [.memory: memory, .cpu: cpu], now: date(15), calendar: calendar))
        #expect(impact.daysBefore == 3 && impact.daysAfter == 3)
        #expect(impact.notable?.metric == .memory)
        #expect(impact.notable?.before == 1.2e9 && impact.notable?.after == 1.6e9)
        #expect(impact.isHeavier)
    }

    @Test("Small changes, or ones under the floor, aren't notable")
    func aboutTheSame() throws {
        let cpu = days([5: 0.8, 6: 0.8, 9: 0.4, 10: 0.4])
        let memory = days([5: 1.0e9, 6: 1.0e9, 9: 1.1e9, 10: 1.1e9])
        let impact = try #require(UpdateComparison.impact(chrome, daily: [.cpu: cpu, .memory: memory], now: date(15), calendar: calendar))
        #expect(impact.notable == nil, "half the processor, but under a percent; 10% more memory")
    }

    @Test("Nothing to say until two days of use on each side, never counting today")
    func waits() {
        let memory = days([5: 1e9, 6: 1e9, 9: 2e9, 10: 2e9])
        #expect(UpdateComparison.impact(chrome, daily: [.memory: memory], now: date(10, hour: 12), calendar: calendar) == nil)
        #expect(UpdateComparison.impact(chrome, daily: [.memory: memory], now: date(11), calendar: calendar) != nil)
        // Days more than a week before don't count.
        let september = [29, 30].compactMap { calendar.date(from: DateComponents(year: 2026, month: 9, day: $0)) }
        let old = september.map { DayValue(day: $0, average: 1e9, maximum: 1e9) } + days([9: 2e9, 10: 2e9])
        #expect(UpdateComparison.impact(chrome, daily: [.memory: old], now: date(15), calendar: calendar) == nil)
    }

    @Test("The span to read: a week before the update's day to a week after, not past today")
    func span() {
        let span = UpdateComparison.span(chrome, now: date(11, hour: 9), calendar: calendar)
        #expect(span?.start == date(1))
        #expect(span?.end == date(11))
    }

    @Test("Not compared yet: waits during its week after, if history goes back before it")
    func mayCompare() {
        #expect(UpdateComparison.mayCompare(chrome, firstRecorded: date(1), now: date(11), calendar: calendar))
        #expect(!UpdateComparison.mayCompare(chrome, firstRecorded: date(1), now: date(20), calendar: calendar), "its week is over")
        #expect(!UpdateComparison.mayCompare(chrome, firstRecorded: date(7), now: date(11), calendar: calendar), "no history before it")
        #expect(!UpdateComparison.mayCompare(chrome, firstRecorded: nil, now: date(11), calendar: calendar))
    }
}
