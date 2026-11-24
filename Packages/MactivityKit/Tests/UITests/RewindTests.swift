import Foundation
import Testing
@testable import UI

/// Rewind's label for a clicked bar (D-190).
struct RewindTests {
    @Test("A bar inside a day reads as its hours, a day's bar as its date, longer bars as dates")
    func labels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13)) ?? Date()
        let hours = HistoryBin(start: day.addingTimeInterval(14 * 3600), end: day.addingTimeInterval(14.25 * 3600), average: 0, maximum: 0)
        #expect(HistoryStrip.momentLabel(hours) == (hours.start ..< hours.end).formatted(.interval.weekday(.abbreviated).hour().minute()))
        let wholeDay = HistoryBin(start: day, end: day.addingTimeInterval(86400), average: 0, maximum: 0)
        #expect(HistoryStrip.momentLabel(wholeDay) == day.formatted(.dateTime.month(.abbreviated).day()))
        let week = HistoryBin(start: day, end: day.addingTimeInterval(3 * 86400), average: 0, maximum: 0)
        #expect(HistoryStrip.momentLabel(week).contains("–") || HistoryStrip.momentLabel(week).contains("-"))
    }
}
