import Foundation

/// Data used per app while the Mac is on an expensive connection, an iPhone's hotspot (D-136).
/// Pure: fed one snapshot at a time while the connection is expensive; started fresh each time
/// it becomes expensive.
public struct HotspotSession: Hashable, Sendable {
    public struct Usage: Hashable, Sendable, Identifiable {
        public var id: AppIdentity.ID {
            app.id
        }

        public let app: AppIdentity
        public var bytes: Double

        public init(app: AppIdentity, bytes: Double) {
            self.app = app
            self.bytes = bytes
        }
    }

    public let start: Date
    public private(set) var byApp: [AppIdentity.ID: Usage] = [:]
    /// The whole Mac, from the interface counters: includes what per-app figures miss (macOS's
    /// own daemons, Safari's page loads).
    public private(set) var totalBytes: Double = 0
    /// Per app since `takeRecent()`, for the 10-minute alert check.
    public private(set) var recent: [AppIdentity.ID: Usage] = [:]

    /// At most this many seconds per snapshot: a longer gap is sleep (D-133).
    static let longestCountedInterval: TimeInterval = 60

    public init(start: Date) {
        self.start = start
    }

    public mutating func add(_ snapshot: Snapshot) {
        let seconds = min(snapshot.interval.seconds, Self.longestCountedInterval)
        guard seconds > 0 else {
            return
        }
        totalBytes += (snapshot.system.network.inBPS + snapshot.system.network.outBPS) * seconds
        for app in snapshot.apps {
            let rate = (app.netInBPS ?? 0) + (app.netOutBPS ?? 0)
            guard rate > 0 else {
                continue
            }
            byApp[app.id, default: Usage(app: app.app, bytes: 0)].bytes += rate * seconds
            recent[app.id, default: Usage(app: app.app, bytes: 0)].bytes += rate * seconds
        }
    }

    /// Apps by data used, most first.
    public var top: [Usage] {
        byApp.values.sorted { ($0.bytes, $1.app.name) > ($1.bytes, $0.app.name) }
    }

    /// What each app used since the last call, and starts counting again.
    public mutating func takeRecent() -> [Usage] {
        defer { recent = [:] }
        return recent.values.sorted { $0.bytes > $1.bytes }
    }
}
