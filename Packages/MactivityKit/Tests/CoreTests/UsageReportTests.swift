import Core
import Foundation
import Testing

@Suite("Usage report (D-159)")
struct UsageReportTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("The busiest hour averages its points; a single spike doesn't win")
    func busiestHour() {
        let hourA = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        let hourB = hourA.addingTimeInterval(3600)
        let series = [
            SeriesPoint(at: hourA, average: 100, maximum: 100),
            SeriesPoint(at: hourA.addingTimeInterval(900), average: 10, maximum: 10),
            SeriesPoint(at: hourA.addingTimeInterval(1800), average: 10, maximum: 10),
            SeriesPoint(at: hourB, average: 60, maximum: 70),
            SeriesPoint(at: hourB.addingTimeInterval(900), average: 50, maximum: 55),
        ]
        let busiest = UsageReport.busiestHour(series, calendar: calendar)
        #expect(busiest?.start == hourB)
        #expect(busiest?.average == 55)
        #expect(UsageReport.busiestHour([], calendar: calendar) == nil)
    }

    @Test("Counts: most first, then by name")
    func counts() {
        let counts = UsageReport.counts(["Xcode", "Slack", "Xcode", "Arc", "Slack", "Xcode"])
        #expect(counts.map(\.name) == ["Xcode", "Slack", "Arc"])
        #expect(counts.map(\.count) == [3, 2, 1])
    }

    @Test("Change against the period before needs an hour of it")
    func change() {
        var report = UsageReport(period: .week, start: start, end: start.addingTimeInterval(7 * 86400), mac: nil)
        report.activeSeconds = 7200
        report.previousActiveSeconds = 3600
        #expect(report.activeChange == 1)
        report.previousActiveSeconds = 600
        #expect(report.activeChange == nil)
    }
}
