import Core
import Foundation

/// Fills a `UsageReport` from History, time in front, sleep, the alert log and crash reports
/// (D-159). Every figure is optional: a fresh install or a Mac without a battery leaves gaps,
/// and the report says less rather than guessing.
@MainActor
public enum UsageReportLoader {
    public static func load(
        _ services: AppServices, period: UsageReport.Period, mac: String?, end: Date = Date()
    ) async -> UsageReport {
        let start = end.addingTimeInterval(-Double(period.days) * 86400)
        var report = UsageReport(period: period, start: start, end: end, mac: mac)
        let history = services.history
        let daily = history as? any DailyHistoryStore
        let focus = history as? any FocusStore
        let limit = UsageReport.listLength

        report.activeSeconds = await (try? focus?.activeSeconds(from: start, to: end)) ?? 0
        report.previousActiveSeconds = await (try? focus?.activeSeconds(
            from: start.addingTimeInterval(start.timeIntervalSince(end)),
            to: start
        ))
        report.inFront = await (try? focus?.focusTotals(from: start, to: end, limit: limit)) ?? []

        let cpu = await (try? daily?.series(metric: .cpu, app: nil, from: start, to: end)) ?? []
        if !cpu.isEmpty {
            report.averageCPU = cpu.reduce(0) { $0 + $1.average } / Double(cpu.count)
            report.peakCPU = cpu.map(\.maximum).max()
        }
        if let busiest = UsageReport.busiestHour(cpu) {
            let hourEnd = busiest.start.addingTimeInterval(3600)
            let apps = await (try? daily?.topApps(metric: .cpu, from: busiest.start, to: hourEnd, limit: 3)) ?? []
            report.peak = UsageReport.Peak(start: busiest.start, cpuPercent: busiest.average, apps: apps)
        }
        report.dailyCPU = await (try? daily?.dailyValues(metric: .cpu, days: period.days)) ?? []

        let pressure = await (try? daily?.series(metric: .memoryPressure, app: nil, from: start, to: end)) ?? []
        if !pressure.isEmpty {
            report.averageMemoryPressure = pressure.reduce(0) { $0 + $1.average } / Double(pressure.count)
        }
        let swap = await (try? daily?.series(metric: .swapUsed, app: nil, from: start, to: end)) ?? []
        report.peakSwapBytes = swap.map(\.maximum).max()
        report.writtenBytes = await (try? daily?.systemTotal(metrics: [.diskWrite], from: start, to: end)) ?? 0
        report.networkBytes = await (try? daily?.systemTotal(metrics: [.netIn, .netOut], from: start, to: end)) ?? 0

        report.byCPU = await (try? daily?.topApps(metric: .cpu, from: start, to: end, limit: limit)) ?? []
        report.byMemory = await (try? daily?.topApps(metric: .memory, from: start, to: end, limit: limit)) ?? []
        let energy = await (try? daily?.topApps(metric: .energyImpact, from: start, to: end, limit: 200)) ?? []
        report.byEnergy = Array(HistoryStrip.shares(energy).prefix(limit))

        let events = await (try? (history as? any PowerEventStore)?.powerEvents(days: period.days + 1)) ?? []
        report.averageSleepSeconds = WeeklyReport.averageSleep(events, from: start, to: end)
        if services.metrics.hardware.hasBattery, let battery = history as? any BatteryHistoryStore {
            let days = await (try? battery.batteryHistory(days: period.days)) ?? []
            report.batteryHealthPercent = days.last { $0.maxCapacityPercent != nil }?.maxCapacityPercent
            report.onBatterySeconds = days.reduce(0) { $0 + $1.minutesOnBattery } * 60
        }

        let alerts = await (try? services.alertLog.recentAlerts(limit: 2000)) ?? []
        report.alerts = UsageReport.counts(alerts.filter { $0.firedAt >= start && $0.firedAt <= end }.map(\.rule.title))
        let crashes = await CrashFilter.relevant(services.crashReports.reports(since: start))
        report.crashes = UsageReport.counts(crashes.map(\.appName))
        return report
    }
}
