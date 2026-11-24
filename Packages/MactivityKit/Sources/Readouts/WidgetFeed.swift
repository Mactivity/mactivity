import Core
import Foundation
import os

/// When the app rewrites the widget file and when it asks WidgetKit to reload (E7).
///
/// - Write at most once a minute, and only when a figure moved meaningfully or the last write is
///   `heartbeat` old (so a running app never lets the widget go stale).
/// - Reload timelines only after a write, at most every `minimumReloadInterval`: WidgetKit
///   budgets reloads (roughly 40–70 a day), so 15 min keeps us near that without depending on
///   the system dropping requests.
public struct WidgetPublishPolicy: Equatable, Sendable {
    public var minimumWriteInterval: TimeInterval = 60
    public var heartbeat: TimeInterval = 30 * 60
    public var minimumReloadInterval: TimeInterval = 15 * 60
    /// Points of total CPU.
    public var cpuPoints: Double = 5
    /// Points of memory used, as a percent of total.
    public var memoryPoints: Double = 2
    /// Battery percentage points.
    public var batteryPoints: Double = 1

    public init() {}

    public static let standard = WidgetPublishPolicy()

    /// Whether `new` differs enough from what the widget shows to be worth a write. The
    /// sparkline's history alone never counts: it moves every minute.
    public func changedMeaningfully(from old: WidgetSnapshot, to new: WidgetSnapshot) -> Bool {
        if abs(new.cpuPercent - old.cpuPercent) >= cpuPoints {
            return true
        }
        if abs(new.memoryUsedPercent - old.memoryUsedPercent) >= memoryPoints || new.memoryPressure != old.memoryPressure {
            return true
        }
        switch (old.battery, new.battery) {
        case (nil, nil):
            // A desktop: the widget shows the GPU where a laptop's shows the battery.
            if abs((new.gpuPercent ?? 0) - (old.gpuPercent ?? 0)) >= cpuPoints {
                return true
            }
        case let (before?, after?):
            if abs(after.percent - before.percent) >= batteryPoints || after.isCharging != before.isCharging || after.onAC != before.onAC {
                return true
            }
        default:
            return true
        }
        return old.topApps.map(\.name) != new.topApps.map(\.name)
    }
}

/// The write/reload decision, as a value so it's testable without files or clocks.
public struct WidgetThrottle: Sendable {
    public enum Decision: Equatable, Sendable {
        case skip, write, writeAndReload
    }

    public let policy: WidgetPublishPolicy
    public private(set) var lastWritten: WidgetSnapshot?
    public private(set) var lastWriteAt: Date?
    public private(set) var lastReloadAt: Date?

    public init(policy: WidgetPublishPolicy = .standard) {
        self.policy = policy
    }

    /// Cheap pre-check, so ticks inside the write interval don't even build a candidate.
    public func isDue(now: Date) -> Bool {
        lastWriteAt.map { now.timeIntervalSince($0) >= policy.minimumWriteInterval } ?? true
    }

    /// Decides, and records the decision as done. Call once per candidate.
    public mutating func decide(_ candidate: WidgetSnapshot, now: Date) -> Decision {
        guard isDue(now: now) else {
            return .skip
        }
        let changed = lastWritten.map { policy.changedMeaningfully(from: $0, to: candidate) } ?? true
        let heartbeat = lastWriteAt.map { now.timeIntervalSince($0) >= policy.heartbeat } ?? true
        let reloadDue = lastReloadAt.map { now.timeIntervalSince($0) >= policy.minimumReloadInterval } ?? true
        // A change written inside the reload cooldown is still owed a reload: without this the
        // widget kept the old figure until the 30-minute heartbeat (D-145).
        let reloadOwed = reloadDue && (lastWriteAt.map { written in lastReloadAt.map { written > $0 } ?? true } ?? false)
        guard changed || heartbeat || reloadOwed else {
            return .skip
        }
        lastWritten = candidate
        lastWriteAt = now
        guard reloadDue else {
            return .write
        }
        lastReloadAt = now
        return .writeAndReload
    }
}

/// Folds snapshots into per-minute CPU means for the small widget's sparkline. Two additions
/// per tick; a point is pushed when the minute rolls over.
public struct MinuteMeans: Sendable {
    public private(set) var points: [Double] = []
    private var minute: Int?
    private var sum = 0.0
    private var samples = 0
    private let capacity: Int

    public init(capacity: Int = WidgetSnapshot.historyLength) {
        self.capacity = capacity
    }

    public mutating func add(_ value: Double, at date: Date) {
        let current = Int(date.timeIntervalSince1970 / 60)
        if let minute, minute != current, samples > 0 {
            points.append(sum / Double(samples))
            if points.count > capacity {
                points.removeFirst(points.count - capacity)
            }
            sum = 0
            samples = 0
        }
        minute = current
        sum += value
        samples += 1
    }

    /// Finished minutes plus the one in progress.
    public var withCurrent: [Double] {
        samples > 0 ? Array((points + [sum / Double(samples)]).suffix(capacity)) : points
    }
}

/// The app's side of the widget feed: fed every snapshot, writes the JSON file into the app
/// group container when `WidgetThrottle` says so, then calls `reload` (WidgetCenter, injected
/// by the app so this target doesn't link WidgetKit).
///
/// Cost per snapshot while nothing is due: one `Date` comparison and two additions.
@MainActor
public final class WidgetFeed {
    private static let log = Logger(subsystem: "app.mactivity.readouts", category: "widget-feed")

    public let fileURL: URL
    private var throttle: WidgetThrottle
    private var history = MinuteMeans()
    /// Today so far (D-200), carried in every file written; set by the app every 15 minutes.
    private var today: WidgetSnapshot.Today?
    private var lastWritten: WidgetSnapshot?
    private let reload: @MainActor () -> Void

    public init(fileURL: URL, policy: WidgetPublishPolicy = .standard, reload: @escaping @MainActor () -> Void) {
        self.fileURL = fileURL
        throttle = WidgetThrottle(policy: policy)
        self.reload = reload
    }

    /// The file inside an app group container, or nil when there's no team (ad-hoc builds) or
    /// the system has no container for the group. `containerURL` is
    /// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`, injected for tests.
    public nonisolated static func fileURL(teamID: String?, containerURL: (String) -> URL?) -> URL? {
        guard let group = WidgetSnapshot.appGroupIdentifier(teamID: teamID), let container = containerURL(group) else {
            return nil
        }
        return container.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(WidgetSnapshot.fileName)
    }

    @discardableResult
    public func consider(_ snapshot: Snapshot) -> WidgetThrottle.Decision {
        history.add(snapshot.system.cpu.totalPercent, at: snapshot.at)
        guard throttle.isDue(now: snapshot.at) else {
            return .skip
        }
        var candidate = WidgetSnapshot(snapshot: snapshot, cpuHistory: history.withCurrent)
        candidate.today = today
        let decision = throttle.decide(candidate, now: snapshot.at)
        switch decision {
        case .skip:
            break
        case .write:
            write(candidate)
        case .writeAndReload:
            if write(candidate) {
                reload()
            }
        }
        return decision
    }

    /// A new Today so far: written now with the last figures, and the widgets reloaded, rather
    /// than waiting for the figures to change enough to be written again (D-200).
    public func updateToday(_ today: WidgetSnapshot.Today) {
        guard today != self.today else {
            return
        }
        self.today = today
        guard var last = lastWritten else {
            return
        }
        last.today = today
        if write(last) {
            reload()
        }
    }

    @discardableResult
    private func write(_ snapshot: WidgetSnapshot) -> Bool {
        lastWritten = snapshot
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try snapshot.encoded().write(to: fileURL, options: .atomic)
            return true
        } catch {
            Self.log.error("Widget file write failed: \(String(describing: error))")
            return false
        }
    }
}
