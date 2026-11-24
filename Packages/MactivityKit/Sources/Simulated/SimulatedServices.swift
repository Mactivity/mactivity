import Core
import Foundation

/// Three apps playing: Safari untouched, Music at 80% on a second device, Podcasts muted. Settings are per app,
/// like the real source. Two devices: the built-in speakers (default) and a pair of AirPods.
public actor SimulatedAudioSource: AudioSource {
    public static let speakersUID = "BuiltInSpeakerDevice"
    public static let headphonesUID = "simulated-airpods-pro"

    private static let playing: [Int32] = [
        SimulatedCatalog.pid(app: 0, process: 2),
        SimulatedCatalog.pid(app: 1, process: 0),
        SimulatedCatalog.pid(app: 5, process: 0),
    ]

    private var settings: [AppIdentity.ID: AudioAppSetting] = [
        SimulatedCatalog.apps[5].identity.id: AudioAppSetting(volume: 0.8, outputDeviceUID: headphonesUID),
        SimulatedCatalog.apps[1].identity.id: AudioAppSetting(volume: 0.6, isMuted: true),
    ]

    public init() {}

    public func clients() async throws -> [AudioClient] {
        Self.playing.compactMap { pid in
            guard let app = Self.app(for: pid) else {
                return nil
            }
            let setting = settings[app] ?? .untouched
            return AudioClient(
                pid: pid, app: app, volume: setting.volume, isMuted: setting.isMuted,
                outputDeviceUID: setting.outputDeviceUID, settingsKey: app
            )
        }
    }

    public func setVolume(_ volume: Double, for pid: Int32) async throws {
        update(pid) {
            $0.volume = min(1, max(0, volume))
            $0.isMuted = false
        }
    }

    public func setMuted(_ muted: Bool, for pid: Int32) async throws {
        update(pid) { $0.isMuted = muted }
    }

    public func setOutputDevice(uid: String?, for pid: Int32) async throws {
        update(pid) { $0.outputDeviceUID = uid }
    }

    public func resetSettings(for pid: Int32) async throws {
        update(pid) { $0 = .untouched }
    }

    public func outputDevices() async throws -> [AudioOutputDevice] {
        [
            AudioOutputDevice(uid: Self.speakersUID, name: "MacBook Pro Speakers", isDefault: true),
            AudioOutputDevice(uid: Self.headphonesUID, name: "AirPods Pro", isDefault: false),
        ]
    }

    public func setEnabled(_: Bool) async {}

    private func update(_ pid: Int32, _ change: (inout AudioAppSetting) -> Void) {
        guard let app = Self.app(for: pid) else {
            return
        }
        var setting = settings[app] ?? .untouched
        change(&setting)
        settings[app] = setting.isUntouched ? nil : setting
    }

    private static func app(for pid: Int32) -> AppIdentity.ID? {
        let index = (Int(pid) - 400) / 100
        return SimulatedCatalog.apps.indices.contains(index) ? SimulatedCatalog.apps[index].identity.id : nil
    }
}

/// An in-memory history store. Keeps every recorded snapshot; fine for previews and tests.
public actor SimulatedHistoryStore: HistoryStore, BatteryHistoryStore {
    private var snapshots: [Snapshot] = []
    /// Notes on history (D-253), kept in memory; two to start with, for the demo.
    var savedNotes: [UUID: HistoryNote]?

    public init() {}

    public func record(_ snapshot: Snapshot) async throws {
        snapshots.append(snapshot)
    }

    public func series(metric: Metric, app: AppIdentity.ID?, range: HistoryRange) async throws -> [SeriesPoint] {
        inRange(range).map { snapshot in
            let value = Self.value(of: metric, app: app, in: snapshot)
            return SeriesPoint(at: snapshot.at, average: value, maximum: value)
        }
    }

    public func topApps(metric: Metric, range: HistoryRange, limit: Int) async throws -> [AppTotal] {
        let window = inRange(range)
        guard !window.isEmpty else {
            return []
        }
        var sums: [AppIdentity.ID: (app: AppIdentity, sum: Double)] = [:]
        for snapshot in window {
            for app in snapshot.apps {
                sums[app.id, default: (app.app, 0)].sum += app.value(for: metric) ?? 0
            }
        }
        return sums.values
            .map { AppTotal(app: $0.app, value: $0.sum / Double(window.count)) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.self)
    }

    public func total(metric: Metric, range: HistoryRange) async throws -> Double {
        inRange(range).reduce(0) { total, snapshot in
            let seconds = Double(snapshot.interval.components.seconds)
            return total + Self.value(of: metric, app: nil, in: snapshot) * seconds
        }
    }

    /// The same apps, 15% lighter: enough to preview the comparison.
    public func topAppsInPreviousPeriod(metric: Metric, range: HistoryRange, limit: Int) async throws -> [AppTotal] {
        try await topApps(metric: metric, range: range, limit: limit).map { AppTotal(app: $0.app, value: $0.value * 0.85) }
    }

    public func flush() async throws {}

    public func storageSizeBytes() async -> UInt64 {
        UInt64(snapshots.count * 4096)
    }

    public func deleteAll() async throws {
        snapshots.removeAll()
    }

    public func setRetention(days _: Int) async {}

    /// A slowly aging battery: capacity falls a point every ~3 weeks, a cycle every day or two.
    public func batteryHistory(days: Int) async throws -> [BatteryDay] {
        let today = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        return (0 ..< max(1, days)).reversed().map { back in
            let day = Calendar.current.date(byAdding: .day, value: -back, to: today) ?? today
            return BatteryDay(
                day: day, maxCapacityPercent: 96 + Double(back) / 21, cycleCount: max(0, 212 - back / 2),
                minutesOnBattery: Double((back * 37) % 240)
            )
        }
    }

    private func inRange(_ range: HistoryRange) -> [Snapshot] {
        guard let last = snapshots.last?.at else {
            return []
        }
        let start = last - Double(range.duration.components.seconds)
        return snapshots.filter { $0.at >= start }
    }

    private static func value(of metric: Metric, app: AppIdentity.ID?, in snapshot: Snapshot) -> Double {
        if let app {
            return snapshot.apps.first { $0.id == app }?.value(for: metric) ?? 0
        }
        return snapshot.apps.reduce(0) { $0 + ($1.value(for: metric) ?? 0) }
    }
}

/// Keeps alert state in memory.
public actor SimulatedAlertStateStore: AlertStateStore {
    private var state = AlertState()
    private var alerts: [Alert] = []

    public init() {}

    public func loadAlertState() async throws -> AlertState {
        state
    }

    public func saveAlertState(_ state: AlertState) async throws {
        self.state = state
    }

    public func recentAlerts(limit: Int) async throws -> [Alert] {
        Array(alerts.sorted { $0.firedAt > $1.firedAt }.prefix(limit))
    }

    public func recordAlert(_ alert: Alert) async throws {
        alerts.append(alert)
    }
}

/// Records alerts instead of posting notifications.
public actor SimulatedAlertDeliverer: AlertDeliverer {
    public private(set) var delivered: [Alert] = []

    public init() {}

    public func deliver(_ alert: Alert) async throws {
        delivered.append(alert)
    }
}

/// A fixed notification permission, for previews and tests.
public struct SimulatedNotificationPermission: NotificationPermissionSource {
    public let value: NotificationPermission

    public init(_ value: NotificationPermission = .allowed) {
        self.value = value
    }

    public func permission() async -> NotificationPermission {
        value
    }
}

/// Records terminations instead of sending signals. Never touches a real process.
public actor SimulatedProcessTerminator: ProcessTerminator {
    public private(set) var requests: [ConfirmedTermination] = []

    public init() {}

    public func terminate(_ request: ConfirmedTermination) async throws -> TerminationResult {
        requests.append(request)
        let pids: [Int32] = switch request.target {
        case let .app(_, pids): pids
        case let .process(pid), let .processGroup(pid): [pid]
        case .container: []
        }
        return TerminationResult(terminated: pids, survivors: [])
    }
}

/// Never presenting, unless a test says so.
public struct SimulatedPresenting: PresentingSource {
    public let reason: PresentingReason?

    public init(reason: PresentingReason? = nil) {
        self.reason = reason
    }

    public func current() async -> PresentingReason? {
        reason
    }
}
