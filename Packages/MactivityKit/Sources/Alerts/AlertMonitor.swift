import Core
import Foundation
import os

/// Feeds snapshots to the rule engine, keeps its state, and hands fired alerts to the store,
/// the deliverer, and the UI (spec 5.4, 6.8).
public actor AlertMonitor {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    /// Activity is averaged into buckets this long, and evaluated once per completed bucket.
    static let bucketLength: TimeInterval = AlertEngine.pointLength

    private static let logger = Logger(subsystem: "app.mactivity.alerts", category: "monitor")

    private let deliverer: any AlertDeliverer
    private let store: any AlertStateStore
    private let calendar: Calendar
    private var settings: AlertSettings
    /// Each app's usual daily peak memory (D-218), from the app's hourly check.
    private var usualPeakMemory: [AppIdentity.ID: Double] = [:]
    private var recorder = ActivityRecorder(bucketLength: AlertMonitor.bucketLength)
    /// Nil until loaded from the store on the first evaluation.
    private var state: AlertState?
    private var stateLoad: Task<AlertState, Never>?
    private var continuations: [UUID: AsyncStream<Alert>.Continuation] = [:]
    /// How many times the engine has run. For tests.
    private(set) var evaluationCount = 0

    public init(deliverer: any AlertDeliverer, store: any AlertStateStore, settings: AlertSettings = .defaults) {
        // Autoupdating: quiet hours follow the Mac to a new time zone (D-139).
        self.init(deliverer: deliverer, store: store, settings: settings, calendar: .autoupdatingCurrent)
    }

    /// `calendar` decides quiet hours. Tests pass a fixed one.
    init(deliverer: any AlertDeliverer, store: any AlertStateStore, settings: AlertSettings, calendar: Calendar) {
        self.deliverer = deliverer
        self.store = store
        self.settings = settings
        self.calendar = calendar
    }

    deinit {
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    public func updateSettings(_ settings: AlertSettings) {
        self.settings = settings
    }

    public func updateUsualPeakMemory(_ peaks: [AppIdentity.ID: Double]) {
        usualPeakMemory = peaks
    }

    /// Called once per snapshot (every 1–5 s).
    public func ingest(_ snapshot: Snapshot, frontmostAppID: AppIdentity.ID?) async {
        // Only apps a rule can alert about are kept: not macOS, not muted apps, nothing at all
        // with every rule off. Keeping an hour of points for every app was ~5 MB (D-086).
        let anyRule = longestEnabledWindow > 0
        let muted = settings.mutedAppIDs
        let closed = recorder.record(snapshot) { app in
            anyRule && app.kind != .system && !muted.contains(app.id)
        }
        guard closed else {
            return
        }
        let keep = longestEnabledWindow + Self.bucketLength
        recorder.trim(
            olderThan: snapshot.at.addingTimeInterval(-keep),
            maxPoints: Int((keep / Self.bucketLength).rounded(.up))
        )
        let activity = recorder.currentActivity()
        let context = AlertContext(
            now: snapshot.at, frontmostAppID: frontmostAppID, calendar: calendar, usualPeakMemory: usualPeakMemory
        )

        await loadStateIfNeeded()
        // No suspension between reading the state and writing it back.
        let evaluation = AlertEngine.evaluate(
            settings: settings, activity: activity, state: state ?? AlertState(), context: context
        )
        evaluationCount += 1
        await apply(evaluation)
    }

    /// Keeps the new state and publishes alerts. A state change without an alert (growing
    /// memory's level forgotten once the app gave memory back, D-111) is saved too; it was
    /// dropped, so the app stayed silenced until it grew past the old level (D-139).
    private func apply(_ evaluation: AlertEvaluation) async {
        let changed = evaluation.state != state
        state = evaluation.state
        if !evaluation.alerts.isEmpty {
            await publish(evaluation)
        } else if changed {
            do {
                try await store.saveAlertState(evaluation.state)
            } catch {
                Self.logger.error("Couldn't save alert state: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func runSystemRules(_ inputs: SystemAlertInputs, now: Date) async {
        await loadStateIfNeeded()
        let evaluation = SystemAlertRules.evaluate(
            settings: settings, inputs: inputs, state: state ?? AlertState(), now: now, calendar: calendar
        )
        await apply(evaluation)
    }

    public func recentAlerts(limit: Int) async -> [Alert] {
        do {
            return try await store.recentAlerts(limit: limit)
        } catch {
            Self.logger.error("Couldn't read recent alerts: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Every alert that fires from now on, for the UI.
    public func firedAlerts() -> AsyncStream<Alert> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Alert>.makeStream(bufferingPolicy: .bufferingNewest(100))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuations[id] = continuation
        return stream
    }

    /// How many bucketed points are kept for one app. For tests.
    func pointCount(for appID: AppIdentity.ID) -> Int {
        recorder.tracks[appID]?.points.count ?? 0
    }

    // MARK: Private

    private var longestEnabledWindow: TimeInterval {
        // Only the snapshot rules: the crash rule's 24 hours would otherwise keep a day of points.
        AlertRule.appRules
            .map { settings.settings(for: $0) }
            .filter(\.isEnabled)
            .map(\.window.seconds)
            .max() ?? 0
    }

    private func loadStateIfNeeded() async {
        guard state == nil else {
            return
        }
        let load = stateLoad ?? Task { [store] in
            do {
                return try await store.loadAlertState()
            } catch {
                Self.logger.error("Couldn't load alert state: \(error.localizedDescription, privacy: .public)")
                return AlertState()
            }
        }
        stateLoad = load
        let loaded = await load.value
        if state == nil {
            state = loaded
        }
        stateLoad = nil
    }

    private func publish(_ evaluation: AlertEvaluation) async {
        do {
            try await store.saveAlertState(evaluation.state)
        } catch {
            Self.logger.error("Couldn't save alert state: \(error.localizedDescription, privacy: .public)")
        }
        for alert in evaluation.alerts {
            Self.logger.info("\(alert.rule.rawValue, privacy: .public) fired for \(alert.app.id, privacy: .public)")
            do {
                try await store.recordAlert(alert)
            } catch {
                Self.logger.error("Couldn't record alert: \(error.localizedDescription, privacy: .public)")
            }
            do {
                try await deliverer.deliver(alert)
            } catch {
                Self.logger.error("Couldn't deliver alert: \(error.localizedDescription, privacy: .public)")
            }
            for continuation in continuations.values {
                continuation.yield(alert)
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
