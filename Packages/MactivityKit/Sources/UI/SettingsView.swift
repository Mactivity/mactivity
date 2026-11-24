import Core
import SwiftUI
import UniformTypeIdentifiers

/// Settings (spec 4.5), looking like System Settings panes.
public struct SettingsView: View {
    private let services: AppServices

    @AppStorage(PreferenceKey.settingsTab) private var tab: SettingsTab = .general

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        TabView(selection: $tab) {
            Tab(String(localized: "General", bundle: .strings), systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettings(controls: services.controls, metrics: services.metrics)
            }
            Tab(
                String(localized: "Customize", bundle: .strings, comment: "Settings pane: colors, the figures' typeface, spacing"),
                systemImage: "paintpalette",
                value: SettingsTab.customize
            ) {
                CustomizeSettings(metrics: services.metrics)
            }
            Tab(String(localized: "Menu Bar", bundle: .strings), systemImage: "menubar.rectangle", value: SettingsTab.menuBar) {
                MenuBarSettings(metrics: services.metrics)
            }
            Tab(String(localized: "Alerts", bundle: .strings), systemImage: "bell.badge", value: SettingsTab.alerts) {
                AlertSettingsPane(services: services)
            }
            Tab(String(localized: "History", bundle: .strings), systemImage: "clock.arrow.circlepath", value: SettingsTab.history) {
                HistorySettings(services: services)
            }
            Tab(String(localized: "Helper", bundle: .strings), systemImage: "lock.shield", value: SettingsTab.helper) {
                HelperSettings(controls: services.controls)
            }
            Tab(String(localized: "Privacy", bundle: .strings), systemImage: "lock", value: SettingsTab.privacy) {
                PrivacySettings(controls: services.controls)
            }
        }
        // Every pane is a Form: past the maximum it scrolls, rather than outgrow a laptop's screen (D-175).
        .frame(
            minWidth: Tokens.Layout.settingsWidth, maxWidth: Tokens.Layout.settingsWidth,
            minHeight: Tokens.Layout.settingsMinHeight, maxHeight: Tokens.Layout.settingsMaxHeight
        )
        // Closed, Settings would keep its panes (the menu bar preview) observing live data (D-086).
        .releasedWhileHidden()
    }
}

private struct GeneralSettings: View {
    let controls: AppControls
    let metrics: LiveMetrics

    @AppStorage(PreferenceKey.appearance) private var appearance: AppearancePreference = .system
    @AppStorage(PreferenceKey.showsWindowAtLaunch) private var showsWindowAtLaunch = true
    @AppStorage(PreferenceKey.perAppVolume) private var perAppVolume = false
    @AppStorage(PreferenceKey.askMactivity) private var askMactivity = false
    @AppStorage(PreferenceKey.visibleIntervalSeconds) private var visibleIntervalSeconds = 1
    @AppStorage(TemperatureUnit.defaultsKey) private var temperatureUnit: TemperatureUnit = .automatic
    @AppStorage(PreferenceKey.memoryFigure) private var memoryFigure: MemoryFigure = .automatic
    @AppStorage(PreferenceKey.networkFigure) private var networkFigure: NetworkFigure = .automatic
    @AppStorage(PreferenceKey.diskFigure) private var diskFigure: DiskFigure = .automatic
    @AppStorage(PreferenceKey.batteryFigure) private var batteryFigure: BatteryFigure = .automatic
    @AppStorage(PreferenceKey.temperatureFigure) private var temperatureFigure: TemperatureFigure = .automatic
    @State private var launchAtLogin = false
    @State private var needsApproval = false
    @State private var loginFailed = false

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Open at login", bundle: .strings), isOn: Binding(get: { launchAtLogin }, set: { wanted in
                    if controls.setLaunchAtLogin(wanted) {
                        launchAtLogin = controls.isLaunchAtLoginEnabled()
                        loginFailed = false
                    } else {
                        // macOS refused: say so, rather than the switch just springing back (D-197).
                        loginFailed = true
                    }
                    needsApproval = controls.launchAtLoginNeedsApproval()
                }))
                if loginFailed {
                    Text("macOS didn't allow it. System Settings → General → Login Items can add Mactivity.", bundle: .strings)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Colors.strainLabel)
                }
                if needsApproval {
                    LabeledContent(String(localized: "Needs your approval", bundle: .strings)) {
                        Button(String(localized: "Login Items Settings…", bundle: .strings)) { controls.openLoginItemsSettings() }
                    }
                }
                Toggle(String(localized: "Show the main window when Mactivity opens", bundle: .strings), isOn: $showsWindowAtLaunch)
            } footer: {
                Text("Mactivity always lives in the menu bar. Turn the window off to start quietly at login.", bundle: .strings)
                    .foregroundStyle(.secondary)
            }
            ShortcutsSection()
            Section {
                Picker(String(localized: "Appearance", bundle: .strings), selection: $appearance) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                }
                Picker(String(localized: "Temperature", bundle: .strings), selection: $temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { Text($0.settingsTitle).tag($0) }
                }
                Picker(String(localized: "Update while a window is open", bundle: .strings), selection: $visibleIntervalSeconds) {
                    Text("Every second", bundle: .strings).tag(1)
                    Text("Every 2 seconds", bundle: .strings).tag(2)
                    Text("Every 5 seconds", bundle: .strings).tag(5)
                }
            } footer: {
                Text(
                    """
                    Slower updates use less energy while you keep a window open. With no window open, Mactivity samples every \
                    10 seconds. In Low Power Mode, both slow to half speed.
                    """,
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
            }
            Section {
                Picker(String(localized: "Memory", bundle: .strings), selection: $memoryFigure) {
                    ForEach(MemoryFigure.allCases) { Text($0.settingsTitle).tag($0) }
                }
                Picker(String(localized: "Network", bundle: .strings), selection: $networkFigure) {
                    ForEach(NetworkFigure.allCases) { Text($0.settingsTitle).tag($0) }
                }
                Picker(String(localized: "Disk", bundle: .strings), selection: $diskFigure) {
                    ForEach(DiskFigure.allCases) { Text($0.settingsTitle).tag($0) }
                }
                if metrics.hardware.hasBattery {
                    Picker(String(localized: "Battery", bundle: .strings), selection: $batteryFigure) {
                        ForEach(BatteryFigure.allCases) { Text($0.settingsTitle).tag($0) }
                    }
                }
                // "Sensor", so it doesn't read as a second Temperature (unit) picker above.
                Picker(String(localized: "Temperature sensor", bundle: .strings), selection: $temperatureFigure) {
                    ForEach(TemperatureFigure.allCases) { Text($0.settingsTitle).tag($0) }
                }
            } header: {
                Text("Figures", bundle: .strings, comment: "Settings section: what each metric's figure shows")
            } footer: {
                Text(
                    "Where a figure appears: the menu bar, the menu bar window, and the cards. Automatic keeps each place's usual figure.",
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
            }
            Section {
                Toggle(String(localized: "Per-app volume (experimental)", bundle: .strings), isOn: $perAppVolume)
            } footer: {
                Text(
                    "Adds a Sound tab with a slider per app. Needs permission to listen to app audio; nothing is recorded.",
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
            }
            // Opt-in (D-161): the one place the app could state something its figures don't.
            Section {
                Toggle(String(localized: "Ask Mactivity in Quick Search (experimental)", bundle: .strings), isOn: $askMactivity)
                    .disabled(!AskModel.isModelAvailable)
            } footer: {
                Group {
                    if AskModel.isModelAvailable {
                        Text(
                            """
                            Type a question in Quick Search and Apple Intelligence answers it on this Mac, from Mactivity's \
                            figures. Nothing is sent anywhere. Answers can be wrong; the figures in the app are the reference.
                            """,
                            bundle: .strings
                        )
                    } else {
                        Text("Needs Apple Intelligence, turned on in System Settings.", bundle: .strings)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Section(String(localized: "Updates", bundle: .strings)) {
                // The installed version beside the button, as in the About window (D-114).
                LabeledContent {
                    if controls.updatesConfigured {
                        Button(String(localized: "Check for Updates…", bundle: .strings)) { controls.checkForUpdates() }
                    } else {
                        Text("Updates arrive with signed releases.", bundle: .strings)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text(verbatim: "Mactivity \(BuildInfo.main().displayVersion)")
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
            }
            CommandLineToolSettings()
        }
        .formStyle(.grouped)
        .onChange(of: visibleIntervalSeconds) { _, seconds in
            metrics.visibleInterval = .seconds(LiveMetrics.clampedVisibleSeconds(seconds))
        }
        .onAppear {
            launchAtLogin = controls.isLaunchAtLoginEnabled()
            needsApproval = controls.launchAtLoginNeedsApproval()
        }
        // Back from approving it in System Settings: show the new state now (D-197).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = controls.isLaunchAtLoginEnabled()
            needsApproval = controls.launchAtLoginNeedsApproval()
        }
    }
}

struct AlertSettingsPane: View {
    let services: AppServices

    /// Notes when the day changed, so the next summary isn't right after the last one (D-273).
    private var weeklyDayBinding: Binding<WeeklySummaryDay> {
        Binding {
            WeeklySummaryDay(rawValue: weeklyDay) ?? .monday
        } set: { day in
            guard day.rawValue != weeklyDay else {
                return
            }
            weeklyDay = day.rawValue
            UserDefaults.standard.set(Date(), forKey: PreferenceKey.weeklyDigestDayChanged)
        }
    }

    @AppStorage(PreferenceKey.dailyDigest) private var dailyDigest = false
    @AppStorage(PreferenceKey.weeklyDigest) private var weeklyDigest = true
    @AppStorage(PreferenceKey.weeklyDigestDay) private var weeklyDay = WeeklySummaryDay.monday.rawValue
    @AppStorage(PreferenceKey.holdsAlertsWhilePresenting) private var holdsWhilePresenting = true
    @State private var confirmsRestore = false

    var body: some View {
        @Bindable var services = services
        Form {
            if services.notificationPermission.isOff {
                Section {
                    NotificationsOffNotice()
                }
            }
            ForEach(AlertRule.allCases, id: \.self) { rule in
                let settings = services.alertSettings.settings(for: rule)
                Section {
                    Toggle(String(localized: "On", bundle: .strings, comment: "Turns an alert rule on"), isOn: binding(rule, \.isEnabled))
                    // An alert that's off keeps its figures, dimmed: changing them would do nothing (D-197).
                    Group {
                        thresholdField(rule)
                        // Mac-level rules have their own fixed spans (D-099).
                        if rule.isPerApp {
                            Picker(
                                String(localized: "For", bundle: .strings, comment: "How long a condition lasts before an alert fires"),
                                selection: windowBinding(rule)
                            ) {
                                ForEach(windowChoices(rule), id: \.self) { minutes in
                                    Text(Formatters.duration(.seconds(minutes * 60))).tag(minutes)
                                }
                            }
                        }
                    }
                    .disabled(!settings.isEnabled)
                } header: {
                    Text(rule.title)
                } footer: {
                    // What it watches, in the words of the Alerts tab, with the figures chosen above.
                    Text(RuleDescription.summary(rule, settings))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button(String(localized: "Restore Default Rules…", bundle: .strings)) { confirmsRestore = true }
                    .confirmationDialog(
                        String(localized: "Restore every alert's default figures?", bundle: .strings),
                        isPresented: $confirmsRestore
                    ) {
                        Button(String(localized: "Restore Defaults", bundle: .strings)) {
                            services.alertSettings.rules = AlertSettings.defaults.rules
                        }
                    } message: {
                        Text(
                            "Which alerts are on and their thresholds go back to how Mactivity came. Muted apps and quiet hours stay.",
                            bundle: .strings
                        )
                    }
            }
            Section {
                Toggle(String(localized: "Daily summary", bundle: .strings), isOn: $dailyDigest)
                Toggle(String(localized: "Weekly summary", bundle: .strings), isOn: $weeklyDigest)
                Picker(
                    String(localized: "Send it on", bundle: .strings, comment: "Alert settings: which day the weekly summary goes out"),
                    selection: weeklyDayBinding
                ) {
                    ForEach(WeeklySummaryDay.offered()) { Text($0.title()).tag($0) }
                }
                .disabled(!weeklyDigest)
            } footer: {
                Text(
                    """
                    Daily: the first time your Mac wakes after 7 am, the busiest apps and any alerts from the last day. \
                    Weekly: at 9 am on the day you choose, or 6 pm on Sunday evening, your week in use, sleep and crashes.
                    """,
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
            }
            Section(String(localized: "When", bundle: .strings, comment: "Settings section: when alerts are sent")) {
                Picker(
                    String(
                        localized: "Don't repeat for",
                        bundle: .strings,
                        comment: "Alert settings picker: after an alert, how long before the same alert can fire again (e.g. 1 hour)"
                    ),
                    selection: cooldownBinding
                ) {
                    ForEach([15, 30, 60, 120, 240], id: \.self) { minutes in
                        Text(Formatters.duration(.seconds(minutes * 60))).tag(minutes)
                    }
                }
                Toggle(String(localized: "Ignore the app I'm using", bundle: .strings), isOn: $services.alertSettings.exemptsFrontmostApp)
                // 1.6: alerts wait during a call, a slideshow or a mirrored display, then come as one.
                Toggle(isOn: $holdsWhilePresenting) {
                    Text("Hold alerts while I present or am on a call", bundle: .strings)
                    Text(
                        """
                        They wait while the microphone or camera is in use, a slideshow fills the screen, or the display \
                        is mirrored, then come as one.
                        """,
                        bundle: .strings
                    )
                }
                Toggle(String(localized: "Quiet hours", bundle: .strings), isOn: quietHoursEnabled)
                if let quiet = services.alertSettings.quietHours {
                    Picker(
                        String(localized: "From", bundle: .strings, comment: "Start of quiet hours"), selection: quietBinding(\.startMinute)
                    ) {
                        ForEach(0 ..< 24, id: \.self) { Text(hourLabel($0)).tag($0 * 60) }
                    }
                    Picker(
                        String(localized: "Until", bundle: .strings, comment: "End of quiet hours"), selection: quietBinding(\.endMinute)
                    ) {
                        ForEach(0 ..< 24, id: \.self) { Text(hourLabel($0)).tag($0 * 60) }
                    }
                    .help(Text("Quiet from \(hourLabel(quiet.startMinute / 60)) to \(hourLabel(quiet.endMinute / 60))", bundle: .strings))
                    // The same hour twice is no quiet time at all (QuietHours): say so (D-197).
                    if quiet.startMinute == quiet.endMinute {
                        Text("From and Until are the same hour, so alerts are never held back.", bundle: .strings)
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(Tokens.Colors.strainLabel)
                    }
                }
            }
            MutedAppsSection(services: services)
        }
        .formStyle(.grouped)
        .tracksNotificationPermission(services)
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    func binding<Value>(_ rule: AlertRule, _ keyPath: WritableKeyPath<RuleSettings, Value>) -> Binding<Value> {
        Binding {
            services.alertSettings.settings(for: rule)[keyPath: keyPath]
        } set: { value in
            var settings = services.alertSettings.settings(for: rule)
            settings[keyPath: keyPath] = value
            services.alertSettings.rules[rule] = settings
        }
    }

    private func windowBinding(_ rule: AlertRule) -> Binding<Int> {
        Binding {
            Int(services.alertSettings.settings(for: rule).window.components.seconds / 60)
        } set: { minutes in
            binding(rule, \.window).wrappedValue = .seconds(minutes * 60)
        }
    }

    private func windowChoices(_ rule: AlertRule) -> [Int] {
        rule == .growingMemory ? [15, 30, 60, 120] : [1, 5, 10, 15, 30]
    }

    @ViewBuilder
    private func thresholdField(_ rule: AlertRule) -> some View {
        switch rule {
        case .highCPU:
            Picker(String(localized: "Above", bundle: .strings, comment: "Alert threshold"), selection: binding(rule, \.threshold)) {
                ForEach([50.0, 60, 70, 80, 90], id: \.self) { Text(Formatters.percent($0)).tag($0) }
            }
        case .growingMemory:
            Picker(String(localized: "Grows by", bundle: .strings, comment: "Alert threshold"), selection: binding(rule, \.threshold)) {
                ForEach([536_870_912.0, 1_073_741_824, 2_147_483_648, 4_294_967_296], id: \.self) {
                    Text(Formatters.memory($0)).tag($0)
                }
            }
        case .heavyDisk:
            Picker(
                String(localized: "Writing above", bundle: .strings, comment: "Alert threshold"), selection: binding(rule, \.threshold)
            ) {
                ForEach([20_000_000.0, 50_000_000, 100_000_000, 200_000_000], id: \.self) { Text(Formatters.rate($0)).tag($0) }
            }
        case .heavyNetwork:
            Picker(String(localized: "Above", bundle: .strings, comment: "Alert threshold"), selection: binding(rule, \.threshold)) {
                ForEach([1_000_000.0, 5_000_000, 10_000_000, 50_000_000], id: \.self) { Text(Formatters.rate($0)).tag($0) }
            }
        default:
            systemThresholdField(rule)
        }
    }

    private var cooldownBinding: Binding<Int> {
        Binding {
            Int(services.alertSettings.cooldown.components.seconds / 60)
        } set: { minutes in
            services.alertSettings.cooldown = .seconds(minutes * 60)
        }
    }

    private var quietHoursEnabled: Binding<Bool> {
        Binding {
            services.alertSettings.quietHours != nil
        } set: { isOn in
            services.alertSettings.quietHours = isOn ? QuietHours(startMinute: 22 * 60, endMinute: 7 * 60) : nil
        }
    }

    private func quietBinding(_ keyPath: WritableKeyPath<QuietHours, Int>) -> Binding<Int> {
        Binding {
            services.alertSettings.quietHours?[keyPath: keyPath] ?? 0
        } set: { value in
            services.alertSettings.quietHours?[keyPath: keyPath] = value
        }
    }
}
