import Alerts
import AppKit
import Core
import Foundation
import History
import Projects
import Sampling
import Startup
import UI

/// Sleep and wake (D-096), app launches (D-215) and the 10-minute checks (D-094, D-099), apart
/// from AppModel's pipeline.
extension AppModel {
    /// Records each sleep and wake as it happens into the running pipeline's store;
    /// simulated data never mixes with real events.
    func recordSleepAndWake() {
        // App launch times (D-215), into the running pipeline's real store only.
        LaunchRecorder.shared.start {
            AppModel.shared.isSimulated ? nil : AppModel.shared.pipeline?.store
        }
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, PowerEvent.Kind)] = [
            (NSWorkspace.willSleepNotification, .sleep),
            (NSWorkspace.didWakeNotification, .wake),
        ]
        powerObservers = events.map { name, kind in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                let event = PowerEvent(at: Date(), kind: kind, reason: kind == .wake ? WakeReason.current() : nil)
                MainActor.assumeIsolated {
                    // Network stretches stop at sleep and start again at wake (D-236).
                    if kind == .sleep {
                        Task { await AppModel.shared.networkRecorder.pause() }
                    } else {
                        AppModel.shared.networkRecorder.resume()
                    }
                    guard let store = AppModel.shared.pipeline?.store, !AppModel.shared.isSimulated else {
                        return
                    }
                    Task { try? await store.recordPowerEvent(event) }
                }
            }
        }
        // The Mac's time zone changed, or the day turned over: every day boundary moved, so
        // History, Today and the week reload against the Mac's clock (D-220).
        powerObservers += [Notification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    NSTimeZone.resetSystemTimeZone()
                    AppModel.shared.services.historyDidChange()
                }
            }
        }
    }

    /// An iPhone's hotspot or another expensive connection (D-136): the model starts a session
    /// when it begins. Real connections only; simulated data has its own.
    func watchExpensiveNetwork() {
        let hotspot = services.hotspot
        let apply: @Sendable (ExpensiveNetworkWatcher.State) -> Void = { state in
            Task { @MainActor in hotspot.update(isExpensive: state.isExpensive, isConstrained: state.isConstrained) }
        }
        Self.expensiveNetwork.onChange(apply)
        apply(Self.expensiveNetwork.state)
        // Network changes, from the same watcher (D-233).
        networkRecorder.start(watcher: Self.expensiveNetwork)
    }

    /// No connection for the rule's time, awake (D-149): a sleep never counts, since the wait
    /// runs on the suspending clock, and the Mac reconnecting first cancels it. Event-driven.
    func watchConnection() {
        let apply: @Sendable (ExpensiveNetworkWatcher.State) -> Void = { state in
            Task { @MainActor in AppModel.shared.connectionChanged(isConnected: state.isConnected) }
        }
        Self.expensiveNetwork.onChange(apply)
    }

    func connectionChanged(isConnected: Bool) {
        offlineWait?.cancel()
        offlineWait = nil
        guard !isConnected, !isSimulated else {
            return
        }
        let seconds = services.alertSettings.settings(for: .connectionLost).threshold
        offlineWait = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds), clock: .suspending)
            guard let self, !Task.isCancelled, !Self.expensiveNetwork.state.isConnected, let monitor = pipeline?.monitor else {
                return
            }
            await monitor.checkSystem(SystemAlertInputs(offlineFor: seconds))
        }
    }

    /// New startup items since the last look, kept across launches, so one added while
    /// Mactivity wasn't running is caught at the next start (D-231). 14 ms a look.
    static func startupAdditions(defaults: UserDefaults = .standard) async -> [StartupAddition] {
        // Not Mactivity's own login item: turning on Open at Login isn't news (D-236).
        guard let items = try? await LaunchdStartupSource(includesMainApp: false).items() else {
            return []
        }
        let known = defaults.stringArray(forKey: StartupWatch.defaultsKey).map(Set.init)
        let (new, keep) = StartupWatch.additions(items, known: known)
        defaults.set(keep.sorted(), forKey: StartupWatch.defaultsKey)
        return StartupWatch.additions(grouping: new)
    }

    /// The month's data against the budget, when one is set (D-235).
    static func dataBudgetStatus(store: SQLiteHistoryStore, now: Date) async -> DataBudgetStatus? {
        guard let budget = DataBudgetModel.saved() else {
            return nil
        }
        let period = budget.period(containing: now)
        let used = await (try? store.systemTotal(metrics: [.netIn, .netOut], from: period.start, to: now)) ?? 0
        return DataBudgetStatus(budget: budget, period: period, used: used, now: now)
    }

    /// Every 10 minutes (D-094, D-099): accessory batteries into history, then the Mac-level
    /// alert rules. A few IORegistry reads, one bluetoothd query, a directory listing and a few
    /// small history queries: nothing that grows with how busy the Mac is.
    func slowChecks(
        devices source: any PeripheralBatterySource, store: SQLiteHistoryStore, monitor: AlertMonitor
    ) -> Task<Void, Never> {
        let services = services
        return Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            var forecast: (at: Date, days: Double?)?
            var peaksAt: Date?
            while !Task.isCancelled {
                let now = Date()
                // Each app's usual daily peak memory, hourly, for the growing-memory alert (D-218).
                if peaksAt.map({ now.timeIntervalSince($0) >= 3600 }) ?? true {
                    peaksAt = now
                    await monitor.updateUsualPeakMemory(Self.usualPeakMemory(store: store, now: now))
                }
                let devices = await source.peripherals()
                try? await store.recordDevices(devices, at: now)
                // The desk: displays and the lid, 28 ms, for the Next Mac advice (D-237).
                if !AppModel.shared.isSimulated {
                    try? await store.recordDesk(LiveDesk().sample(at: now))
                }
                if forecast.map({ now.timeIntervalSince($0.at) > 6 * 3600 }) ?? true {
                    let days = await (try? store.dailyValues(metric: .diskFree, days: 30)) ?? []
                    forecast = (now, DiskForecast.daysUntilFull(days))
                }
                let window = services.alertSettings.settings(for: .appCrashing).window.seconds
                let reports = await services.crashReports.reports(since: now.addingTimeInterval(-window))
                // What added itself to start with the Mac since the last look (D-231).
                let additions = AppModel.shared.isSimulated ? [] : await Self.startupAdditions()
                let budget = await Self.dataBudgetStatus(store: store, now: now)
                // Software needing security updates (D-252): read every 6 hours, checked daily when on.
                var urgentSoftware: [(item: InstalledSoftware, concern: SoftwareConcern)] = []
                if !AppModel.shared.isSimulated, services.alertSettings.settings(for: .vulnerableSoftware).isEnabled {
                    await services.software.refresh(now: now)
                    // An app's old updater is for Checkup, not a notification each (D-257): a first look can
                    // find a dozen apps at once.
                    urgentSoftware = services.software.findings(now: now).filter { $0.concern.isUrgent && $0.item.origin != .appUpdater }
                }
                var inputs = await SystemAlertInputs(
                    devices: devices,
                    diskDaysUntilFull: forecast?.days,
                    diskName: services.metrics.snapshot?.system.disk.bootVolume?.name ?? "Macintosh HD",
                    crashes: Self.crashCounts(reports),
                    // A night Stay Awake held on purpose isn't one that didn't sleep.
                    awakeOvernight: Self.keptAwakeOvernight(services.keepAwake, now: now) ? nil : Self.awakeOvernight(
                        store: store,
                        now: now
                    ),
                    awakeBecause: services.sleepBlockers.blockers().map(\.app.name),
                    hotspotUsage: services.hotspot.takeRecent(),
                    diskFreeBytes: services.metrics.snapshot?.system.disk.bootVolume?.freeBytes,
                    unusual: unusualToday(store: store, now: now),
                    startupAdditions: additions,
                    dataBudget: budget
                )
                inputs.urgentSoftware = urgentSoftware
                await monitor.checkSystem(inputs, now: now)
                // A digest due while the screen stayed on all morning (D-139).
                DigestScheduler.shared.check(services: services)
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// Out of the ordinary, for its alert (D-201): with the rule on, and only once two hours of
    /// today are in history, so a short morning doesn't stand for the day. The comparison is
    /// Overview's, read at most every half hour.
    private func unusualToday(store: SQLiteHistoryStore, now: Date) async -> [UnusualUsage] {
        guard services.alertSettings.settings(for: .outOfTheOrdinary).isEnabled else {
            return []
        }
        let midnight = Calendar.current.startOfDay(for: now)
        let recorded = await (try? store.series(metric: .cpu, app: nil, from: midnight, to: now)) ?? []
        // History reads minutes for the first three hours of a day, quarter-hours after.
        let bucket: TimeInterval = now.timeIntervalSince(midnight) <= 3 * 3600 ? 60 : 900
        guard Double(recorded.count) * bucket >= 2 * 3600 else {
            return []
        }
        await services.unusual.refresh(services, now: now)
        return services.unusual.found
    }

    /// The 30 apps using the most memory over two weeks, each with its usual daily peak: about 30
    /// reads of hourly rows, once an hour.
    private static func usualPeakMemory(store: SQLiteHistoryStore, now: Date) async -> [AppIdentity.ID: Double] {
        let start = now.addingTimeInterval(-14 * 86400)
        let apps = await (try? store.topApps(metric: .memory, from: start, to: now, limit: 30)) ?? []
        var peaks: [AppIdentity.ID: Double] = [:]
        for app in apps {
            let points = await (try? store.series(metric: .memory, app: app.app.id, from: start, to: now)) ?? []
            peaks[app.app.id] = MemoryPeaks.usual(points)
        }
        return peaks
    }

    private static func keptAwakeOvernight(_ keepAwake: KeepAwakeModel, now: Date) -> Bool {
        let midnight = Calendar.current.startOfDay(for: now)
        return keepAwake.wasOn(from: midnight, to: midnight.addingTimeInterval(6 * 3600), now: now)
    }

    /// Each finding with its app, and for real processes the project and the agent behind it.
    static func runawayReports(_ findings: [RunawayWatch.Finding], in snapshot: Snapshot, simulated: Bool) -> [RunawayReport] {
        let apps = Dictionary(snapshot.apps.map { ($0.id, $0.app) }, uniquingKeysWith: { first, _ in first })
        return findings.map { finding in
            let context = simulated ? (project: nil, agent: nil) : ProcessContext.describe(finding.pid)
            return RunawayReport(
                finding: finding, app: apps[finding.app] ?? .system, project: context.project, agent: context.agent
            )
        }
    }

    /// Crash reports per app, of apps and of the version installed (`CrashFilter`), with the app's icon.
    private static func crashCounts(_ reports: [CrashReport]) -> [AppIdentity: Int] {
        var counts: [AppIdentity: Int] = [:]
        for report in CrashFilter.relevant(reports) {
            let url = report.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            let app = AppIdentity(
                id: report.bundleID ?? "crash:\(report.appName)", name: report.appName, bundleID: report.bundleID,
                iconKey: url?.path ?? "other", kind: .app
            )
            counts[app, default: 0] += 1
        }
        return counts
    }

    /// Mornings only (6 to noon): true when history shows the Mac recording between 1 and 5 am
    /// with under an hour asleep between midnight and 6. Nil otherwise, or when Mactivity wasn't
    /// running overnight to know.
    private static func awakeOvernight(store: SQLiteHistoryStore, now: Date) async -> Bool? {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        guard (6 ..< 12).contains(hour) else {
            return nil
        }
        let midnight = calendar.startOfDay(for: now)
        let recorded = await (try? store.series(
            metric: .cpu, app: nil, from: midnight.addingTimeInterval(3600), to: midnight.addingTimeInterval(5 * 3600)
        )) ?? []
        // Eight quarter-hours: two hours of the four seen awake.
        guard recorded.count >= 8 else {
            return nil
        }
        let events = await (try? store.powerEvents(days: 2)) ?? []
        let asleep = SleepTimeline.asleep(events, from: midnight, to: midnight.addingTimeInterval(6 * 3600), ongoingUntil: now)
        return asleep.reduce(0) { $0 + $1.duration } < 3600
    }
}
