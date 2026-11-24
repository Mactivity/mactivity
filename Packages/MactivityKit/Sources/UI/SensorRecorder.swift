import Core
import Foundation

/// Camera and microphone history's recording (1.8, D-259). macOS's own record of which app used
/// a sensor lasts about two days, so Mactivity copies it into History: when the camera or a
/// microphone turns on or off (checked every 10 seconds, from public API), and every few hours
/// for the screen and the location, which have no cheap public check. Each read starts where the
/// last change kept left off, so nothing is read twice and a gap while Mactivity was closed is
/// filled from the log. Where the log can't be read, the public state is kept without the apps.
@MainActor
public final class SensorRecorder {
    private let source: any SensorActivitySource
    private var store: (any SensorHistoryStore)?
    private var lastCheck: Date = .distantPast
    private var lastInUse: Set<PrivacySensor>?
    /// When the log was last read up to; nil before the first read with this store.
    private var lastRead: Date?
    private var reading = false

    /// How often the public state is checked: a few microseconds each time.
    static let checkEvery: TimeInterval = 10
    /// The safety read: well inside the log's two days.
    static let readEvery: TimeInterval = 3 * 3600
    /// How far back the first read goes, on a Mac with no history of it yet.
    static let firstRead: TimeInterval = 2 * 86400

    public init(source: any SensorActivitySource, store: (any SensorHistoryStore)? = nil) {
        self.source = source
        self.store = store
    }

    /// History's store, or a new one after Simulated data was turned off: read again from its
    /// newest change.
    public func attach(_ store: (any SensorHistoryStore)?) {
        self.store = store
        lastRead = nil
    }

    /// Each snapshot: at most every 10 seconds, whether the camera or a microphone changed, and
    /// a read of the log when one did or the safety read is due.
    public func observe(_ snapshot: Snapshot) {
        guard store != nil, snapshot.at.timeIntervalSince(lastCheck) >= Self.checkEvery else {
            return
        }
        lastCheck = snapshot.at
        let inUse = source.inUse()
        let changed = lastInUse.map { $0 != inUse } ?? false
        lastInUse = inUse
        let due = lastRead.map { snapshot.at.timeIntervalSince($0) >= Self.readEvery } ?? true
        guard changed || due, !reading else {
            return
        }
        reading = true
        // On its own task: a read takes a second or more, and the snapshot loop that calls this
        // records History in between.
        let at = snapshot.at
        Task { [weak self] in
            await self?.read(at: at, inUse: inUse, changed: changed)
            self?.reading = false
        }
    }

    func read(at now: Date, inUse: Set<PrivacySensor>, changed: Bool) async {
        guard let store else {
            return
        }
        let last = try? await store.lastSensorChange()
        let from = max(last?.at ?? .distantPast, now.addingTimeInterval(-Self.firstRead))
        lastRead = now
        guard let read = await source.changes(from: from, to: now) else {
            // The log can't be read: the public state, without the apps (D-259).
            if changed {
                let active = Set(inUse.map { SensorUse(sensor: $0, app: nil) })
                try? await store.recordSensorChanges([SensorChange(at: now, active: active)])
            }
            return
        }
        let fresh = Self.fresh(read, after: last, bootedAt: CheckupLoader.bootTime())
        try? await store.recordSensorChanges(fresh)
    }

    /// Pure: the changes newer than the last one kept. When that one left something in use and
    /// the Mac has restarted since, a restart ended it: an empty change at the startup first.
    nonisolated static func fresh(_ changes: [SensorChange], after last: SensorChange?, bootedAt: Date?) -> [SensorChange] {
        var fresh = changes.filter { $0.at > (last?.at ?? .distantPast) }
        if let last, !last.active.isEmpty, let bootedAt, last.at < bootedAt, (fresh.first?.at ?? .distantFuture) > bootedAt {
            fresh.insert(SensorChange(at: bootedAt, active: []), at: 0)
        }
        return fresh
    }
}
