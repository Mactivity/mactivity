import Foundation

// Every data source the app uses, as a protocol (spec 7.1, CLAUDE.md rule 1).
// Each has a real implementation in its own target and a `Simulated*` twin in Simulated.
// The UI only ever sees these protocols.

// MARK: - Sampling

public protocol CPUSource: Sendable {
    /// Load since the previous call. The first call reports load since boot.
    func sample() async throws -> CPUStats
}

public protocol MemorySource: Sendable {
    func sample() async throws -> MemoryStats
}

public protocol DiskSource: Sendable {
    /// Throughput since the previous call; zero on the first call.
    func sample() async throws -> DiskStats
}

public protocol NetworkSource: Sendable {
    /// Throughput since the previous call; zero on the first call.
    func sample() async throws -> NetworkStats
}

public protocol GPUSource: Sendable {
    /// Nil when the Mac exposes no readable accelerator statistics.
    func sample() async throws -> GPUStats?
    /// Cumulative GPU time in nanoseconds per client PID, from the accelerator's user clients
    /// (IORegistry `AppUsage` → `accumulatedGPUTime`). Empty when unavailable.
    func clientGPUTime() async -> [Int32: UInt64]
}

public protocol BatterySource: Sendable {
    /// Nil on Macs without a battery.
    func sample() async throws -> BatteryStats?
}

public protocol SensorSource: Sendable {
    func sample() async throws -> SensorStats
}

public protocol ProcessSource: Sendable {
    /// Every process the app can read, with cumulative counters.
    func sample() async throws -> [ProcessReading]
    /// Same, but without reading usage counters for `pids`; those come back with
    /// `isComplete == false`. The sampler skips processes it already attributes to macOS while
    /// idle, since the macOS row takes the system remainder anyway (D-022).
    func sample(skippingUsageFor pids: Set<Int32>) async throws -> [ProcessReading]
}

extension ProcessSource {
    public func sample(skippingUsageFor _: Set<Int32>) async throws -> [ProcessReading] {
        try await sample()
    }
}

// MARK: - Grouping

public protocol AppResolver: Sendable {
    /// Attributes every reading to exactly one app. Every input PID appears in the result.
    func resolve(_ processes: [ProcessReading]) async -> [Int32: AppIdentity]
}

// MARK: - Snapshots

/// The one broadcast stream of snapshots (spec 6.13). Nothing else polls.
public protocol SnapshotSource: Sendable {
    /// A new stream that yields every snapshot from now on, starting with the latest one.
    func snapshots() async -> AsyncStream<Snapshot>
    /// 1 s while any window is visible, 10 s otherwise.
    func setCadence(_ cadence: SamplingCadence) async
    /// Whether temperatures and fans are wanted while idle (the menu bar shows temperature).
    /// While a window is visible they're always read.
    func setSensorDemand(_ wanted: Bool) async
    /// Whether macOS's own processes need per-process figures. Only an expanded macOS row shows
    /// them; otherwise that row is the system remainder, so their usage isn't read (D-063).
    func setSystemDetail(_ wanted: Bool) async
    /// How often to sample while a window is visible (1 s by default; 2 or 5 s by choice, D-065).
    func setVisibleInterval(_ interval: Duration) async
    /// Whether a figure that changes every tick shows per-app GPU (the menu bar window's GPU
    /// tab). Otherwise per-app GPU is read every few seconds while a window is visible (D-086).
    func setGPUDetail(_ wanted: Bool) async
}

extension SnapshotSource {
    public func setSensorDemand(_: Bool) async {}
    public func setSystemDetail(_: Bool) async {}
    public func setVisibleInterval(_: Duration) async {}
    public func setGPUDetail(_: Bool) async {}
}

public enum SamplingCadence: Hashable, Sendable {
    case idle
    case visible

    public var interval: Duration {
        switch self {
        // 10 s, not the spec's original 5 s (D-051): half the idle cost of
        // system reads, and history and alerts still get six points a minute.
        case .idle: .seconds(10)
        case .visible: .seconds(1)
        }
    }
}

// MARK: - Audio

/// Per-app volume, mute, and output device (spec 5.7, M10). Settings are per app, not per process: a change
/// through one pid applies to every process with the same `AudioClient.settingsKey`, is remembered, and is
/// reapplied when that app plays again, including after either app relaunches.
/// An `AudioSource` failure the UI can act on. Sources' errors adopt it, so the view can tell
/// "grant audio access" from "that app stopped playing" or "the device went away".
public protocol AudioChangeFailure: Error {
    /// True when the fix is allowing audio capture in Privacy & Security.
    var needsPermission: Bool { get }
    /// One line for the user, when it isn't about permission.
    var message: String { get }
}

public protocol AudioSource: Sendable {
    /// Processes playing audio, plus any Mactivity is changing, with their app's settings.
    func clients() async throws -> [AudioClient]
    /// 0...1. Moving the level also unmutes.
    func setVolume(_ volume: Double, for pid: Int32) async throws
    /// Mute keeps the level, so unmuting restores it.
    func setMuted(_ muted: Bool, for pid: Int32) async throws
    /// Sends the app to an output device by UID; nil follows the system default. If the device goes away the
    /// app falls back to the default, and returns when the device does.
    func setOutputDevice(uid: String?, for pid: Int32) async throws
    /// Back to 100%, unmuted, on the system default, and forgotten.
    func resetSettings(for pid: Int32) async throws
    /// Output devices an app can be sent to.
    func outputDevices() async throws -> [AudioOutputDevice]
    /// The per-app volume flag. Off: no taps and no listeners; remembered settings are kept. On: remembered
    /// settings reapply whenever their app plays.
    func setEnabled(_ enabled: Bool) async
}

// MARK: - History, alerts, termination

public protocol HistoryStore: Sendable {
    func record(_ snapshot: Snapshot) async throws
    /// `app == nil` means the system-wide series.
    func series(metric: Metric, app: AppIdentity.ID?, range: HistoryRange) async throws -> [SeriesPoint]
    func topApps(metric: Metric, range: HistoryRange, limit: Int) async throws -> [AppTotal]
    /// The same ranking for the period just before the range (e.g. the 7 days before the last 7),
    /// for "vs previous period" (expansion E3). Empty when retention doesn't reach that far.
    func topAppsInPreviousPeriod(metric: Metric, range: HistoryRange, limit: Int) async throws -> [AppTotal]
    /// System-wide total for counter metrics over a range ("written today").
    func total(metric: Metric, range: HistoryRange) async throws -> Double
    /// Writes any partially accumulated minute. Called on quit.
    func flush() async throws
    /// Size of the store on disk, for Settings → History.
    func storageSizeBytes() async -> UInt64
    /// "Delete history" in Settings.
    func deleteAll() async throws
    /// How many days of history to keep (spec 6.7, D-089; default a year).
    func setRetention(days: Int) async
}

public protocol AlertDeliverer: Sendable {
    func deliver(_ alert: Alert) async throws
}

/// Whether macOS lets Mactivity post notifications (System Settings → Notifications).
public enum NotificationPermission: Sendable, Equatable {
    case allowed
    /// Turned off in System Settings, or declined at the prompt.
    case denied
    /// Never asked. The prompt shows the first time the app asks.
    case notDetermined

    /// Alerts can't reach the person: worth saying so where the rules are.
    public var isOff: Bool {
        self != .allowed
    }
}

/// Reads the notification permission. Reading never prompts.
public protocol NotificationPermissionSource: Sendable {
    func permission() async -> NotificationPermission
}

public protocol ProcessTerminator: Sendable {
    /// Takes only a `ConfirmedTermination`, which only the UI's `ConfirmedAction` can create.
    func terminate(_ request: ConfirmedTermination) async throws -> TerminationResult
}
