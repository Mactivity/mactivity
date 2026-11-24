import Core
import Foundation

/// Reads a month or a year of History into a `PeriodRecap` (D-254). Everything comes from what's
/// already recorded; a year is about 380 small reads, under a second.
@MainActor
enum LookingBackLoader {
    static func load(
        _ services: AppServices, span: PeriodRecap.Span, containing date: Date, now: Date = Date()
    ) async -> PeriodRecap {
        let calendar = Calendar.current
        let interval = LookingBack.interval(span, containing: date, now: now)
        let previous = LookingBack.previous(span, before: interval)
        let history = services.history
        let focus = history as? any FocusStore
        let daily = history as? any DailyHistoryStore
        let first = await (try? focus?.firstFocus()).flatMap(\.self)
        // The span before counts only when History covers all of it.
        let coversPrevious = first.map { $0 <= previous.start } ?? false
        let active = await (try? focus?.activeSeconds(from: interval.start, to: interval.end)) ?? 0
        let previousActive = coversPrevious ? await (try? focus?.activeSeconds(from: previous.start, to: previous.end)) : nil
        let top = await (try? focus?.focusTotals(from: interval.start, to: interval.end, limit: 200)) ?? []
        var change: (came: [AppTotal], went: [AppTotal]) = ([], [])
        if coversPrevious {
            let before = await (try? focus?.focusTotals(from: previous.start, to: previous.end, limit: 200)) ?? []
            change = LookingBack.cameAndWent(current: top, previous: before)
        }
        let days = await activeByDay(focus, interval, calendar: calendar)
        let months = span == .year ? await activeByMonth(focus, interval, calendar: calendar) : []
        let rows = await (try? (history as? any AgentHistoryStore)?.agentUsage(from: interval.start, to: interval.end)) ?? []
        let agents = LookingBack.agents(rows)
        var crashes: Int?
        if span == .month {
            let reports = await CrashFilter.relevant(services.crashReports.reports(since: interval.start))
            crashes = reports.count { interval.contains($0.at) }
        }
        let notes = await (try? (history as? any NoteStore)?.notes(from: interval.start, to: interval.end))?.count ?? 0
        return await PeriodRecap(
            span: span, interval: interval, activeSeconds: active, previousActiveSeconds: previousActive,
            busiestDays: LookingBack.busiest(days), busiestMonth: LookingBack.busiest(months, count: 1).first,
            topApps: Array(top.prefix(5)), came: change.came, went: change.went,
            agentSeconds: agents.seconds, topAgentProject: agents.project,
            slowdowns: slowdowns(daily, interval),
            crashes: crashes,
            dataBytes: (try? daily?.systemTotal(metrics: [.netIn, .netOut], from: interval.start, to: interval.end)) ?? 0,
            writtenBytes: (try? daily?.systemTotal(metrics: [.diskWrite], from: interval.start, to: interval.end)) ?? 0,
            notes: notes,
            recordingSince: first.flatMap { $0 > interval.start ? $0 : nil }
        )
    }

    private static func activeByDay(_ focus: (any FocusStore)?, _ interval: DateInterval, calendar: Calendar) async -> [DayTotal] {
        guard let focus else {
            return []
        }
        var totals: [DayTotal] = []
        var day = interval.start
        while day < interval.end {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
            let seconds = await (try? focus.activeSeconds(from: day, to: min(next, interval.end))) ?? 0
            totals.append(DayTotal(day: day, seconds: seconds))
            day = next
        }
        return totals
    }

    private static func activeByMonth(_ focus: (any FocusStore)?, _ interval: DateInterval, calendar: Calendar) async -> [DayTotal] {
        guard let focus else {
            return []
        }
        var totals: [DayTotal] = []
        var month = interval.start
        while month < interval.end {
            let next = calendar.date(byAdding: .month, value: 1, to: month) ?? month.addingTimeInterval(31 * 86400)
            let seconds = await (try? focus.activeSeconds(from: month, to: min(next, interval.end))) ?? 0
            totals.append(DayTotal(day: month, seconds: seconds))
            month = next
        }
        return totals
    }

    /// Slowdowns from the whole Mac's series (D-169), at the resolution History keeps for the span:
    /// quarter-hours for a recent month, hours for a year.
    private static func slowdowns(_ daily: (any DailyHistoryStore)?, _ interval: DateInterval) async -> Int {
        guard let daily else {
            return 0
        }
        let cpu = await (try? daily.series(metric: .cpu, app: nil, from: interval.start, to: interval.end)) ?? []
        let memory = await (try? daily.series(metric: .memoryPressure, app: nil, from: interval.start, to: interval.end)) ?? []
        let thermal = await (try? daily.series(metric: .thermalPressure, app: nil, from: interval.start, to: interval.end)) ?? []
        // The spacing of the points: the smallest gap among the first few, as a gap may be a sleep.
        let bucket = zip(cpu.prefix(20), cpu.prefix(20).dropFirst()).map { $1.at.timeIntervalSince($0.at) }.min() ?? 3600
        return SlowSpells.find(cpu: cpu, memoryPressure: memory, thermal: thermal, bucket: max(60, bucket)).count
    }
}
