import Alerts
import AppKit
import Core
import Foundation
import os
import UI

/// Sends the daily digest (expansion E2) and the weekly summary (D-102, D-273) when they're due:
/// checked once the pipeline runs, on every screen wake, and with the 10-minute checks. Before
/// the pipeline starts the stores are placeholders, so checking then sent nothing, or simulated
/// figures in Debug builds (D-139).
@MainActor
final class DigestScheduler {
    static let shared = DigestScheduler()

    private static let log = Logger(subsystem: "app.mactivity.app", category: "digest")
    private var observer: NSObjectProtocol?

    func start(services: AppServices) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DigestScheduler.shared.check(services: services) }
        }
    }

    /// Sends whichever is due. Callers: the pipeline starting, a screen wake, the 10-minute checks.
    func check(services: AppServices) {
        sendIfDue(services: services)
        sendWeeklyIfDue(services: services)
    }

    /// The weekly summary on the chosen day (D-273), on the same wake as the daily one.
    private func sendWeeklyIfDue(services: AppServices) {
        let defaults = UserDefaults.standard
        let lastSent = defaults.object(forKey: PreferenceKey.lastWeeklyDigestSent) as? Date
        let day = defaults.string(forKey: PreferenceKey.weeklyDigestDay).flatMap(WeeklySummaryDay.init) ?? .monday
        let changedAt = defaults.object(forKey: PreferenceKey.weeklyDigestDayChanged) as? Date
        guard defaults.object(forKey: PreferenceKey.weeklyDigest) as? Bool ?? true, !services.metrics.isSimulated,
              Digest.isWeeklyDue(now: Date(), lastSent: lastSent, day: day, changedAt: changedAt)
        else {
            return
        }
        // The seven days up to when it became due, even when it goes out later in the week.
        let end = Digest.weeklyReportEnd(due: Digest.weeklyDueTime(atOrBefore: Date(), day: day) ?? Date(), day: day)
        Task {
            let report = await WeeklyReportLoader.load(services, end: end)
            // Recorded even when there's nothing to say, so a quiet week doesn't retry every wake.
            UserDefaults.standard.set(Date(), forKey: PreferenceKey.lastWeeklyDigestSent)
            guard let content = Digest.weekly(report, day: day) else {
                return
            }
            do {
                try await NotificationDeliverer().deliverDigest(content)
            } catch {
                Self.log.error("Weekly summary delivery failed: \(String(describing: error))")
            }
        }
    }

    private func sendIfDue(services: AppServices) {
        let defaults = UserDefaults.standard
        let lastSent = defaults.object(forKey: PreferenceKey.lastDigestSent) as? Date
        guard defaults.bool(forKey: PreferenceKey.dailyDigest), !services.metrics.isSimulated,
              Digest.isDue(now: Date(), lastSent: lastSent)
        else {
            return
        }
        Task {
            let history = services.history
            let alertLog = services.alertLog
            let cpu = await (try? history.topApps(metric: .cpu, range: .h24, limit: 3)) ?? []
            let memory = await (try? history.topApps(metric: .memory, range: .h24, limit: 3)) ?? []
            let network = await (try? history.topApps(metric: .netIn, range: .h24, limit: 3)) ?? []
            let dayAgo = Date().addingTimeInterval(-86400)
            let alerts = await ((try? alertLog.recentAlerts(limit: 50)) ?? []).filter { $0.firedAt >= dayAgo }
            // Recorded even when there's nothing to say, so a quiet day doesn't retry every wake.
            UserDefaults.standard.set(Date(), forKey: PreferenceKey.lastDigestSent)
            guard let content = Digest.content(topCPU: cpu, topMemory: memory, topNetwork: network, alerts: alerts) else {
                return
            }
            do {
                try await NotificationDeliverer().deliverDigest(content)
            } catch {
                Self.log.error("Digest delivery failed: \(String(describing: error))")
            }
        }
    }
}
