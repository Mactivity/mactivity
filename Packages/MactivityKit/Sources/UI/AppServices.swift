import Core
import Docker
import Foundation
import Observation
import Projects
import Simulated
import Storage

/// The Storage cleanups Checkup links to (D-196).
public enum HelperStatus: Sendable, Equatable {
    /// Ad-hoc builds can't pin code signatures, so the helper is unavailable.
    case needsSignedBuild
    case off
    case needsApproval
    case on
}

/// Whether Mactivity may read Bluetooth accessory batteries (AirPods).
public enum AccessoryBatteryAccess: Sendable {
    case notAsked, allowed, denied
    /// Previews and tests: no Bluetooth.
    case unavailable
}

/// App-level switches the app target owns (ServiceManagement, Sparkle, the helper). Views call
/// these closures; they never import those frameworks themselves.
@MainActor
public struct AppControls {
    public var isLaunchAtLoginEnabled: () -> Bool = { false }
    public var setLaunchAtLogin: (Bool) -> Bool = { _ in false }
    public var launchAtLoginNeedsApproval: () -> Bool = { false }
    public var openLoginItemsSettings: () -> Void = {}
    public var updatesConfigured = false
    public var checkForUpdates: () -> Void = {}
    public var helperStatus: () -> HelperStatus = { .needsSignedBuild }
    public var setHelper: (Bool) -> HelperStatus = { _ in .needsSignedBuild }
    /// Bluetooth access for AirPods batteries. Reading never prompts; requesting shows the prompt once.
    public var accessoryBatteryAccess: () -> AccessoryBatteryAccess = { .unavailable }
    public var requestAccessoryBatteryAccess: () async -> AccessoryBatteryAccess = { .unavailable }
    /// Locks the keyboard for cleaning (D-203): the app's event tap.
    public var cleanKeyboard: () -> Void = {}

    public init() {}
}

/// Everything the views need, behind protocols. The app target builds it and swaps its contents
/// when "Simulated data" changes; views never name a concrete source (CLAUDE.md rule 1).
@MainActor
@Observable
public final class AppServices {
    public let metrics: LiveMetrics
    public let navigation = AppNavigation()
    /// "Why is my Mac slow?" (D-134).
    public let slowdown = SlowdownModel()
    /// Apps open but unused (D-135).
    public let unusedApps = UnusedAppsModel()
    /// Data used on an iPhone's hotspot (D-136).
    public let hotspot = HotspotModel()
    /// Stay Awake (D-147, renamed D-162).
    public let keepAwake = KeepAwakeModel()
    /// AI coding agent sessions (D-148).
    public let agents = AgentsModel(source: SimulatedAgentSource())
    /// One app's history page (D-168).
    public let appHistory = AppHistoryModel()
    /// "Your next Mac": what to look for, from 7 or 30 days of use (D-181).
    public let nextMac = NextMacModel()
    public let compareMacs = CompareMacsModel()
    /// What's out of the ordinary today (D-198).
    public let unusual = UnusualModel()
    /// After an update (D-206).
    public let updates = UpdatesModel()
    /// Build times (D-209).
    public let builds = BuildsModel()
    /// Two days or weeks side by side (D-207).
    public let compare = CompareModel()
    /// After an update, Overview's notice and the release notes (D-179). The app sets it at launch.
    public var whatsNew = WhatsNewModel()
    /// Ask Mactivity, in Quick Search (D-153).
    public let ask = AskModel()
    /// Record a moment (D-151).
    public let recording = RecordingModel()
    /// The connection line on the Network tab (D-149).
    public let networkDetails = NetworkDetailsModel(source: SimulatedNetworkDetails())
    public let networkInterfaces = NetworkInterfacesModel(source: SimulatedNetworkInterfaces())
    /// Crowded Wi-Fi channels (D-286).
    public let wifiChannels = WiFiChannelsModel(source: SimulatedWiFiScan())
    /// Configuration profiles and unlocks on the Security page (D-287, D-288).
    public let profiles = ProfilesModel(source: SimulatedProfiles())
    public let unlocks = UnlocksModel(source: SimulatedUnlocks())
    /// Notifications by app (D-289).
    public let notifications = NotificationsModel(source: SimulatedNotificationLog())
    /// What the Photos library takes, on the Storage page (D-283).
    public let photosLibrary = PhotosLibraryModel(source: SimulatedPhotosLibrary())
    /// External and network drives on the Disk tab (D-284, D-285).
    public let mountedDrives = MountedDrivesModel(source: SimulatedMountedDrives())
    /// Per-app volume (spec 5.7). Replaced by the app; simulated by default.
    @ObservationIgnored public var audio: any AudioSource = SimulatedAudioSource()
    /// Get Info and per-app connections (expansions E12, E1). Replaced by the app; simulated by default.
    @ObservationIgnored public var processDetails: any ProcessDetailsSource = SimulatedProcessDetailsSource()
    /// Drives' own health reports, read when the Disk tab or Checkup asks (D-157).
    @ObservationIgnored public var driveHealth: any DriveHealthSource = SimulatedDriveHealth()
    /// Renderer arguments for the browser split (D-154).
    @ObservationIgnored public var processArguments: any ProcessArgumentReading = SimulatedProcessArguments()
    /// What's keeping the Mac awake (D-096): read only while a view shows it.
    @ObservationIgnored public var sleepBlockers: any SleepBlockerSource = SimulatedSleepBlockers()
    /// Crash and hang reports (D-098): read while a view shows them, and by the alert check.
    @ObservationIgnored public var crashReports: any CrashReportSource = SimulatedCrashReports()
    @ObservationIgnored public var softwareUpdates: any SoftwareUpdateSource = SimulatedSoftwareUpdates()
    /// What macOS flagged (D-212).
    @ObservationIgnored public var macReports: any MacReportSource = SimulatedMacReports() {
        didSet { macReportsCache = nil }
    }

    /// The last 30 days of them, read at most every 5 minutes: Checkup reads them each time the
    /// menu bar window or Overview opens.
    @ObservationIgnored private var macReportsCache: (at: Date, reports: [MacReport])?

    /// What macOS flagged in the last `days` days (up to 30), newest first.
    func recentMacReports(days: Double, now: Date = Date()) async -> [MacReport] {
        if macReportsCache.map({ now.timeIntervalSince($0.at) > 300 || now < $0.at }) ?? true {
            macReportsCache = await (now, macReports.macReports(since: now.addingTimeInterval(-30 * 86400)))
        }
        let since = now.addingTimeInterval(-days * 86400)
        return (macReportsCache?.reports ?? []).filter { $0.at >= since }
    }

    public let projects: ProjectsModel
    /// The only way to stop anything (CLAUDE.md rule 4).
    public let confirmedAction: ConfirmedAction
    /// Docker containers in Projects (expansion E5). Stops route through `confirmedAction`;
    /// restarts through the model's own `restartAction`.
    public let containers: ContainersModel
    /// Login items, launch agents, and daemons (expansion E4). Simulated until the app swaps it.
    public let startup = StartupModel.preview()
    /// Storage map (expansion E10). Replaced by the app; simulated by default. A new scanner
    /// starts a new model.
    public var storageScanner: any StorageScanning = SimulatedStorageScanner() {
        didSet {
            releaseStorage()
            projectSpace = makeProjectSpace()
        }
    }

    /// Space per project (D-223). Replaced by the app; simulated by default. Its scan is kept
    /// while the app runs: it's quick, and sizes change slowly.
    public var projectSpaceScanner: any ProjectSpaceScanning = SimulatedProjectSpaceScanner() {
        didSet { projectSpace = makeProjectSpace() }
    }

    private(set) var projectSpace = ProjectSpaceModel(scanner: SimulatedProjectSpaceScanner(), trasher: SimulatedStorageScanner().trasher)

    /// Homebrew services (D-225). Replaced by the app; simulated by default.
    /// Outdated Software (D-252): replaced by the app; simulated by default.
    public let software = OutdatedSoftwareModel()
    public var softwareSource: any InstalledSoftwareSource = SimulatedInstalledSoftware() {
        didSet { software.setSource(softwareSource) }
    }

    public var homebrewSource: any HomebrewServiceSource = SimulatedHomebrewServices() {
        didSet { homebrewServices = HomebrewServicesModel(source: homebrewSource) }
    }

    private(set) var homebrewServices = HomebrewServicesModel(source: SimulatedHomebrewServices())

    /// Simulators and emulators (D-226).
    public var devDeviceSource: any DevDeviceSource = SimulatedDevDevices() {
        didSet { devDevices = DevDevicesModel(source: devDeviceSource) }
    }

    private(set) var devDevices = DevDevicesModel(source: SimulatedDevDevices())

    /// Background dev tools (D-228).
    public var devToolSource: any DevToolSource = SimulatedDevTools() {
        didSet { devTools = DevToolsModel(source: devToolSource) }
    }

    private(set) var devTools = DevToolsModel(source: SimulatedDevTools())

    /// Local databases (D-277). Replaced by the app; simulated by default.
    public var localDatabaseSource: any LocalDatabaseSource = SimulatedLocalDatabases() {
        didSet { localDatabases = LocalDatabasesModel(source: localDatabaseSource) }
    }

    private(set) var localDatabases = LocalDatabasesModel(source: SimulatedLocalDatabases())

    /// Projects at a glance (D-279). Replaced by the app; simulated by default.
    public var projectGlanceSource: any ProjectGlanceSource = SimulatedProjectGlance() {
        didSet { projectGlance = ProjectGlanceModel(source: projectGlanceSource) }
    }

    private(set) var projectGlance = ProjectGlanceModel(source: SimulatedProjectGlance())

    /// Remote sessions (D-280). Replaced by the app; simulated by default.
    public var remoteSessionSource: any RemoteSessionSource = SimulatedRemoteSessions() {
        didSet { remoteSessions = RemoteSessionsModel(source: remoteSessionSource) }
    }

    private(set) var remoteSessions = RemoteSessionsModel(source: SimulatedRemoteSessions())

    /// Open to the network (D-230).
    public var openPortSource: any OpenPortSource = SimulatedOpenPorts() {
        didSet { openPorts = OpenPortsModel(source: openPortSource) }
    }

    private(set) var openPorts = OpenPortsModel(source: SimulatedOpenPorts())

    /// Who made what's running (D-232).
    public var signatureSource: any CodeSignatureSource = SimulatedCodeSignatures() {
        didSet { signatures = SignaturesModel(source: signatureSource) }
    }

    private(set) var signatures = SignaturesModel(source: SimulatedCodeSignatures())

    /// Who can do what (D-261): the Security page and Checkup's protections.
    public var securitySource: any SecuritySource = SimulatedSecurity() {
        didSet { security = SecurityModel(source: securitySource) }
    }

    private(set) var security = SecurityModel(source: SimulatedSecurity())
    /// Wi-Fi over time and network changes (D-233, D-234), from the history store.
    let networkHistory = NetworkHistoryModel()
    /// The monthly data budget (D-235).
    public let dataBudget = DataBudgetModel()

    /// Devices (D-237).
    public var deskSource: any DeskSource = SimulatedDesk() {
        didSet { devices = DevicesModel(source: deskSource) }
    }

    private(set) var devices = DevicesModel(source: SimulatedDesk())

    private func makeProjectSpace() -> ProjectSpaceModel {
        ProjectSpaceModel(scanner: projectSpaceScanner, trasher: storageScanner.trasher) { [weak self] in
            self?.containers.diskSource
        }
    }

    /// The Storage tab's state. Held here, not by the view, so a scan keeps running and its map
    /// stays while another tab is showing. Released when the main window closes (D-055).
    private(set) var storage = StorageModel(scanner: SimulatedStorageScanner())

    /// ⌘R (View → Rescan Storage): scans the Storage tab's place again, while that tab shows and
    /// no scan runs.
    public var canRescanStorage: Bool {
        navigation.selection == .storage && !storage.isScanning
    }

    public func rescanStorage() {
        guard canRescanStorage else {
            return
        }
        storage.start()
    }

    /// The main window closed: drop the scan and its tree rather than keep them in memory.
    public func releaseStorage() {
        storage.stop()
        storage = StorageModel(scanner: storageScanner)
        // App icons are read again as rows appear; the cache would otherwise keep every icon
        // ever shown for the life of the app (D-086).
        IconCache.shared.removeAll()
    }

    @ObservationIgnored private var projectTerminator: any ProcessTerminator
    @ObservationIgnored private var containerTerminator: any ProcessTerminator
    public private(set) var history: any HistoryStore
    public private(set) var alertLog: any AlertStateStore
    /// Newest first. Refreshed when an alert fires and when the Alerts tab appears.
    public private(set) var recentAlerts: [Core.Alert] = []
    /// A short confirmation after Quit / Force Quit. Clears itself.
    public private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    public func show(toast text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else {
                return
            }
            self?.toast = nil
        }
    }

    /// Bumped whenever the history store changes, so history views reload.
    public private(set) var historyGeneration = 0

    public var alertSettings: AlertSettings {
        didSet {
            guard alertSettings != oldValue else {
                return
            }
            onAlertSettingsChange(alertSettings)
        }
    }

    @ObservationIgnored private let onAlertSettingsChange: (AlertSettings) -> Void
    @ObservationIgnored public var requestNotificationAuthorization: () async -> Bool = { false }
    /// Whether macOS lets alerts through. Replaced by the app; simulated (allowed) by default.
    @ObservationIgnored public var notificationPermissionSource: any NotificationPermissionSource = SimulatedNotificationPermission()
    /// The last permission read. The Alerts tab and Settings → Alerts say when it's off.
    public private(set) var notificationPermission: NotificationPermission = .allowed

    /// Reads the permission again: when an alerts view appears and when Mactivity becomes
    /// active (the person may have just changed it in System Settings).
    public func refreshNotificationPermission() async {
        let fresh = await notificationPermissionSource.permission()
        if fresh != notificationPermission {
            notificationPermission = fresh
        }
    }

    @ObservationIgnored public var controls = AppControls()
    /// When this Mactivity started: Checkup compares it with the Mac's start (D-129).
    @ObservationIgnored public let launchedAt = Date()

    public init(
        metrics: LiveMetrics,
        history: any HistoryStore,
        alertLog: any AlertStateStore,
        alertSettings: AlertSettings,
        projects: any ProjectSource,
        terminator: any ProcessTerminator,
        onAlertSettingsChange: @escaping (AlertSettings) -> Void = { _ in }
    ) {
        self.metrics = metrics
        self.projects = ProjectsModel(source: projects)
        let simulatedContainers = SimulatedContainerSource()
        containers = ContainersModel(source: simulatedContainers, restarter: simulatedContainers)
        projectTerminator = terminator
        containerTerminator = simulatedContainers
        confirmedAction = ConfirmedAction(
            terminator: ContainerRoutingTerminator(containers: simulatedContainers, everythingElse: terminator)
        )
        self.history = history
        self.alertLog = alertLog
        self.alertSettings = alertSettings
        self.onAlertSettingsChange = onAlertSettingsChange
        keepAwake.watch(metrics)
        keepAwake.onEnded = { [weak self] reason in self?.show(toast: reason) }
        recording.onFinished = { [weak self] text in self?.show(toast: text) }
        projectSpace = makeProjectSpace()
    }

    public func replaceStores(history: any HistoryStore, alertLog: any AlertStateStore) {
        self.history = history
        self.alertLog = alertLog
        recentAlerts = []
        historyGeneration += 1
    }

    /// An alert just fired.
    public func noteAlert(_ alert: Core.Alert) {
        recentAlerts.insert(alert, at: 0)
    }

    /// Mutes or unmutes an app's alerts: the app row's menu and a notification's Mute action. The
    /// same list as Settings → Alerts → Apps with muted alerts, saved like any settings change.
    public func setAlertsMuted(_ muted: Bool, for appID: AppIdentity.ID) {
        if muted {
            alertSettings.mutedAppIDs.insert(appID)
        } else {
            alertSettings.mutedAppIDs.remove(appID)
        }
    }

    /// Swaps the dev-server source and the terminator together (simulated vs. real).
    public func replaceProjects(_ source: any ProjectSource, terminator: any ProcessTerminator) {
        projects.replaceSource(source)
        projectTerminator = terminator
        confirmedAction.setTerminator(ContainerRoutingTerminator(containers: containerTerminator, everythingElse: terminator))
    }

    /// Swaps the container source, the terminator for container stops, and the restarter together.
    public func replaceContainers(
        _ source: any ContainerSource,
        terminator: any ProcessTerminator,
        restarter: any ContainerRestarter
    ) {
        containers.replace(source: source, restarter: restarter)
        containerTerminator = terminator
        confirmedAction.setTerminator(ContainerRoutingTerminator(containers: terminator, everythingElse: projectTerminator))
    }

    public func reloadAlerts() async {
        let log = alertLog
        recentAlerts = await (try? log.recentAlerts(limit: 100)) ?? []
    }

    /// History changed on disk ("Delete history").
    public func historyDidChange() {
        historyGeneration += 1
    }
}
