import AppKit
import Core
import SwiftUI

/// The Alerts page's views (D-238): what fired first, the rules a click away.
public enum AlertsTab: String, CaseIterable, Identifiable, Sendable {
    case recent, rules

    public var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .recent: String(localized: "Recent", bundle: .strings, comment: "Recent alerts")
        case .rules: String(localized: "Rules", bundle: .strings, comment: "Alert rules")
        }
    }
}

/// Alerts tab: what fired, newest first, by day; the rules in their own view (spec 5.4, D-238).
struct AlertsView: View {
    let services: AppServices

    @Environment(\.openSettings) private var openSettings
    @AppStorage(PreferenceKey.settingsTab) private var settingsTab: SettingsTab = .general

    var body: some View {
        Group {
            if services.navigation.alertsTab == .recent, services.recentAlerts.isEmpty {
                empty
            } else {
                Form {
                    if services.notificationPermission.isOff {
                        Section {
                            NotificationsOffNotice()
                        }
                    }
                    switch services.navigation.alertsTab {
                    case .recent: recent
                    case .rules: rules
                    }
                }
                .formStyle(.grouped)
            }
        }
        .task(id: services.historyGeneration) {
            await services.reloadAlerts()
        }
        .tracksNotificationPermission(services)
        // Every visit opens on what fired, as the page is for (D-238).
        .onDisappear { services.navigation.alertsTab = .recent }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(
                    String(localized: "View", bundle: .strings, comment: "Alerts tab picker: recent alerts or the rules"),
                    selection: Binding(get: { services.navigation.alertsTab }, set: { services.navigation.alertsTab = $0 })
                ) {
                    ForEach(AlertsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// Nothing yet: what the page is for, and the way to the rules.
    private var empty: some View {
        VStack(spacing: Tokens.Spacing.m) {
            if services.notificationPermission.isOff {
                NotificationsOffNotice().cardStyle().frame(maxWidth: 560)
            }
            ContentUnavailableView {
                Label {
                    Text("Nothing has misbehaved yet.", bundle: .strings)
                } icon: {
                    Image(systemName: "bell").foregroundStyle(Tokens.SidebarTint.alerts.gradient)
                }
            } description: {
                Text("When an app or your Mac goes past one of your rules, it shows here, by day.", bundle: .strings)
            } actions: {
                Button(String(localized: "Show the Rules", bundle: .strings, comment: "Alerts: switches to the rules view")) {
                    services.navigation.alertsTab = .rules
                }
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What fired, by day, newest first.
    private var recent: some View {
        ForEach(AlertDays.group(services.recentAlerts), id: \.day) { day in
            Section {
                ForEach(day.alerts) { alert in
                    AlertRow(alert: alert) {
                        services.navigation.show(alert.rule, app: alert.app.id)
                    }
                }
            } header: {
                SectionHeading(AlertDays.title(day.day))
            }
        }
    }

    /// Each rule, on or off, by what it watches, and the way to its thresholds.
    @ViewBuilder private var rules: some View {
        ForEach(AlertRule.Group.allCases, id: \.self) { group in
            Section {
                ForEach(group.rules, id: \.self) { rule in
                    Toggle(isOn: ruleBinding(rule)) {
                        HStack(spacing: Tokens.Spacing.s) {
                            RuleBadge(rule: rule)
                            VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                                Text(rule.title)
                                Text(RuleDescription.summary(rule, services.alertSettings.settings(for: rule)))
                                    .font(Tokens.Typography.secondary)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text(rule.title))
                }
            } header: {
                SectionHeading(group.title)
            }
        }
        Section {
            // A SettingsLink opens whichever pane was last open; this one is about Alerts.
            Button(String(
                localized: "Thresholds, quiet hours, and muted apps…", bundle: .strings,
                comment: "Opens alert settings; muted apps are apps whose alerts are silenced, not their sound"
            )) {
                settingsTab = .alerts
                openSettings()
            }
        }
    }

    private func ruleBinding(_ rule: AlertRule) -> Binding<Bool> {
        Binding {
            services.alertSettings.settings(for: rule).isEnabled
        } set: { enabled in
            var rules = services.alertSettings.rules
            var settings = services.alertSettings.settings(for: rule)
            settings.isEnabled = enabled
            rules[rule] = settings
            services.alertSettings.rules = rules
        }
    }
}

/// One alert: its rule's badge, what happened, and when. Opens where it happened.
private struct AlertRow: View {
    let alert: Core.Alert
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                RuleBadge(rule: alert.rule)
                VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                    Text(alert.title).fontWeight(.semibold)
                    Text(alert.body)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Tokens.Spacing.s)
                HStack(spacing: Tokens.Spacing.xxs) {
                    Text(alert.firedAt, format: .dateTime.hour().minute())
                        .monospacedDigit()
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .opacity(hovering ? 1 : 0)
                }
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityHint(Text("Shows where it happened", bundle: .strings, comment: "Alerts: what clicking an alert does"))
    }
}

/// Recent alerts by local day, newest first (D-238).
enum AlertDays {
    static func group(_ alerts: [Core.Alert], calendar: Calendar = .autoupdatingCurrent) -> [(day: Date, alerts: [Core.Alert])] {
        let byDay = Dictionary(grouping: alerts) { calendar.startOfDay(for: $0.firedAt) }
        return byDay.keys.sorted(by: >).map { day in
            (day, (byDay[day] ?? []).sorted { $0.firedAt > $1.firedAt })
        }
    }

    /// "Today", "Yesterday", "Monday, October 12".
    static func title(_ day: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        if calendar.isDateInToday(day) {
            return String(localized: "Today", bundle: .strings, comment: "Alerts: the day's section title")
        }
        if calendar.isDateInYesterday(day) {
            return String(localized: "Yesterday", bundle: .strings, comment: "Alerts: the day's section title")
        }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// "Notifications are off for Mactivity", with a way to turn them on. Shown in the Alerts tab and
/// Settings → Alerts while macOS isn't letting alerts through.
struct NotificationsOffNotice: View {
    var body: some View {
        LabeledContent {
            Button(String(localized: "Open Notification Settings…", bundle: .strings)) {
                NotificationSettings.open()
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                    Text("Notifications are off for Mactivity", bundle: .strings)
                    Text("Alerts still show in the Alerts tab, but no notifications appear.", bundle: .strings)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "bell.slash")
                    .foregroundStyle(Tokens.Colors.strain)
            }
        }
    }
}

/// System Settings → Notifications, on Mactivity's own page.
enum NotificationSettings {
    /// The Notifications pane with the app selected. Without a bundle ID (tests, previews), the
    /// pane's list; a macOS that ignores `id` shows the list too.
    static func url(bundleID: String?) -> URL? {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        guard let bundleID, !bundleID.isEmpty,
              let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else {
            return URL(string: pane)
        }
        return URL(string: "\(pane)?id=\(encoded)")
    }

    @MainActor
    static func open() {
        if let url = url(bundleID: Bundle.main.bundleIdentifier) {
            NSWorkspace.shared.open(url)
        }
    }
}

extension View {
    /// Reads the notification permission on appear and whenever Mactivity becomes active.
    func tracksNotificationPermission(_ services: AppServices) -> some View {
        task { await services.refreshNotificationPermission() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await services.refreshNotificationPermission() }
            }
    }
}

/// "≥ 70% average for 10 minutes", from the rule's settings.
enum RuleDescription {
    static func summary(_ rule: AlertRule, _ settings: RuleSettings) -> String {
        let window = Formatters.duration(settings.window)
        switch rule {
        case .highCPU:
            let percent = Formatters.percent(settings.threshold)
            return String(
                localized: "≥ \(percent) average for \(window)", bundle: .strings,
                comment: "Alert rule summary, e.g. ≥ 70% average for 10 min"
            )
        case .growingMemory:
            let growth = Formatters.memory(settings.threshold)
            return String(
                localized: "+\(growth) over \(window), still growing", bundle: .strings,
                comment: "Alert rule summary, e.g. +1 GB over 30 min"
            )
        case .heavyDisk:
            let rate = Formatters.rate(settings.threshold)
            return String(
                localized: "≥ \(rate) written, sustained \(window)", bundle: .strings,
                comment: "Alert rule summary, e.g. ≥ 50 MB/s written"
            )
        case .heavyNetwork:
            let rate = Formatters.rate(settings.threshold)
            return String(
                localized: "≥ \(rate) either way, sustained \(window)", bundle: .strings,
                comment: "Alert rule summary: download or upload"
            )
        case .accessoryBatteryLow:
            let level = Formatters.percent(settings.threshold)
            return String(localized: "An accessory at \(level) or less", bundle: .strings, comment: "Alert rule summary")
        case .diskFilling:
            let span = Duration.seconds(settings.threshold * 86400).formatted(.units(allowed: [.weeks, .days], width: .wide))
            return String(
                localized: "Startup disk full within \(span) at the current rate", bundle: .strings, comment: "Alert rule summary"
            )
        case .appCrashing:
            let count = Int(settings.threshold)
            return String(localized: "An app crashing \(count) or more times in a day", bundle: .strings, comment: "Alert rule summary")
        case .notSleeping:
            return String(localized: "The Mac didn't sleep overnight", bundle: .strings, comment: "Alert rule summary")
        case .hotspotData:
            let amount = Formatters.bytes(settings.threshold)
            return String(
                localized: "An app using over \(amount) of your hotspot's data in 10 minutes", bundle: .strings,
                comment: "Alert rule summary"
            )
        case .diskLow, .overheating, .connectionLost, .runawayProcess, .outOfTheOrdinary, .agentLongSession, .agentMemory, .newStartupItem,
             .dataBudget, .vulnerableSoftware:
            return newerSummary(rule, settings)
        }
    }

    /// The rules added in D-149 and D-156.
    private static func newerSummary(_ rule: AlertRule, _ settings: RuleSettings) -> String {
        switch rule {
        case .diskLow:
            let amount = Formatters.bytes(settings.threshold)
            return String(localized: "Startup disk under \(amount) free", bundle: .strings, comment: "Alert rule summary")
        case .overheating:
            let count = Int(settings.threshold)
            return String(
                localized: "Slowed down to cool for \(count) of the last 10 minutes", bundle: .strings, comment: "Alert rule summary"
            )
        case .connectionLost:
            return String(localized: "No network for a minute", bundle: .strings, comment: "Alert rule summary")
        case .runawayProcess:
            let minutes = Int(settings.threshold)
            return String(
                localized: "A node, python or similar process at a full core for \(minutes) minutes, or leaking memory",
                bundle: .strings, comment: "Alert rule summary"
            )
        case .outOfTheOrdinary:
            let times = Int(settings.threshold).formatted()
            return String(
                localized: "An app at \(times)× its usual day on this Mac, once a day",
                bundle: .strings, comment: "Alert rule summary: an app doing several times what it usually does"
            )
        case .agentLongSession:
            let time = Formatters.duration(.seconds(settings.threshold * 3600))
            return String(
                localized: "A coding agent's session running longer than \(time), once per session",
                bundle: .strings, comment: "Alert rule summary, e.g. longer than 4h"
            )
        case .agentMemory:
            let memory = Formatters.memory(settings.threshold)
            return String(
                localized: "A coding agent's processes holding \(memory) or more, once per session",
                bundle: .strings, comment: "Alert rule summary, e.g. 8 GB or more"
            )
        case .newStartupItem:
            return String(
                localized: "Something adds itself to start with your Mac",
                bundle: .strings, comment: "Alert rule summary"
            )
        case .dataBudget:
            let percent = Formatters.percent(settings.threshold)
            return String(
                localized: "The month's data at \(percent) of your budget, and again when it's used",
                bundle: .strings, comment: "Alert rule summary, e.g. at 80% of your budget"
            )
        case .vulnerableSoftware:
            return String(
                localized: "A package with a serious known vulnerability, or no longer getting security fixes; once each",
                bundle: .strings, comment: "Alert rule summary"
            )
        default:
            return ""
        }
    }
}

extension AlertRule {
    /// The History card an alert about crashes, sleep, accessories or heat opens on (D-196).
    public var historySection: HistorySection? {
        switch self {
        case .appCrashing: .crashes
        case .notSleeping: .sleep
        case .accessoryBatteryLow: .accessories
        case .overheating: .temperature
        default: nil
        }
    }

    /// Where an alert for this rule opens: the metric's tab for app rules, History for
    /// accessories, crashes and sleep, Storage for a filling disk (D-099).
    public var sidebarItem: SidebarItem {
        switch self {
        case .highCPU, .growingMemory, .heavyDisk, .heavyNetwork, .hotspotData, .runawayProcess: metric.sidebarItem
        case .accessoryBatteryLow, .appCrashing, .notSleeping, .overheating: .history
        case .diskFilling, .diskLow: .storage
        // Overview's Out of the ordinary card (D-201).
        case .outOfTheOrdinary: .overview
        case .connectionLost: .network
        case .agentLongSession, .agentMemory: .agents
        case .newStartupItem: .startup
        case .dataBudget: .network
        // Checkup, where the Outdated Software item is (D-252).
        case .vulnerableSoftware: .checkup
        }
    }
}

extension Metric {
    /// The main-window tab that shows this metric.
    public var sidebarItem: SidebarItem {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .energy: .battery
        case .diskRead, .diskWrite: .disk
        case .netIn, .netOut: .network
        case .gpu: .gpu
        case .energyImpact: .battery
        case .cpuTemperature, .gpuTemperature, .fanSpeed, .thermalPressure: .history
        case .batteryLevel: .battery
        case .memoryPressure, .swapUsed: .memory
        case .diskFree: .disk
        case .onBattery, .powerDraw, .batteryTempCharging, .batteryTempInUse: .battery
        }
    }
}
