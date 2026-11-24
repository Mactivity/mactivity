import Alerts
import AppKit
import Audio
import Core
import Docker
import Foundation
import Grouping
import History
import Observation
import os
import Projects
import Readouts
import Sampling
import Sensors
import Simulated
import Startup
import Storage
import UI

/// Owns the data pipeline and decides real versus simulated. The only place in the app that
/// names concrete sources; views only see protocols (CLAUDE.md rule 1).
///
/// One `SnapshotSource` feeds three subscribers: `LiveMetrics` (views), the history store, and
/// the alert monitor (spec 6.13).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    fileprivate nonisolated static let log = Logger(subsystem: "app.mactivity.app", category: "model")

    let services: AppServices

    /// The "Simulated data" toggle. Persisted.
    var isSimulated: Bool {
        didSet {
            guard isSimulated != oldValue else {
                return
            }
            defaults.set(isSimulated, forKey: PreferenceKey.simulatedData)
            let state = isSimulated ? "on" : "off"
            Self.log.info("Simulated data \(state)")
            if startsServices {
                startPipeline()
            }
        }
    }

    /// False for a model a test makes: it reads and writes its settings, and nothing else.
    @ObservationIgnored private let startsServices: Bool

    @ObservationIgnored private let defaults: UserDefaults
    /// Latest figures for the desktop widgets (E7). Nil in ad-hoc builds: no team, no app group.
    @ObservationIgnored private let widgetFeed: WidgetFeed?
    /// Control Center's controls (D-210); nil without a widget feed.
    @ObservationIgnored let controls: ControlPublisher?
    @ObservationIgnored var pipeline: Pipeline?
    /// Waiting to see whether a lost connection stays lost (D-149).
    @ObservationIgnored var offlineWait: Task<Void, Never>?
    /// Turns per-app volume on and off with its Settings toggle.
    @ObservationIgnored private var perAppVolumeObservation: NSKeyValueObservation?

    struct Pipeline {
        let source: any SnapshotSource
        let store: SQLiteHistoryStore
        let monitor: AlertMonitor
        let tasks: [Task<Void, Never>]
    }

    /// `startsServices: false` (tests) skips everything that reaches outside the model: the
    /// sampling, history, the helper, sleep and wake, the weekly digest.
    init(defaults: UserDefaults = .standard, startsServices: Bool = true) {
        self.defaults = defaults
        self.startsServices = startsServices
        widgetFeed = WidgetFeed.forThisApp()
        controls = widgetFeed.map { ControlPublisher(widgetFile: $0.fileURL) }
        let simulated = defaults.bool(forKey: PreferenceKey.simulatedData)
        isSimulated = simulated
        let settings = AlertSettings.decode(defaults.string(forKey: PreferenceKey.alertSettings) ?? "")
        let placeholder = SimulatedSnapshotSource()
        let placeholderServers = SimulatedDevServers()
        services = AppServices(
            metrics: LiveMetrics(source: placeholder, isSimulated: simulated),
            history: SimulatedHistoryStore(),
            alertLog: SimulatedAlertStateStore(),
            alertSettings: settings,
            projects: placeholderServers,
            terminator: placeholderServers
        ) { [defaults] settings in
            defaults.set(settings.encoded(), forKey: PreferenceKey.alertSettings)
            Task { @MainActor in await AppModel.shared.pipeline?.monitor.updateSettings(settings) }
        }
        services.requestNotificationAuthorization = { await NotificationDeliverer.requestAuthorization() }
        // Screenshots and the demo video run in an empty home folder that was never asked for
        // notifications; "can't send notifications" would lead every Checkup and Alerts shot.
        if !LaunchOverrides.isScreenshotMode {
            services.notificationPermissionSource = UserNotificationPermission()
        }
        services.controls = Self.makeControls()
        services.metrics.visibleInterval = .seconds(
            LiveMetrics.clampedVisibleSeconds(defaults.object(forKey: PreferenceKey.visibleIntervalSeconds) as? Int ?? 1)
        )
        // The page that was showing at the last quit or update (not in screenshots or the demo
        // video, which pick their own).
        if !LaunchOverrides.isScreenshotMode, !LaunchOverrides.isDemoTour {
            services.restoreLaunchState(from: defaults, version: BuildInfo.main().version)
        }
        // `make measure TAB=cpu` opens the main window on one tab (scripts/measure.sh).
        if let tab = defaults.string(forKey: "MeasureInitialTab").flatMap(SidebarItem.init(rawValue:)) {
            services.navigation.selection = tab
        }
        guard startsServices else {
            return
        }
        DigestScheduler.shared.start(services: services)
        let helperOn = HelperControl.status == .on
        Task { await AppModel.helperSource.setEnabled(helperOn) }
        startPipeline()
        // The stores are real now: a digest due at launch goes out (D-139).
        DigestScheduler.shared.check(services: services)
        observePerAppVolume()
        recordSleepAndWake()
        watchExpensiveNetwork()
        watchConnection()
        focus.start()
    }

    // MARK: - Sleep and wake (D-096)

    @ObservationIgnored let networkRecorder = NetworkRecorder()
    @ObservationIgnored var powerObservers: [NSObjectProtocol] = []
    /// Time in front (D-098): into the running pipeline's store, unless turned off or simulated.
    @ObservationIgnored private lazy var focus = FocusRecorder { [weak self] in
        guard let self, !self.isSimulated,
              defaults.object(forKey: PreferenceKey.recordsTimeInFront) as? Bool ?? true
        else {
            return nil
        }
        return pipeline?.store
    }

    /// The app-level switches the views call (ServiceManagement, Sparkle, the helper, Bluetooth).
    private static func makeControls() -> AppControls {
        var controls = AppControls()
        controls.isLaunchAtLoginEnabled = { LaunchAtLogin.isEnabled }
        controls.setLaunchAtLogin = { LaunchAtLogin.set($0) }
        controls.cleanKeyboard = { KeyboardLockController.shared.lock() }
        controls.launchAtLoginNeedsApproval = { LaunchAtLogin.needsApproval }
        controls.openLoginItemsSettings = { LaunchAtLogin.openLoginItemsSettings() }
        controls.updatesConfigured = Updates.shared.isConfigured
        controls.checkForUpdates = { Updates.shared.checkForUpdates() }
        controls.helperStatus = { HelperControl.status }
        controls.setHelper = { wanted in
            let status = HelperControl.set(wanted)
            Task { await AppModel.helperSource.setEnabled(status == .on) }
            return status
        }
        controls.accessoryBatteryAccess = { BluetoothAccess.status }
        controls.requestAccessoryBatteryAccess = { await BluetoothAccess.shared.request() }
        return controls
    }

    /// The real audio source follows the flag whether or not simulated data is on: its taps act on real apps.
    /// Off (the default), it runs nothing: no taps, no HAL listeners, no timers.
    private func observePerAppVolume() {
        perAppVolumeObservation = defaults.observe(\.perAppVolume, options: [.initial, .new]) { [weak self] _, _ in
            // Read when the task runs, not from the change, so tasks that run out of order still settle on the
            // latest value.
            Task { @MainActor in
                guard let self else {
                    return
                }
                await Self.audio.setEnabled(self.defaults.perAppVolume)
            }
        }
    }

    /// Writes the minute in progress and hands every tapped app's audio back. Called on quit.
    func flush() async {
        await focus.flush()
        try? await pipeline?.store.flush()
        await Self.audio.reset()
    }

    /// Per-app volume (M10, experimental). Remembered per-app settings live in UserDefaults.
    static let audio = CoreAudioSource(store: .standardDefaults())
    /// Accessory batteries for their history (D-094). Its own sampler: only its peripheral read is used.
    static let devices = SensorSampler()
    /// Get Info and per-app connections.
    static let processDetails = LiveProcessDetailsSource()
    /// Whether the Mac is on an iPhone's hotspot (D-136): changes arrive from Network, no polling.
    static let expensiveNetwork = ExpensiveNetworkWatcher()

    /// Runaway dev processes (D-156): where each runs is looked up only when one is found.
    private static func checkRunaways(
        _ runaway: inout RunawayWatch, _ snapshot: Snapshot, monitor: AlertMonitor, services: AppServices, simulated: Bool
    ) async {
        let stuckAfter = services.alertSettings.settings(for: .runawayProcess).threshold * 60
        let findings = runaway.observe(snapshot, stuckAfter: stuckAfter)
        if !findings.isEmpty {
            let reports = runawayReports(findings, in: snapshot, simulated: simulated)
            await monitor.checkSystem(SystemAlertInputs(runaways: reports), now: snapshot.at)
        }
    }

    private func startPipeline() {
        pipeline?.tasks.forEach { $0.cancel() }
        let simulated = isSimulated
        // `-SimulateDesktopMac YES`: simulated data without a battery, to see the Energy tab.
        let source: any SnapshotSource = simulated
            ? SimulatedSnapshotSource(hasBattery: !defaults.bool(forKey: "SimulateDesktopMac"))
            : Self.liveSampler()
        let store = Self.historyStore(simulated: simulated, retentionDays: retentionDays)
        let deliverer: any AlertDeliverer = simulated ? SimulatedAlertDeliverer() : Self.holdingDeliverer()
        let monitor = AlertMonitor(deliverer: deliverer, store: store, settings: services.alertSettings)

        services.metrics.replaceSource(source, isSimulated: simulated)
        replaceSystemSources(simulated: simulated)
        services.replaceStores(history: store, alertLog: store)
        let projectMonitor = replaceProjectSources(simulated: simulated)

        if simulated, LaunchOverrides.isScreenshotMode {
            fillForScreenshots(store: store)
        }

        let services = services
        // Simulated figures never reach the widgets.
        let widgetFeed = simulated ? nil : widgetFeed
        let agents = AgentHistoryRecorder(source: simulated ? SimulatedAgentSource() : LiveAgentSource())
        let todayWidget = widgetFeed.map(TodayWidgetUpdater.init)
        // Simulated Xcode always has a compiler running: one endless build, in no real folder.
        let builds = simulated ? nil : BuildRecorder()
        // Network changes and Wi-Fi into the real store only (D-233, D-234).
        let network = simulated ? nil : networkRecorder.attached(to: store)
        // Camera and microphone history, from the real Mac only (D-259).
        let sensors = simulated ? nil : SensorRecorder(source: LiveSensorActivity(), store: store as? any SensorHistoryStore)
        let recorder = Task { @MainActor in
            var heat = HeatCheck()
            var runaway = RunawayWatch()
            for await snapshot in await source.snapshots() {
                await recordTick(
                    snapshot, frontmost: FrontmostApp.shared.bundleID, store: store, monitor: monitor, projects: projectMonitor
                )
                services.hotspot.record(snapshot)
                services.recording.record(snapshot)
                widgetFeed?.consider(snapshot)
                if let inputs = heat.consider(snapshot, threshold: services.alertSettings.settings(for: .overheating).threshold) {
                    await monitor.checkSystem(inputs, now: snapshot.at)
                }
                await Self.checkRunaways(&runaway, snapshot, monitor: monitor, services: services, simulated: simulated)
                await agents.observe(snapshot, store: store, monitor: monitor)
                await network?.observe(snapshot)
                sensors?.observe(snapshot)
                // Notifications by app, from the real Mac only (D-289).
                if !simulated {
                    services.notifications.observe(at: snapshot.at, store: store)
                }
                await builds?.observe(snapshot, store: store)
                AppModel.shared.controls?.update(stayAwake: services.keepAwake.isOn)
                await todayWidget?.observe(snapshot, services: services)
            }
        }
        let devices = slowChecks(devices: simulated ? SimulatedPeripheralSource() : Self.devices, store: store, monitor: monitor)
        let listener = Task { @MainActor [services] in
            for await alert in await monitor.firedAlerts() {
                services.noteAlert(alert)
            }
        }
        // Flush the previous store before it goes away so no minute is lost on a toggle.
        if let old = pipeline?.store {
            Task { try? await old.flush() }
        }
        pipeline = Pipeline(source: source, store: store, monitor: monitor, tasks: [recorder, listener, devices])
    }

    /// Dev servers, containers, startup items and agents: live, or simulated ones together.
    private func replaceProjectSources(simulated: Bool) -> ProjectMonitor? {
        let projectMonitor: ProjectMonitor? = simulated ? nil : ProjectMonitor()
        if let projectMonitor {
            services.replaceProjects(projectMonitor, terminator: SignalTerminator())
            services.replaceContainers(DockerContainerSource(), terminator: DockerTerminator(), restarter: DockerController())
            services.startup.replace(source: LaunchdStartupSource(), toggle: UserLaunchAgentToggle.user)
            services.agents.replaceSource(LiveAgentSource())
        } else {
            let servers = SimulatedDevServers()
            services.replaceProjects(servers, terminator: servers)
            let containers = SimulatedContainerSource()
            services.replaceContainers(containers, terminator: containers, restarter: containers)
            let startup = SimulatedStartupSource()
            services.startup.replace(source: startup, toggle: startup)
            services.agents.replaceSource(SimulatedAgentSource())
        }
        return projectMonitor
    }

    private var retentionDays: Int {
        let days = defaults.integer(forKey: PreferenceKey.historyRetentionDays)
        return days > 0 ? days : HistoryRetention.defaultDays
    }

    /// Reads processes through the helper when it's on, locally otherwise (spec 6.9).
    static let helperSource = HelperProcessSource(teamID: HelperControl.teamID)

    private func fillForScreenshots(store: SQLiteHistoryStore) {
        let services = services
        Task { @MainActor in
            let source = SimulatedSnapshotSource()
            let recorded = SimulatedHistoryStore()
            var snapshots: [Snapshot] = []
            for _ in 0 ..< LiveMetrics.historyLength {
                let snapshot = await source.next()
                snapshots.append(snapshot)
                try? await recorded.record(snapshot)
            }
            services.metrics.backfill(snapshots)
            services.replaceStores(history: SimulatedThirtyDayHistory(apps: recorded), alertLog: store)
            for alert in SimulatedAlerts.recent() {
                try? await store.recordAlert(alert)
            }
            await services.reloadAlerts()
        }
    }

    /// The real history file; simulated data goes to memory so it never mixes with real history.
    private static func historyStore(simulated: Bool, retentionDays: Int) -> SQLiteHistoryStore {
        if !simulated {
            do {
                return try SQLiteHistoryStore.openRecovering(url: SQLiteHistoryStore.defaultURL(), retentionDays: retentionDays)
            } catch {
                log.error("Couldn't open history, keeping it in memory: \(String(describing: error))")
            }
        }
        do {
            return try SQLiteHistoryStore(url: nil, retentionDays: retentionDays)
        } catch {
            // An in-memory SQLite database failing to open means the process is out of memory.
            preconditionFailure("In-memory history store failed: \(error)")
        }
    }
}

extension UserDefaults {
    /// `PreferenceKey.perAppVolume`, exposed for key-value observing. The property name must match the key.
    @objc dynamic var perAppVolume: Bool {
        bool(forKey: PreferenceKey.perAppVolume)
    }
}

/// The frontmost app's bundle ID, updated on activation. Reading it from `NSRunningApplication`
/// every tick is a LaunchServices round trip.
@MainActor
final class FrontmostApp {
    static let shared = FrontmostApp()

    private(set) var bundleID: String?
    private var observer: NSObjectProtocol?

    private init() {
        bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated { FrontmostApp.shared.bundleID = id }
        }
    }
}

/// A tick's writes, in one trip to the sampling thread. History, alerts and projects all live on
/// it, so coming back to the main thread between them was two round trips for nothing (D-267).
private func recordTick(
    _ snapshot: Snapshot, frontmost: String?, store: SQLiteHistoryStore, monitor: isolated AlertMonitor, projects: ProjectMonitor?
) async {
    do {
        try await store.record(snapshot)
    } catch {
        AppModel.log.error("History record failed: \(String(describing: error))")
    }
    await monitor.ingest(snapshot, frontmostAppID: frontmost)
    await projects?.observe(snapshot)
}
