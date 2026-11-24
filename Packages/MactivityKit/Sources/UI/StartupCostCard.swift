import Core
import Foundation
import os
import SwiftUI

/// What the Mac did after its last startup (D-171), with the apps busiest in those minutes.
/// Measured once the window has passed, and kept per startup: History's minutes, which this
/// needs, last two days, and a Mac can go weeks between restarts.
struct StartupReport: Hashable, Sendable, Codable {
    let cost: StartupCost
    let apps: [AppTotal]

    static let defaultsKey = "LastStartupReport"
    private static let log = Logger(subsystem: "app.mactivity.ui", category: "startup-cost")

    @MainActor
    static func load(_ services: AppServices, now: Date = Date()) async -> StartupReport? {
        guard !services.metrics.isSimulated, let booted = CheckupLoader.bootTime() else {
            return nil
        }
        if let saved = saved(), abs(saved.cost.bootedAt.timeIntervalSince(booted)) < 2 {
            return saved
        }
        // Only a Mactivity that opens at login saw the login.
        guard services.controls.isLaunchAtLoginEnabled(), let daily = services.history as? any DailyHistoryStore else {
            return nil
        }
        let end = booted.addingTimeInterval(StartupCosts.latestStart + StartupCosts.window)
        let cpu = await (try? daily.series(metric: .cpu, app: nil, from: booted, to: end)) ?? []
        guard let cost = StartupCosts.measure(cpu: cpu, bootedAt: booted), now >= cost.window.end else {
            return nil
        }
        let apps = await (try? daily.topApps(metric: .cpu, from: cost.window.start, to: cost.window.end, limit: 4)) ?? []
        let report = StartupReport(cost: cost, apps: apps)
        save(report)
        return report
    }

    private static func saved() -> StartupReport? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(StartupReport.self, from: data)
    }

    private static func save(_ report: StartupReport) {
        do {
            try UserDefaults.standard.set(JSONEncoder().encode(report), forKey: defaultsKey)
        } catch {
            log.error("Couldn't keep the startup report: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// "Settled 4m after logging in".
    var headline: String {
        guard let settled = cost.settledAfter else {
            return String(
                localized: "Still busy 10 minutes after logging in",
                bundle: .strings,
                comment: "Startup tab: the Mac never calmed down in the first 10 minutes"
            )
        }
        if settled < 60 {
            return String(
                localized: "Calm within a minute of logging in",
                bundle: .strings,
                comment: "Startup tab: the Mac was quiet right after login"
            )
        }
        let duration = Formatters.duration(.seconds(settled))
        return String(
            localized: "Settled \(duration) after logging in",
            bundle: .strings,
            comment: "Startup tab: how long after login the processor calmed down, e.g. 4m"
        )
    }

    var detail: String {
        let when = cost.loginAt.formatted(.dateTime.weekday(.wide).hour().minute())
        let average = Formatters.percent(cost.averageCPU)
        return String(
            localized: "Last startup: \(when) · the processor averaged \(average) over the first 10 minutes",
            bundle: .strings,
            comment: "Startup tab: when the Mac last started, and its average CPU after login"
        )
    }
}

/// The Startup tab's "after your last startup" card (D-171).
struct StartupCostCard: View {
    let report: StartupReport
    /// Bundle IDs of apps with a login item or agent, marked as starting with the Mac.
    let startsAtLogin: Set<String>
    let showHistory: (AppIdentity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                Image(systemName: report.cost.settledAfter == nil ? "hourglass" : "power")
                    .font(Tokens.Typography.cardSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: Tokens.IconSize.card)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(report.headline).font(Tokens.Typography.cardTitle)
                    Text(report.detail)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            if !report.apps.isEmpty {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(
                        "Busiest then:",
                        bundle: .strings,
                        comment: "Startup tab: before the apps busiest in the first 10 minutes after login"
                    )
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    ForEach(report.apps) { chip($0) }
                }
                .padding(.leading, Tokens.IconSize.card + Tokens.Spacing.s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func chip(_ total: AppTotal) -> some View {
        let atLogin = total.app.bundleID.map(startsAtLogin.contains) ?? false
        return Button { showHistory(total.app) } label: {
            HStack(spacing: Tokens.Spacing.xxs) {
                AppIconView(total.app, size: Tokens.IconSize.small)
                Text(total.app.name).lineLimit(1)
                Text(Formatters.percent(total.value)).foregroundStyle(.secondary).monospacedDigit()
                if atLogin {
                    Image(systemName: "power").foregroundStyle(.secondary).accessibilityLabel(Text(
                        "Starts with your Mac",
                        bundle: .strings
                    ))
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(
            atLogin
                ? Text(
                    "\(total.app.name) starts with your Mac. Click to see its history.",
                    bundle: .strings,
                    comment: "Tooltip on an app busy after login that has a login item"
                )
                : Text("Show \(total.app.name)’s history", bundle: .strings, comment: "Tooltip on a top app: opens its history page")
        )
    }
}
