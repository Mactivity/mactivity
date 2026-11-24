import Foundation

/// Apps open but unused (D-135): running for days without coming to the front, still holding
/// memory. From time in front (D-098) and the latest snapshot.
public struct UnusedApp: Hashable, Sendable, Identifiable {
    public var id: AppIdentity.ID {
        app.id
    }

    public let app: AppIdentity
    public let memoryBytes: UInt64
    /// When it was last in front, or nil when it hasn't been since time in front began.
    public let lastUsed: Date?
    /// How long it's gone unused, by the evidence: since `lastUsed`, or since it opened, or at
    /// least since time in front began.
    public let unusedFor: TimeInterval

    public init(app: AppIdentity, memoryBytes: UInt64, lastUsed: Date?, unusedFor: TimeInterval) {
        self.app = app
        self.memoryBytes = memoryBytes
        self.lastUsed = lastUsed
        self.unusedFor = unusedFor
    }
}

public enum UnusedApps {
    public static let idleLimit: TimeInterval = 3 * 86400
    public static let smallest: UInt64 = 300_000_000
    /// Of the whole Mac's CPU: an app using this much is doing something, unused or not.
    static let busyPercent = 1.0
    /// Apps people keep open without bringing them to the front, for their notifications or
    /// what they play: suggesting to quit them would be bad advice.
    static let keptOpenOnPurpose: Set<String> = [
        "com.apple.mail", "com.apple.MobileSMS", "com.apple.iCal", "com.apple.reminders", "com.apple.FaceTime",
        "com.apple.Music", "com.apple.podcasts", "com.apple.TV", "com.spotify.client",
        "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.Outlook", "com.hnc.Discord",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop", "us.zoom.xos",
    ]

    /// A running app with a window (activation policy regular), as the UI sees it.
    public struct Running: Sendable {
        public let id: AppIdentity.ID
        public let launchedAt: Date?

        public init(id: AppIdentity.ID, launchedAt: Date?) {
            self.id = id
            self.launchedAt = launchedAt
        }
    }

    /// Pure. Largest first.
    /// - Parameters:
    ///   - apps: the latest snapshot's apps, for names and memory.
    ///   - running: regular apps now running; only these are candidates (a menu bar helper never
    ///     comes to the front, so "unused" would mean nothing).
    ///   - lastFront: when each app was last in front.
    ///   - recordingSince: when time in front began; without it nothing can be said.
    ///   - own: Mactivity's bundle ID, never listed.
    public static func find(
        apps: [AppAggregate],
        running: [Running],
        lastFront: [AppIdentity.ID: Date],
        recordingSince: Date?,
        own: String?,
        now: Date
    ) -> [UnusedApp] {
        guard let recordingSince else {
            return []
        }
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [UnusedApp] = []
        for candidate in running where candidate.id != own && !keptOpenOnPurpose.contains(candidate.id) {
            // Working right now (Docker's containers, an export) is in use, front or not.
            guard let aggregate = byID[candidate.id], aggregate.app.kind == .app, aggregate.memoryBytes >= smallest,
                  aggregate.cpuPercent < busyPercent
            else {
                continue
            }
            let lastUsed = lastFront[candidate.id]
            // The latest thing that proves it was available to use: last in front, or opened
            // after recording began, or the start of recording.
            let since = [lastUsed, candidate.launchedAt, recordingSince].compactMap(\.self).max() ?? recordingSince
            let unused = now.timeIntervalSince(since)
            if unused >= idleLimit {
                found.append(UnusedApp(app: aggregate.app, memoryBytes: aggregate.memoryBytes, lastUsed: lastUsed, unusedFor: unused))
            }
        }
        return found.sorted { ($0.memoryBytes, $1.app.name) > ($1.memoryBytes, $0.app.name) }
    }
}
