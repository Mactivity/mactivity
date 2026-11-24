@testable import Alerts
import Core
import Foundation
import Testing

@Suite("Your week, on your day (D-273)")
struct WeeklySummaryDayTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// Monday 2026-09-28 00:00 UTC.
    private let monday = Date(timeIntervalSince1970: 1_790_553_600)
    private let hour: TimeInterval = 3600
    private let dayLength: TimeInterval = 86400

    /// The sends a schedule makes over `days`, checked every 10 minutes from `start`, from a last
    /// summary at `lastSent`; the day changes to `to` at `changedAt`.
    private func sends(
        from start: Date, days: Double, lastSent: Date?, from old: WeeklySummaryDay = .monday, to new: WeeklySummaryDay, changedAt: Date,
        every step: TimeInterval = 600
    ) -> [Date] {
        var sent: [Date] = []
        var last = lastSent
        var now = start
        while now < start + days * dayLength {
            let isChanged = now >= changedAt
            if Digest.isWeeklyDue(
                now: now, lastSent: last, day: isChanged ? new : old, changedAt: isChanged ? changedAt : nil, calendar: calendar
            ) {
                sent.append(now)
                last = now
            }
            now += step
        }
        return sent
    }

    @Test("Each day's due time: 9 am, and Sunday evening at 6")
    func dueTimes() {
        let wednesday = monday + 2 * dayLength + 12 * hour
        #expect(Digest.weeklyDueTime(atOrBefore: wednesday, day: .monday, calendar: calendar) == monday + 9 * hour)
        #expect(Digest.weeklyDueTime(atOrBefore: wednesday, day: .wednesday, calendar: calendar) == monday + 2 * dayLength + 9 * hour)
        #expect(Digest.weeklyDueTime(atOrBefore: wednesday, day: .thursday, calendar: calendar) == monday - 4 * dayLength + 9 * hour)
        #expect(Digest.weeklyDueTime(atOrBefore: wednesday, day: .sundayEvening, calendar: calendar) == monday - dayLength + 18 * hour)
        #expect(Digest.weeklyDueTime(atOrBefore: wednesday, day: .sunday, calendar: calendar) == monday - dayLength + 9 * hour)
    }

    @Test("Which seven days: Monday morning's are Monday to Sunday; Sunday evening's are the same week up to 6 pm")
    func coverage() {
        let sundayEvening = monday + 6 * dayLength + 18 * hour
        let eveningEnd = Digest.weeklyReportEnd(due: sundayEvening, day: .sundayEvening, calendar: calendar)
        #expect(eveningEnd == sundayEvening)
        let evening = WeeklyReport.days(ending: eveningEnd, calendar: calendar)
        #expect(evening.first?.start == monday)
        #expect(evening.last?.end == sundayEvening)
        #expect(evening.count == 7)

        let mondayMorning = monday + 7 * dayLength + 9 * hour
        let morningEnd = Digest.weeklyReportEnd(due: mondayMorning, day: .monday, calendar: calendar)
        #expect(morningEnd == monday + 7 * dayLength)
        let morning = WeeklyReport.days(ending: morningEnd, calendar: calendar)
        // The same Monday: going out on Sunday evening or Monday morning, it's the same week.
        #expect(morning.first?.start == monday)
        #expect(morning.last?.end == monday + 7 * dayLength)

        // Any other morning: the seven whole days before it, none of that morning.
        let thursday = monday + 3 * dayLength + 9 * hour
        let thursdayEnd = Digest.weeklyReportEnd(due: thursday, day: .thursday, calendar: calendar)
        let thursdayDays = WeeklyReport.days(ending: thursdayEnd, calendar: calendar)
        #expect(thursdayDays.first?.start == monday - 4 * dayLength)
        #expect(thursdayDays.last?.end == monday + 3 * dayLength)
    }

    @Test("A Mac asleep at the due time sends it at the next chance, about the same seven days")
    func asleep() {
        let due = monday + 6 * dayLength + 18 * hour
        let lastSent = due - 7 * dayLength
        // Asleep through Sunday evening and woken on Monday morning.
        let woke = due + 14 * hour
        #expect(Digest.isWeeklyDue(now: woke, lastSent: lastSent, day: .sundayEvening, calendar: calendar))
        let dueThen = Digest.weeklyDueTime(atOrBefore: woke, day: .sundayEvening, calendar: calendar)
        #expect(dueThen == due)
        #expect(!Digest.isWeeklyDue(now: woke + hour, lastSent: woke, day: .sundayEvening, calendar: calendar))
        // Off for a week and more: one summary, the latest.
        #expect(Digest.isWeeklyDue(now: due + 10 * dayLength, lastSent: lastSent, day: .sundayEvening, calendar: calendar))
        #expect(Digest.weeklyDueTime(atOrBefore: due + 10 * dayLength, day: .sundayEvening, calendar: calendar) == due + 7 * dayLength)
    }

    @Test("A week without changing the day: exactly one, on time")
    func steady() {
        let sent = sends(
            from: monday, days: 21, lastSent: monday - dayLength + 18 * hour, from: .sundayEvening, to: .sundayEvening,
            changedAt: .distantFuture
        )
        #expect(sent == [
            monday + 6 * dayLength + 18 * hour,
            monday + 13 * dayLength + 18 * hour,
            monday + 20 * dayLength + 18 * hour,
        ])
    }

    @Test("Sunday evening's just gone out, then choosing Monday: no second one the next morning")
    func noDoubleSundayToMonday() {
        let sunday = monday + 6 * dayLength + 18 * hour
        let nextMonday = monday + 7 * dayLength
        // Changed on Monday at 10, after Monday's 9 am has already passed.
        let sent = sends(
            from: sunday + hour, days: 16, lastSent: sunday, from: .sundayEvening, to: .monday, changedAt: nextMonday + 10 * hour
        )
        #expect(sent == [nextMonday + 7 * dayLength + 9 * hour, nextMonday + 14 * dayLength + 9 * hour])
        // Changed on Sunday night, before it.
        let early = sends(from: sunday + hour, days: 14, lastSent: sunday, from: .sundayEvening, to: .monday, changedAt: sunday + 2 * hour)
        #expect(early.first == nextMonday + 7 * dayLength + 9 * hour)
    }

    @Test("Monday's just gone out, then choosing Tuesday: not the very next day, and not never")
    func noDoubleMondayToTuesday() {
        let sentAt = monday + 9 * hour
        let sent = sends(from: sentAt, days: 16, lastSent: sentAt, to: .tuesday, changedAt: sentAt + hour)
        #expect(sent.first == monday + 8 * dayLength + 9 * hour)
        #expect(sent.count == 2)
    }

    @Test("Choosing a day that has just passed still sends this week's, rather than none")
    func noNone() {
        let lastMonday = monday + 9 * hour
        // Just before next Monday's would go out, choosing Sunday evening: yesterday's counts.
        let changedAt = lastMonday + 7 * dayLength - 30 * 60
        let sent = sends(from: changedAt, days: 8, lastSent: lastMonday, to: .sundayEvening, changedAt: changedAt)
        #expect(sent.first == changedAt)
        // And the week after is on time, not another straight away.
        #expect(sent.dropFirst().first == monday + 13 * dayLength + 18 * hour)
    }

    @Test("Whatever day is chosen, whenever: never two within the gap, never more than the gap plus a week without one")
    func anyChange() {
        for old in WeeklySummaryDay.allCases {
            for new in WeeklySummaryDay.allCases where new != old {
                // Every 13 hours through a week, so changing before and after each day's due time.
                for offset in stride(from: 0.0, to: 7 * dayLength, by: 13 * hour) {
                    let lastSent = Digest.weeklyDueTime(atOrBefore: monday + 7 * dayLength, day: old, calendar: calendar) ?? monday
                    let changedAt = lastSent + hour + offset
                    let sent = sends(
                        from: lastSent + 600, days: 30, lastSent: lastSent, from: old, to: new, changedAt: changedAt, every: 3600
                    )
                    let all = [lastSent] + sent
                    for (first, second) in zip(all, all.dropFirst()) {
                        let gap = second.timeIntervalSince(first)
                        #expect(gap >= Digest.weeklyGapAfterChange, "\(old) to \(new) at +\(offset / hour) h: \(gap / hour) h")
                        #expect(gap <= 11 * dayLength + hour, "\(old) to \(new) at +\(offset / hour) h: \(gap / dayLength) days")
                    }
                    #expect(sent.count >= 3, "\(old) to \(new) at +\(offset / hour) h: only \(sent.count) in 30 days")
                }
            }
        }
    }

    @Test("A clock set back still sends, and the first summary ever waits for its day")
    func edges() {
        #expect(Digest.isWeeklyDue(now: monday + 9 * hour, lastSent: monday + 400 * hour, day: .friday, calendar: calendar))
        let friday = monday + 4 * dayLength
        #expect(!Digest.isWeeklyDue(now: friday + 8 * hour, lastSent: nil, day: .friday, calendar: calendar))
        #expect(Digest.isWeeklyDue(now: friday + 9 * hour, lastSent: nil, day: .friday, calendar: calendar))
        #expect(!Digest.isWeeklyDue(now: friday + dayLength + 10 * hour, lastSent: nil, day: .friday, calendar: calendar))
    }

    private func report(end: Date) -> WeeklyReport {
        let days = WeeklyReport.days(ending: end, calendar: calendar)
        return WeeklyReport(
            start: days.first?.start ?? end, end: end, activeSeconds: 20 * 3600, previousActiveSeconds: nil, topApps: [],
            averageSleepSeconds: nil, dataBytes: 0, writtenBytes: 0, crashes: 0, busiestDay: nil, charges: nil
        )
    }

    @Test("The title says which days it is")
    func titles() throws {
        let sunday = monday + 6 * dayLength + 18 * hour
        let evening = try #require(Digest.weekly(report(end: sunday), day: .sundayEvening, sentAt: sunday, calendar: calendar))
        #expect(evening.title == "Your Mac this week")
        // Sent on Monday after a night asleep, it's not this week any more.
        let late = try #require(Digest.weekly(report(end: sunday), day: .sundayEvening, sentAt: sunday + 14 * hour, calendar: calendar))
        #expect(late.title != "Your Mac this week")
        #expect(late.title.contains("Sep 28"))

        let nextMonday = monday + 7 * dayLength
        let usual = try #require(Digest.weekly(report(end: nextMonday), day: .monday, sentAt: nextMonday + 9 * hour, calendar: calendar))
        #expect(usual.title == "Your Mac last week")

        let thursdayEnd = monday + 3 * dayLength
        let other = try #require(
            Digest.weekly(report(end: thursdayEnd), day: .thursday, sentAt: thursdayEnd + 9 * hour, calendar: calendar)
        )
        // Thursday Sep 24 to Wednesday Sep 30: the last day is Wednesday's, not Thursday's.
        #expect(other.title.contains("24"))
        #expect(other.title.contains("30"))
        #expect(!other.title.contains("Oct"))
    }

    @Test("The picker starts on the Mac's first day, with Sunday evening after Sunday")
    func offered() {
        var calendar = calendar
        calendar.firstWeekday = 2
        let days = WeeklySummaryDay.offered(calendar: calendar)
        #expect(days.first == .monday)
        #expect(days.suffix(2) == [.sunday, .sundayEvening])
        #expect(days.count == WeeklySummaryDay.allCases.count)
        calendar.firstWeekday = 1
        #expect(Array(WeeklySummaryDay.offered(calendar: calendar).prefix(3)) == [.sunday, .sundayEvening, .monday])
    }
}
