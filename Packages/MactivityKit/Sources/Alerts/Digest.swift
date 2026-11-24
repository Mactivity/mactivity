import Core
import Foundation
import UserNotifications

/// The "while you were away" digest (expansion E2): one notification a day summarizing the
/// busiest apps and the alerts that fired. Pure text building here; scheduling is the app's.
public enum Digest {
    public struct Content: Equatable, Sendable {
        public let title: String
        public let body: String
    }

    /// Nil when nothing is worth a notification (no app stood out and no alerts fired).
    public static func content(
        topCPU: [AppTotal],
        topMemory: [AppTotal],
        topNetwork: [AppTotal],
        alerts: [Alert],
        locale: Locale = .current
    ) -> Content? {
        var lines: [String] = []
        // "Stood out": averaged at least 5% of the machine, or the heaviest memory user.
        if let cpu = topCPU.first(where: { $0.app.kind != .system && $0.value >= 5 }) {
            let percent = Formatters.percent(cpu.value, locale: locale)
            lines.append(String(
                localized: "Busiest: \(cpu.app.name), \(percent) CPU on average.", bundle: .strings,
                comment: "Daily digest. The arguments are an app name and a percent."
            ))
        }
        if let memory = topMemory.first(where: { $0.app.kind != .system }) {
            let amount = Formatters.memory(memory.value, locale: locale)
            lines.append(String(
                localized: "Most memory: \(memory.app.name), \(amount).", bundle: .strings,
                comment: "Daily digest. The arguments are an app name and an amount of memory."
            ))
        }
        if let network = topNetwork.first(where: { $0.app.kind != .system && $0.value >= 100_000 }) {
            let rate = Formatters.rate(network.value, locale: locale)
            lines.append(String(
                localized: "Most network: \(network.app.name), \(rate) on average.", bundle: .strings,
                comment: "Daily digest. The arguments are an app name and a rate."
            ))
        }
        if !alerts.isEmpty {
            // Sorted and joined as the language does: "iTerm" before "Zoom", "、" in Japanese (D-221).
            let names = Array(Set(alerts.map(\.app.name))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .prefix(3).formatted(.list(type: .and).locale(locale))
            lines.append(String(
                localized: "\(alerts.count) alerts: \(names).", bundle: .strings,
                comment: "Daily digest. The count of alerts, then up to three app names."
            ))
        }
        guard !lines.isEmpty, topCPU.contains(where: { $0.value >= 5 }) || !alerts.isEmpty || topMemory.first != nil else {
            return nil
        }
        let title = String(localized: "Your Mac over the last day", bundle: .strings, comment: "Daily digest notification title.")
        return Content(title: title, body: lines.joined(separator: " "))
    }

    /// Whether today's digest is due: enabled, not yet sent today, and after 7 am local time.
    public static func isDue(now: Date, lastSent: Date?, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.hour, from: now) >= 7 else {
            return false
        }
        guard let lastSent else {
            return true
        }
        return !calendar.isDate(lastSent, inSameDayAs: now)
    }
}

extension NotificationDeliverer {
    /// Posts the digest as a normal, silent notification in its own thread.
    public func deliverDigest(_ content: Digest.Content) async throws {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.threadIdentifier = "app.mactivity.digest"
        notification.userInfo = [AlertDeepLink.metricKey: Metric.cpu.rawValue]
        let request = UNNotificationRequest(identifier: "digest-\(UUID().uuidString)", content: notification, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationDeliverer {
    /// The alerts held while the person presented (1.6), as one notification that opens Alerts.
    public func deliverHeldSummary(title: String, body: String) async throws {
        let notification = UNMutableNotificationContent()
        notification.title = title
        notification.body = body
        notification.threadIdentifier = "app.mactivity.held"
        notification.userInfo = [AlertDeepLink.pageKey: AlertDeepLink.alertsPage]
        let request = UNNotificationRequest(identifier: "held-\(UUID().uuidString)", content: notification, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}

extension Digest {

    // MARK: Weekly (D-102)

    /// The notification about the seven days it covers, on the chosen day (D-273). Nil when the
    /// Mac was in use under an hour, or when time in use only started recording during the week (D-108).
    public static func weekly(
        _ report: WeeklyReport, day: WeeklySummaryDay = .monday, sentAt: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current
    ) -> Content? {
        guard report.activeSeconds >= 3600, report.recordingSince == nil else {
            return nil
        }
        func hours(_ seconds: Double) -> String {
            Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2))
        }
        var lines: [String] = []
        let used = hours(report.activeSeconds)
        if let top = report.topApps.first {
            lines.append(String(
                localized: "In use for \(used), most of it in \(top.app.name).", bundle: .strings,
                comment: "Weekly summary: time the Mac was in use, then the app used most"
            ))
        } else {
            lines.append(String(localized: "In use for \(used).", bundle: .strings, comment: "Weekly summary"))
        }
        if let sleep = report.averageSleepSeconds {
            lines.append(String(localized: "Asleep \(hours(sleep)) a night.", bundle: .strings, comment: "Weekly summary: average sleep"))
        }
        // Agent history (D-192): a line once agents ran an hour or more.
        if let seconds = report.agentSeconds, seconds >= 3600, let top = report.topAgent {
            let agentTime = hours(seconds)
            lines.append(top.project.isEmpty
                ? String(
                    localized: "Agents worked \(agentTime), mostly \(top.agent).", bundle: .strings,
                    comment: "Weekly summary: coding-agent time, then the busiest agent"
                )
                : String(
                    localized: "Agents worked \(agentTime), mostly \(top.agent) in \(top.project).", bundle: .strings,
                    comment: "Weekly summary: coding-agent time, then the busiest agent and its project"
                ))
        }
        if report.crashes > 0 {
            lines.append(String(localized: "Crashes: \(report.crashes).", bundle: .strings, comment: "Weekly summary"))
        }
        return Content(title: weeklyTitle(report, day: day, sentAt: sentAt, calendar: calendar), body: lines.joined(separator: " "))
    }

    /// "Last week" is only true of Monday's seven days. Sunday evening's are this week's until
    /// that Sunday's over; any other seven days say which they are.
    private static func weeklyTitle(_ report: WeeklyReport, day: WeeklySummaryDay, sentAt: Date, calendar: Calendar) -> String {
        if day == .monday {
            return String(localized: "Your Mac last week", bundle: .strings, comment: "Weekly summary notification title")
        }
        if day.isEvening, calendar.isDate(sentAt, inSameDayAs: report.end) {
            return String(
                localized: "Your Mac this week", bundle: .strings,
                comment: "Weekly summary notification title, sent on Sunday evening"
            )
        }
        var style = Date.IntervalFormatStyle.interval.month(.abbreviated).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        // The last moment covered: a week ending at midnight ends on the day before.
        let range = (report.start ..< report.end.addingTimeInterval(-1)).formatted(style)
        return String(
            localized: "Your Mac, \(range)", bundle: .strings,
            comment: "Weekly summary notification title: the seven days it covers, e.g. Oct 29 – Nov 4"
        )
    }

    /// The latest time the chosen day's summary fell due, at or before `now`.
    public static func weeklyDueTime(atOrBefore now: Date, day: WeeklySummaryDay = .monday, calendar: Calendar = .current) -> Date? {
        calendar.nextDate(
            after: now.addingTimeInterval(1), matching: DateComponents(hour: day.hour, minute: 0, second: 0, weekday: day.weekday),
            matchingPolicy: .nextTime, direction: .backward
        )
    }

    /// Where the seven days end (D-273). A morning's summary is about the seven whole days before
    /// it: Monday's is Monday to Sunday. Sunday evening's has that same week up to 6 pm, today
    /// included, and keeps that end if a sleeping Mac sends it on Monday.
    public static func weeklyReportEnd(due: Date, day: WeeklySummaryDay, calendar: Calendar = .current) -> Date {
        day.isEvening ? due : calendar.startOfDay(for: due)
    }

    /// After choosing another day, a summary closer than this to the last one waits a week more:
    /// so Sunday evening's isn't followed by Monday morning's, however the day is changed. Short
    /// of a week, so moving the day a few days later doesn't skip a week either: the longest wait
    /// a change can cause is this plus seven days.
    public static let weeklyGapAfterChange: TimeInterval = 4 * 86400

    /// From the due time until it goes out: a Mac that was off or asleep then sends it the next
    /// chance it gets, rather than skipping the week (D-139). Never sent before: only within a day
    /// of the due time, so a new install doesn't open with a summary of a week it barely saw.
    /// `changedAt` is when the day was last chosen; a due time before that counts too, so choosing
    /// a day that's just passed doesn't lose the week, unless the gap says it's too soon.
    public static func isWeeklyDue(
        now: Date, lastSent: Date?, day: WeeklySummaryDay = .monday, changedAt: Date? = nil, calendar: Calendar = .current
    ) -> Bool {
        guard let due = weeklyDueTime(atOrBefore: now, day: day, calendar: calendar) else {
            return false
        }
        guard let lastSent else {
            return now.timeIntervalSince(due) < 86400
        }
        // Sent "later" than now: the clock was set back since; send rather than wait it out (D-221).
        if lastSent > now {
            return true
        }
        guard lastSent < due else {
            return false
        }
        if let changedAt, changedAt > lastSent {
            return due.timeIntervalSince(lastSent) >= weeklyGapAfterChange
        }
        return true
    }
}
