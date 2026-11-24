import Core
import Foundation
import Observation
import Simulated

/// The views' single subscriber to the snapshot stream (spec 6.13). It keeps the latest
/// snapshot, two minutes of sparkline history per tab, and a throttled reading for the menu bar.
@MainActor
@Observable
public final class LiveMetrics {
    public struct Point: Identifiable, Hashable, Sendable {
        public let id: Int
        public let at: Date
        public let value: Double
    }

    /// Anything that can show live figures. The cadence is `visible` while any is on screen.
    public enum Surface: Hashable, Sendable {
        case mainWindow, menuBarWindow, settings, quickSearch
        /// A recording samples every second, window or not (D-151).
        case recording
    }

    /// What the menu bar item draws. Changes at most every `menuBarIdleRefresh` while nothing is
    /// open, because every change costs a system-side status item redraw (D-019).
    public struct MenuBarReading: Equatable, Sendable {
        /// Each metric's figure as `figureChoices` asks, formatted once per reading.
        public var figures: [MenuBarMetric: MenuBarFigure] = [:]
        /// Recent values per metric, oldest first, for graph mode.
        public var graph: [MenuBarMetric: [Double]] = [:]
        public var strain: StrainReason?

        public static let empty = MenuBarReading()

        public func text(for metric: MenuBarMetric) -> String {
            figures[metric]?.text ?? "–"
        }

        /// Sets `metric`'s usual figure for `value` (previews and tests).
        public mutating func set(_ metric: MenuBarMetric, value: Double?) {
            figures[metric] = MenuBarLayout.automatic(metric, value: value)
        }
    }

    /// What this Mac has, as far as the snapshots show. Changes at most a couple of times per
    /// source, so views that only ask "is there a battery?" don't redraw every tick. Pure.
    public struct Hardware: Equatable, Sendable {
        /// True until the first snapshot says otherwise, then true once any snapshot had a
        /// battery: a later read without one is a failed read, not an unplugged battery.
        public private(set) var hasBattery = true
        /// Nil until the sensors are read.
        public private(set) var hasFans: Bool?
        public private(set) var hasTemperatureSensors: Bool?
        private var sawBattery = false

        public init() {}

        public mutating func observe(_ system: SystemSample) {
            if system.battery != nil {
                sawBattery = true
            }
            hasBattery = sawBattery
            if let sensors = system.sensors {
                hasFans = hasFans == true || !sensors.fans.isEmpty
                hasTemperatureSensors = hasTemperatureSensors == true || !sensors.temperatures.isEmpty
            }
        }
    }

    /// About two minutes at the visible cadence (spec 4.1, graph mode).
    public static let historyLength = 120
    /// Menu bar refresh while idle (15 s).
    public static let menuBarIdleRefresh: TimeInterval = 15
    public static let appListRefresh: TimeInterval = 3
    /// The menu bar's figures are redrawn at least this often, even when no shown figure moved
    /// enough to be worth a redraw (D-068).
    public static let menuBarMaxStaleness: TimeInterval = 60

    public private(set) var snapshot: Snapshot?
    /// Whether any snapshot has arrived. Changes only on that transition, so a view that only
    /// asks "is there data yet?" doesn't re-evaluate every tick the way reading `snapshot` would.
    public private(set) var hasSnapshot = false
    /// What app lists show. Refreshes at most every `appListRefresh` (like Activity Monitor), so
    /// rows don't reshuffle and re-measure every second while the figures above them tick.
    public private(set) var appList: AppListData?
    public private(set) var sparklines: [MetricTab: [Point]] = [:]
    public private(set) var menuBar = MenuBarReading.empty
    /// Separate from `menuBar` so icon mode observes only this and redraws only when it changes.
    public private(set) var strain: StrainReason?
    /// Steadies `strain` so the icon doesn't flicker at a threshold (D-121).
    @ObservationIgnored private var strainSmoother = StrainSmoother()
    public private(set) var isSimulated: Bool
    public private(set) var hardware = Hardware()
    public private(set) var cadence: SamplingCadence = .idle

    public var cpu: CPUStats? {
        snapshot?.system.cpu
    }

    public var cpuHistory: [Point] {
        sparklines[.cpu] ?? []
    }

    @ObservationIgnored private var source: any SnapshotSource
    @ObservationIgnored private var visibleSurfaces: Set<Surface> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var nextPointID = 0
    @ObservationIgnored private var cpuWindow: [(at: Date, percent: Double)] = []
    @ObservationIgnored private var lastMenuBarUpdate: Date?
    @ObservationIgnored private var lastAppListUpdate: Date?

    public init(source: any SnapshotSource, isSimulated: Bool) {
        self.source = source
        self.isSimulated = isSimulated
    }

    /// Subscribes to the source. Calling it again resubscribes.
    public func start() {
        loop?.cancel()
        let source = source
        let cadence = cadence
        let sensors = menuBarNeedsSensors
        let systemDetail = showsSystemProcesses
        let gpuDetail = showsPerAppGPU
        let visibleInterval = visibleInterval
        loop = Task { [weak self] in
            await source.setCadence(cadence)
            await source.setSensorDemand(sensors)
            await source.setSystemDetail(systemDetail)
            await source.setGPUDetail(gpuDetail)
            await source.setVisibleInterval(visibleInterval)
            let stream = await source.snapshots()
            for await snapshot in stream {
                guard !Task.isCancelled, let self else {
                    return
                }
                apply(snapshot)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Swaps the data source (the "Simulated data" toggle). History restarts so the two never mix.
    public func replaceSource(_ source: any SnapshotSource, isSimulated: Bool) {
        self.source = source
        self.isSimulated = isSimulated
        snapshot = nil
        hasSnapshot = false
        hardware = Hardware()
        sparklines = [:]
        cpuWindow = []
        appList = nil
        lastAppListUpdate = nil
        menuBar = .empty
        strain = nil
        strainSmoother = StrainSmoother()
        lastMenuBarUpdate = nil
        start()
    }

    /// Sampling interval while a window is visible (Settings → General, D-065).
    public var visibleInterval: Duration = SamplingCadence.visible.interval {
        didSet {
            guard visibleInterval != oldValue else {
                return
            }
            let source = source
            let interval = visibleInterval
            Task { await source.setVisibleInterval(interval) }
        }
    }

    /// The setting's stored seconds, limited to the offered choices' range.
    public static func clampedVisibleSeconds(_ seconds: Int) -> Int {
        min(5, max(1, seconds))
    }

    /// Who currently needs figures for macOS's own processes: an app list with the macOS row
    /// expanded, or an open Get Info window. Detail stays on while anyone wants it (D-086).
    public enum SystemDetailRequester: Hashable, Sendable {
        /// The diagnosis (D-134) reads macOS's background jobs for a few seconds.
        case appList, inspector, diagnosis
    }

    private var systemDetailRequesters: Set<SystemDetailRequester> = [] {
        didSet {
            let wanted = !systemDetailRequesters.isEmpty
            guard wanted != !oldValue.isEmpty else {
                return
            }
            let source = source
            Task { await source.setSystemDetail(wanted) }
        }
    }

    public func setSystemDetail(_ wanted: Bool, for requester: SystemDetailRequester) {
        if wanted {
            systemDetailRequesters.insert(requester)
        } else {
            systemDetailRequesters.remove(requester)
        }
    }

    /// An app list has the macOS row expanded, so macOS's own processes need their figures.
    public var showsSystemProcesses: Bool {
        get { systemDetailRequesters.contains(.appList) }
        set { setSystemDetail(newValue, for: .appList) }
    }

    /// A view that updates every tick shows per-app GPU (the menu bar window's GPU tab), so the
    /// sampler reads it every tick rather than every 3 s (D-086).
    public var showsPerAppGPU = false {
        didSet {
            guard showsPerAppGPU != oldValue else {
                return
            }
            let source = source
            let wanted = showsPerAppGPU
            Task { await source.setGPUDetail(wanted) }
        }
    }

    /// The figures the menu bar item shows (figure, graph, and stacked modes). Empty for icon mode,
    /// which never redraws for figures. Set by the app (D-068). Only these are formatted each
    /// reading, and icon mode makes none at all (D-086); nil (not set: previews, tests) makes all.
    public var menuBarTextMetrics: [MenuBarMetric]? {
        didSet {
            guard menuBarTextMetrics != oldValue, let snapshot else {
                return
            }
            // What the item shows changed: draw it from the latest snapshot now.
            menuBar = makeMenuBarReading(snapshot, strain: strain)
            lastMenuBarUpdate = snapshot.at
        }
    }

    /// What each figure shows (Settings → General → Figures). Set by the app. A change redraws
    /// the item straight away rather than at the next due reading.
    public var figureChoices = FigureChoices.automatic {
        didSet {
            guard figureChoices != oldValue, let snapshot else {
                return
            }
            menuBar = makeMenuBarReading(snapshot, strain: strain)
            lastMenuBarUpdate = snapshot.at
        }
    }

    /// The menu bar shows temperature, so sensors are read while idle too (every 15 s).
    public var menuBarNeedsSensors = false {
        didSet {
            guard menuBarNeedsSensors != oldValue else {
                return
            }
            let source = source
            let wanted = menuBarNeedsSensors
            Task { await source.setSensorDemand(wanted) }
        }
    }

    public func setVisible(_ visible: Bool, surface: Surface) {
        if visible {
            visibleSurfaces.insert(surface)
        } else {
            visibleSurfaces.remove(surface)
        }
        let newCadence: SamplingCadence = visibleSurfaces.isEmpty ? .idle : .visible
        guard newCadence != cadence else {
            return
        }
        if newCadence == .visible, cadence == .idle, let snapshot {
            appList = AppListData(snapshot)
            lastAppListUpdate = snapshot.at
        } else if newCadence == .idle {
            // Nothing shows app lists while idle; don't keep every process around for them.
            appList = nil
            lastAppListUpdate = nil
        }
        cadence = newCadence
        let source = source
        Task { await source.setCadence(newCadence) }
    }

    /// Fills the sparklines with past snapshots, oldest first, as if they had arrived live. For the
    /// website's screenshots, which would otherwise show a second of history.
    public func backfill(_ snapshots: [Snapshot]) {
        snapshots.forEach(apply)
    }

    func apply(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        if !hasSnapshot {
            hasSnapshot = true
        }
        var hardware = hardware
        hardware.observe(snapshot.system)
        if hardware != self.hardware {
            self.hardware = hardware
        }
        // Only a visible window shows app lists; building one groups every process, so idle
        // ticks skip it (becoming visible builds one straight away, in `setVisible`).
        if cadence == .visible, lastAppListUpdate.map({ snapshot.at.timeIntervalSince($0) >= Self.appListRefresh }) ?? true {
            appList = AppListData(snapshot)
            lastAppListUpdate = snapshot.at
        }
        for tab in MetricTab.allCases {
            guard let value = tab.sparklineValue(snapshot) else {
                continue
            }
            var points = sparklines[tab] ?? []
            points.append(Point(id: nextPointID, at: snapshot.at, value: value))
            nextPointID += 1
            if points.count > Self.historyLength {
                points.removeFirst(points.count - Self.historyLength)
            }
            sparklines[tab] = points
        }

        cpuWindow.append((snapshot.at, snapshot.system.cpu.totalPercent))
        cpuWindow.removeAll { snapshot.at.timeIntervalSince($0.at) > StrainDetector.cpuWindow + 10 }
        let strain = strainSmoother.update(StrainDetector.evaluate(
            cpuHistory: cpuWindow,
            now: snapshot.at,
            memoryPressure: snapshot.system.memory.pressure,
            bootVolumeFreeFraction: snapshot.system.disk.bootVolume?.freeFraction,
            thermal: snapshot.system.thermal
        ), now: snapshot.at)
        // A negative gap is a clock set back: redraw rather than wait it out (D-221).
        let due = lastMenuBarUpdate.map { snapshot.at.timeIntervalSince($0) >= Self.menuBarIdleRefresh || snapshot.at < $0 } ?? true
        if strain != self.strain {
            self.strain = strain
        }
        // Icon mode draws no figures: nothing to format (the icon reads `strain`).
        if menuBarTextMetrics?.isEmpty == true {
            return
        }
        if cadence == .visible || due || strain != menuBar.strain {
            // Each redraw of the item costs ~35 ms of main-thread AppKit work (D-019), so only
            // when a shown figure moved enough to notice, strain changed, or it's been a minute.
            let reading = makeMenuBarReading(snapshot, strain: strain)
            let stale = lastMenuBarUpdate.map { snapshot.at.timeIntervalSince($0) >= Self.menuBarMaxStaleness || snapshot.at < $0 } ?? true
            if stale || strain != menuBar.strain
                || Self.menuBarWorthRedrawing(from: menuBar, to: reading, shown: menuBarTextMetrics ?? []) {
                menuBar = reading
                lastMenuBarUpdate = snapshot.at
            }
        }
    }

    /// Pure: whether any shown figure's text changed and one of its numbers moved by more than
    /// its small band (`MenuBarFigure.Band`): under 2 points for percentages, under 2° for
    /// temperature, under a quarter (or 10 kB/s) for rates. A text without numbers ("Normal",
    /// "Charging") redraws on any change. With nothing listed (icon mode) every update counts.
    static func menuBarWorthRedrawing(from old: MenuBarReading, to new: MenuBarReading, shown: [MenuBarMetric]) -> Bool {
        guard !shown.isEmpty else {
            return true
        }
        return shown.contains { metric in
            let before = old.figures[metric]
            let after = new.figures[metric]
            guard before?.text != after?.text else {
                return false
            }
            guard let before, let after else {
                return true
            }
            return !after.isWithinBand(of: before)
        }
    }

    private func makeMenuBarReading(_ snapshot: Snapshot, strain: StrainReason?) -> MenuBarReading {
        var reading = MenuBarReading(strain: strain)
        let system = snapshot.system
        let shown = menuBarTextMetrics.map { Set($0) } ?? Set(MenuBarMetric.allCases)
        for metric in MenuBarMetric.allCases where shown.contains(metric) {
            reading.figures[metric] = MenuBarLayout.figure(metric, system, choices: figureChoices)
        }
        for metric in MenuBarMetric.allCases where metric != .temperature && shown.contains(metric) {
            // Graph mode draws one bar per recent sample.
            reading.graph[metric] = (sparklines[metric.tab] ?? []).suffix(Tokens.MenuBarItem.barCount).map(\.value)
        }
        return reading
    }
}

extension LiveMetrics {
    /// Simulated, already sampling. For SwiftUI previews.
    public static func preview() -> LiveMetrics {
        let metrics = LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true)
        metrics.setVisible(true, surface: .mainWindow)
        metrics.start()
        return metrics
    }
}

/// The slow-moving view of a snapshot for lists and donuts: refreshed every 3 s, with
/// processes grouped by app once per refresh rather than once per row per render.
public struct AppListData: Equatable, Sendable {
    public let apps: [AppAggregate]
    public let processesByApp: [AppIdentity.ID: [ProcessSample]]
    public let memory: MemoryStats

    public init(_ snapshot: Snapshot) {
        apps = snapshot.apps
        processesByApp = Dictionary(grouping: snapshot.processes, by: \.app)
        memory = snapshot.system.memory
    }
}
