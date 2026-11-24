import AppKit
import Core
import Storage
import SwiftUI

/// Checkup (D-101): everything Mactivity knows, as a short list of things worth doing, each with
/// a button to the screen that deals with it.
struct CheckupView: View {
    let services: AppServices
    @Environment(\.openSettings) private var openSettings
    @AppStorage(PreferenceKey.settingsTab) private var settingsTab: SettingsTab = .general

    @State private var items: [CheckupItem]?

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("Everything looks good", bundle: .strings)
                        } icon: {
                            Image(systemName: "checkmark.seal").foregroundStyle(Tokens.SidebarTint.checkup.gradient)
                        }
                    } description: {
                        Text("Nothing needs your attention. Checkup looks again every few minutes.", bundle: .strings)
                    }
                } else {
                    list(items)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: services.historyGeneration) {
            while !Task.isCancelled {
                let inputs = await CheckupLoader.inputs(services)
                items = Checkup.items(inputs)
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// What to do soon, then what's worth knowing (D-239).
    private func list(_ items: [CheckupItem]) -> some View {
        let soon = items.filter { $0.severity == .attention }
        let knowing = items.filter { $0.severity != .attention }
        return Form {
            ForEach([(soon, true), (knowing, false)], id: \.1) { group, isSoon in
                if !group.isEmpty {
                    Section {
                        ForEach(group) { item in
                            CheckupRow(item: item) { open(item) }
                        }
                    } header: {
                        SectionHeading(isSoon
                            ? String(localized: "Worth doing soon", bundle: .strings, comment: "Checkup section: items to act on")
                            : String(localized: "Worth knowing", bundle: .strings, comment: "Checkup section: items for information"))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func open(_ item: CheckupItem) {
        if item.area == .login {
            // Open at login is in Settings → General.
            settingsTab = .general
            openSettings()
        } else if item.area == .unusedApps {
            services.unusedApps.open(services)
        } else if item.area == .software {
            services.software.open()
        } else {
            Self.act(item.area, services: services)
        }
    }

    nonisolated static func summary(_ items: [CheckupItem]) -> String {
        let attention = items.count { $0.severity == .attention }
        return attention > 0
            ? String(localized: "Worth doing soon: \(attention). Worth knowing: \(items.count - attention).", bundle: .strings)
            : String(localized: "Nothing urgent. Worth knowing: \(items.count).", bundle: .strings)
    }

    /// Show: the tab that fixes it, or for an update, Software Update in System Settings.
    static func act(_ area: CheckupItem.Area, services: AppServices) {
        if area == .updates, let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
            NSWorkspace.shared.open(url)
            return
        }
        if area == .timeMachine, let url = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension") {
            NSWorkspace.shared.open(url)
            return
        }
        switch area {
        case .sleep: services.navigation.showHistory(.sleep)
        case .crashes: services.navigation.showHistory(.crashes)
        case .accessories: services.navigation.showHistory(.accessories)
        case .afterUpdates: services.navigation.showHistory(.updates)
        case .builds: services.navigation.showHistory(.builds)
        case .flagged: services.navigation.showHistory(.flagged)
        case .launches: services.navigation.showHistory(.launches)
        // The cleanup itself, not Storage with its card folded (D-196); the Trash in Finder.
        case .messages: services.navigation.showCleanup(.messages)
        case .backups: services.navigation.showCleanup(.backups)
        case .trash: NSWorkspace.shared.open(TrashFolder.folder())
        default: services.navigation.show(destination(area))
        }
    }

    static func destination(_ area: CheckupItem.Area) -> SidebarItem {
        switch area {
        case .disk: .storage
        case .battery: .battery
        case .sleep, .crashes, .accessories: .history
        case .startup: .startup
        case .memory: .memory
        case .heat: .cpu
        case .projects: .projects
        case .notifications: .alerts
        case .messages, .backups, .trash: .storage
        case .updates, .login, .unusedApps, .timeMachine, .software: .checkup
        case .security: .security
        // Overview's Out of the ordinary says by how much (D-198).
        case .unusual: .overview
        case .afterUpdates, .builds, .flagged, .launches: .history
        }
    }

    nonisolated static func symbol(_ area: CheckupItem.Area) -> String {
        switch area {
        case .disk: "internaldrive"
        case .battery: "battery.25percent"
        case .sleep: "moon.zzz"
        case .crashes: "exclamationmark.triangle"
        case .startup: "power"
        case .memory: "memorychip"
        case .accessories: "airpodspro"
        case .heat: "thermometer.high"
        case .projects: "hammer"
        case .notifications: "bell.slash"
        case .messages: "message"
        case .backups: "iphone.gen3"
        case .trash: "trash"
        case .updates: "arrow.down.app"
        case .login: "power"
        case .unusedApps: "moon.zzz"
        case .software: "shippingbox"
        case .unusual: "sparkle.magnifyingglass"
        case .afterUpdates: "arrow.triangle.2.circlepath"
        case .builds: "hammer"
        case .flagged: "flag"
        case .launches: "timer"
        case .timeMachine: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .security: "lock.shield"
        }
    }

    /// Each area in the color of the page it opens, so the list reads at a glance.
    static func tint(_ area: CheckupItem.Area) -> Color {
        switch area {
        case .disk, .flagged: Tokens.SidebarTint.disk
        case .battery, .accessories, .timeMachine: Tokens.SidebarTint.battery
        case .sleep, .unusedApps: .indigo
        case .crashes, .heat, .notifications: .red
        case .startup, .login: Tokens.SidebarTint.startup
        case .memory: Tokens.SidebarTint.memory
        case .projects, .builds: Tokens.SidebarTint.projects
        case .messages, .backups, .trash: Tokens.SidebarTint.storage
        case .updates, .afterUpdates: .blue
        case .unusual: .pink
        case .launches: Tokens.SidebarTint.network
        case .software: .red
        case .security: Tokens.SidebarTint.security
        }
    }
}

private struct CheckupRow: View {
    let item: CheckupItem
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                SymbolBadge(symbol: CheckupView.symbol(item.area), tint: CheckupView.tint(item.area))
                VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                    Text(item.title).fontWeight(.semibold)
                    Text(item.detail)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Tokens.Spacing.s)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, Tokens.Spacing.xxs)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Shows where to deal with it", bundle: .strings, comment: "Checkup: what clicking an item does"))
    }
}

/// Gathers Checkup's inputs from the live figures, history, and the other models.
@MainActor
enum CheckupLoader {
    /// About the real history only: simulated data (and the screenshots and demo video made
    /// with it, launched long after the Mac) has no gap to speak of.
    static func missedAfterRestart(_ services: AppServices) -> TimeInterval? {
        guard !services.metrics.isSimulated, let booted = bootTime() else {
            return nil
        }
        return Checkup.missedAfterRestart(
            bootedAt: booted, launchedAt: services.launchedAt, opensAtLogin: services.controls.isLaunchAtLoginEnabled()
        )
    }

    /// When the Mac started, from `kern.boottime`.
    static func bootTime() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
    }

    /// Broken startup items, and the last startup when it was in the last week. Also keeps the startup's report before its minutes age
    /// out of History (D-171).
    static func addStartup(to inputs: inout CheckupInputs, _ services: AppServices, now: Date) async {
        if services.startup.items.isEmpty {
            await services.startup.refresh()
        }
        inputs.brokenStartupItems = services.startup.summary.broken
        guard let report = await StartupReport.load(services, now: now), now.timeIntervalSince(report.cost.loginAt) < 7 * 86400 else {
            return
        }
        inputs.lastStartup = report.cost
        inputs.lastStartupApps = report.apps.prefix(3).map(\.app.name)
    }

    /// This week against the three before it (D-160).
    static func addTrends(to inputs: inout CheckupInputs, _ services: AppServices, now: Date) async {
        let weekStart = now.addingTimeInterval(-7 * 86400)
        let earlierStart = now.addingTimeInterval(-28 * 86400)
        if let daily = services.history as? any DailyHistoryStore {
            let thisWeek = await (try? daily.topApps(metric: .memory, from: weekStart, to: now, limit: 20)) ?? []
            let before = await (try? daily.topApps(metric: .memory, from: earlierStart, to: weekStart, limit: 60)) ?? []
            inputs.memoryGrowth = Trends.growing(
                now: thisWeek.filter { $0.app.kind == .app }, before: before, ratio: Trends.memoryRatio, increase: Trends.memoryIncrease
            )
        }
        if services.metrics.hardware.hasBattery, let use = services.history as? any BatteryUseStore {
            let thisWeek = await (try? use.batteryUse(from: weekStart, to: now, limit: 0)).flatMap(Trends.drainRate)
            let before = await (try? use.batteryUse(from: earlierStart, to: weekStart, limit: 0)).flatMap(Trends.drainRate)
            if let thisWeek, let before {
                inputs.drain = (thisWeek, before)
            }
        }
    }

    static func inputs(_ services: AppServices) async -> CheckupInputs {
        var inputs = CheckupInputs()
        let now = Date()
        // Commands and folder walks with nothing to do with each other or with History, so the first
        // look waits for the slowest, not for all of them in a row (D-267). Most are kept for a while:
        // what's installed 6 hours, the protections 10 minutes. History's reads below stay in a line:
        // they share one thread, so overlapping them would gain nothing.
        async let cleanupRead = CleanupSummary.current()
        async let softwareRead: Void = services.software.refresh(now: now)
        async let flagged = services.recentMacReports(days: 7, now: now)
        async let security = services.security.checkupSettings(now: now)
        let snapshot = services.metrics.snapshot
        if let boot = snapshot?.system.disk.bootVolume {
            inputs.diskFreeBytes = boot.freeBytes
            inputs.diskTotalBytes = boot.totalBytes
        }
        inputs.swapBytes = snapshot?.system.memory.swapUsedBytes
        inputs.biggestMemoryApp = snapshot?.apps.filter { $0.app.kind != .system }.max { $0.memoryBytes < $1.memoryBytes }?.app.name
        inputs.lowAccessories = (snapshot?.system.sensors?.peripherals ?? []).filter { $0.percent <= 20 }
        await services.refreshNotificationPermission()
        inputs.notificationsOff = services.notificationPermission.isOff
        inputs.missedAfterRestart = missedAfterRestart(services)
        inputs.unusedApps = await UnusedAppsModel.find(services, now: now)
        await addLearned(to: &inputs, services, now: now)
        inputs.pendingUpdates = await services.softwareUpdates.pending()
        inputs.drives = await services.driveHealth.drives()
        await addTrends(to: &inputs, services, now: now)
        await addStartup(to: &inputs, services, now: now)

        await addRecorded(to: &inputs, services, now: now)
        let reports = await services.crashReports.reports(since: now.addingTimeInterval(-7 * 86400))
        for report in CrashFilter.relevant(reports) {
            inputs.crashesThisWeek[report.appName, default: 0] += 1
        }
        (inputs.idleServers, inputs.idleServersMemory) = await idleServers(services)
        await add(cleanupRead, to: &inputs)
        await softwareRead
        inputs.software = services.software.findings(now: now)
        inputs.flagged = await flagged
        inputs.security = await security
        return inputs
    }

    /// What History has on the disk, the battery, pressure and last night, and what's holding the Mac awake.
    private static func addRecorded(to inputs: inout CheckupInputs, _ services: AppServices, now: Date) async {
        let history = services.history
        if let daily = history as? any DailyHistoryStore {
            let days = await (try? daily.dailyValues(metric: .diskFree, days: 30)) ?? []
            inputs.diskDaysUntilFull = DiskForecast.daysUntilFull(days)
        }
        if services.metrics.hardware.hasBattery, let battery = history as? any BatteryHistoryStore {
            let days = await (try? battery.batteryHistory(days: 365)) ?? []
            inputs.batteryHealthPercent = days.last { $0.maxCapacityPercent != nil }?.maxCapacityPercent
            inputs.batteryMonthsTo80 = BatteryHealthForecast.estimate(80, days: days)
        }
        let pressure = await (try? history.series(metric: .memoryPressure, app: nil, range: .h24)) ?? []
        if !pressure.isEmpty {
            inputs.memoryPressureDay = pressure.reduce(0) { $0 + $1.average } / Double(pressure.count)
        }
        let thermal = await (try? history.series(metric: .thermalPressure, app: nil, range: .h24)) ?? []
        let today = Calendar.current.startOfDay(for: now)
        inputs.throttledMinutesToday = Double(thermal.count { $0.at >= today && $0.maximum >= 2 })

        inputs.sleepBlockers = await services.sleepBlockers.blockers()
        if let power = history as? any PowerEventStore, (6 ..< 12).contains(Calendar.current.component(.hour, from: now)) {
            let events = await (try? power.powerEvents(days: 2)) ?? []
            let asleep = SleepTimeline.asleep(events, from: today, to: today.addingTimeInterval(6 * 3600), ongoingUntil: now)
            let recorded = await (try? (history as? any DailyHistoryStore)?.series(
                metric: .cpu, app: nil, from: today.addingTimeInterval(3600), to: today.addingTimeInterval(5 * 3600)
            )) ?? []
            if recorded.count >= 8 {
                inputs.awakeLastNight = asleep.reduce(0) { $0 + $1.duration } < 3600
            }
        }
    }

    private static func add(_ cleanup: Reclaimable, to inputs: inout CheckupInputs) {
        inputs.oldMessagesBytes = cleanup.messages
        inputs.oldBackups = cleanup.backups.map { ($0.bytes, $0.oldest) }
        inputs.trashBytes = cleanup.trash
        inputs.reclaimableBytes = cleanup.total
    }

    /// What history has learned: today out of the ordinary (D-198), updates that made something
    /// heavier (D-206).
    static func addLearned(to inputs: inout CheckupInputs, _ services: AppServices, now: Date) async {
        await services.unusual.refresh(services, now: now)
        inputs.unusual = services.unusual.found
        await services.updates.refresh(services, now: now)
        inputs.heavierUpdates = services.updates.heavier
        await services.builds.refresh(services, now: now)
        // Unnamed projects aren't news anyone can act on.
        inputs.slowerBuilds = services.builds.slower.filter { !$0.project.isEmpty }
        // Hangs over four weeks for the trend (D-212).
        inputs.worseHangs = await HangTrend.worse(services.crashReports.reports(since: now.addingTimeInterval(-28 * 86400)), now: now)
        inputs.heavySleep = await heavySleep(services, now: now)
        if let status = services.storageScanner.timeMachine(), status.hasStopped(now: now), let last = status.lastBackup {
            inputs.timeMachineStopped = (Int(now.timeIntervalSince(last) / 86400), last)
        }
        if let store = services.history as? any AppLaunchStore {
            let launches = await (try? store.launches(from: now.addingTimeInterval(-35 * 86400), to: now)) ?? []
            inputs.slowerLaunches = AppLaunchTimes.byApp(launches, now: now).filter(\.isSlower)
        }
    }

    /// The latest sleep, ended in the last 18 hours, when it drained the battery fast (D-213).
    static func heavySleep(_ services: AppServices, now: Date) async -> SleepSpan? {
        guard services.metrics.hardware.hasBattery, let power = services.history as? any PowerEventStore,
              let daily = services.history as? any DailyHistoryStore else {
            return nil
        }
        let events = await (try? power.powerEvents(days: 2)) ?? []
        return await SleepLevels.spans(events, levels: daily, limit: 2)
            .first { $0.end >= now.addingTimeInterval(-18 * 3600) && $0.isHeavyDrain }
    }

    /// Fresh: the list only refreshes itself while Projects shows, so it could be empty (never
    /// opened) or hours old, naming servers long stopped (D-142).
    static func idleServers(_ services: AppServices) async -> (count: Int, memory: UInt64) {
        await services.projects.refresh()
        let idle = services.projects.idleServers
        return (idle.count, idle.reduce(0) { $0 + $1.memoryBytes })
    }
}
