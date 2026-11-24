import Foundation

// Sleep and wake (D-096): what's keeping the Mac awake now, and when it slept and why it woke.

/// A process holding a power assertion that keeps the Mac, or its display, awake.
public struct SleepBlocker: Hashable, Sendable, Identifiable {
    public enum Keeps: String, Hashable, Sendable {
        /// The Mac won't idle-sleep.
        case system
        /// The display won't sleep (which also keeps the Mac awake).
        case display
    }

    public let id: String
    public let pid: Int32
    public let app: AppIdentity
    /// The assertion's own name, e.g. "Playing audio" or "Electron".
    public let reason: String
    public let keeps: Keeps
    public let since: Date?

    public init(id: String, pid: Int32, app: AppIdentity, reason: String, keeps: Keeps, since: Date?) {
        self.id = id
        self.pid = pid
        self.app = app
        self.reason = reason
        self.keeps = keeps
        self.since = since
    }

    /// False for macOS's own daemons (sharingd, bluetoothd…): there's nothing to quit, so Checkup
    /// and the notices leave them out. History → Sleep still lists them (D-108).
    public var isUserFacing: Bool {
        app.kind != .system
    }
}

public protocol SleepBlockerSource: Sendable {
    func blockers() async -> [SleepBlocker]
}

public struct PowerEvent: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case sleep, wake
    }

    public let at: Date
    public let kind: Kind
    /// A wake's `kern.wakereason`, as macOS gave it.
    public let reason: String?

    public init(at: Date, kind: Kind, reason: String? = nil) {
        self.at = at
        self.kind = kind
        self.reason = reason
    }
}

public protocol PowerEventStore: Sendable {
    func recordPowerEvent(_ event: PowerEvent) async throws
    /// Oldest first, the last `days` days.
    func powerEvents(days: Int) async throws -> [PowerEvent]
}

/// What woke the Mac, from `kern.wakereason` ("smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty
/// RTP.multi-touch"). The first cause a person would recognize wins: the lid before the trackpad.
public enum WakeCause: String, Hashable, Sendable, CaseIterable {
    case lid, powerButton, keyboardOrTrackpad, powerAdapter, network, bluetooth, usb, scheduled, other

    public init(reason: String) {
        let text = reason.lowercased()
        let tokens = Set(text.split(whereSeparator: { " .,:()".contains($0) }).map(String.init))
        // A word matches a piece of the reason that starts with it ("xhc1", "wifibt"), or, when
        // it's long enough not to match by accident, anywhere.
        func has(_ words: String...) -> Bool {
            words.contains { word in
                tokens.contains { $0.hasPrefix(word) } || word.count > 4 && text.contains(word)
            }
        }
        self = if has("lid") {
            .lid
        } else if has("pwrbtn", "powerbutton", "power_button") {
            .powerButton
        } else if has("multi-touch", "keyboard", "trackpad", "hid", "useractivity") {
            .keyboardOrTrackpad
        } else if has("acattach", "adapter", "charger") {
            .powerAdapter
        } else if has("wifi", "wlan", "arp", "network", "en0", "wake-on-lan") {
            .network
        } else if has("bluetooth", "bt") {
            .bluetooth
        } else if has("usb", "xhc") {
            .usb
        } else if has("rtc", "maintenance", "alarm", "scheduled") {
            .scheduled
        } else {
            .other
        }
    }
}

/// When the Mac was asleep, from its sleep and wake events.
public enum SleepTimeline {
    /// Each sleep followed by a wake, clipped to `start ..< end`. A sleep with no wake after it
    /// (Mactivity quit before the Mac woke) or a wake with no sleep before it is left out: the
    /// other half wasn't seen. With `ongoingUntil`, a sleep that's the latest event counts until
    /// then: Mactivity running while the last event is a sleep means a maintenance wake (Power
    /// Nap), and the Mac is still asleep (D-131).
    public static func asleep(_ events: [PowerEvent], from start: Date, to end: Date, ongoingUntil: Date? = nil) -> [DateInterval] {
        var intervals: [DateInterval] = []
        var fellAsleep: Date?
        for event in events.sorted(by: { $0.at < $1.at }) {
            switch event.kind {
            case .sleep:
                fellAsleep = event.at
            case .wake:
                if let slept = fellAsleep, event.at > slept {
                    let from = max(slept, start)
                    let to = min(event.at, end)
                    if to > from {
                        intervals.append(DateInterval(start: from, end: to))
                    }
                }
                fellAsleep = nil
            }
        }
        if let slept = fellAsleep, let ongoingUntil {
            let from = max(slept, start)
            let to = min(ongoingUntil, end)
            if to > from {
                intervals.append(DateInterval(start: from, end: to))
            }
        }
        return intervals
    }
}

// MARK: - Crashes and hangs (D-098)

/// One report macOS wrote when an app crashed or hung, from ~/Library/Logs/DiagnosticReports.
public struct CrashReport: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case crash, hang
    }

    public let id: String
    public let at: Date
    public let appName: String
    public let bundleID: String?
    public let kind: Kind
    /// The report file, for opening in Console.
    public let path: String
    /// The version that crashed, when the report says (D-115).
    public let appVersion: String?

    public init(id: String, at: Date, appName: String, bundleID: String?, kind: Kind, path: String, appVersion: String? = nil) {
        self.id = id
        self.at = at
        self.appName = appName
        self.bundleID = bundleID
        self.kind = kind
        self.path = path
        self.appVersion = appVersion
    }

    /// False once the app has been updated past the version that crashed: its advice ("an update
    /// often fixes it") has already happened (D-115). True when either version is unknown.
    public func isCurrent(installedVersion: String?) -> Bool {
        guard let installedVersion, let appVersion, !appVersion.isEmpty else {
            return true
        }
        return appVersion == installedVersion
    }

    /// A crash of an app or app extension: the report names a bundle. Command-line tools, test
    /// helpers and daemons have none, and crash for reasons an update doesn't fix (a test run, a
    /// compiler given bad input), so Checkup and the crash alert count only these (D-108).
    /// History → Crashes still lists every report.
    public var isAppCrash: Bool {
        kind == .crash && bundleID != nil
    }
}

public protocol CrashReportSource: Sendable {
    /// Reports written since `date`, newest first.
    func reports(since date: Date) async -> [CrashReport]
}

// MARK: - Time in front (D-098)

/// When each app was the one in front while someone was using the Mac.
public protocol FocusStore: Sendable {
    func recordFocus(_ app: AppIdentity, from start: Date, to end: Date) async throws
    /// Seconds in front per app between two dates, highest first.
    func focusTotals(from: Date, to: Date, limit: Int) async throws -> [AppTotal]
    /// Seconds any app was in front between two dates: time the Mac was in use.
    func activeSeconds(from: Date, to: Date) async throws -> Double
    /// When time in front was first recorded; nil before anything was.
    func firstFocus() async throws -> Date?
    /// When each app was last in front (D-135).
    func lastFocus() async throws -> [AppIdentity.ID: Date]
    /// The rows that began between two dates, oldest first (D-271).
    func focusStretches(from: Date, to: Date) async throws -> [FocusStretch]
}

// MARK: - Software updates (D-120)

/// A macOS or Apple software update that Software Update found and hasn't installed.
public struct PendingUpdate: Hashable, Sendable {
    public let name: String
    public let version: String?

    public init(name: String, version: String?) {
        self.name = name
        self.version = version
    }

    /// "macOS Tahoe 26.1", without repeating a version the name already has.
    public var title: String {
        guard let version, !version.isEmpty, !name.contains(version) else {
            return name
        }
        return "\(name) \(version)"
    }
}

public protocol SoftwareUpdateSource: Sendable {
    /// Updates Software Update has found and not installed, from its last check.
    func pending() async -> [PendingUpdate]
    /// Versions installed since `since` (D-206): macOS updates, and each of `apps`' current
    /// version when it arrived after `since`. Newest first.
    func installed(apps: [AppIdentity], since: Date) async -> [InstalledUpdate]
}
