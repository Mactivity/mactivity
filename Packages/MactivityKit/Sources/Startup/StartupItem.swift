import Foundation

/// Reads what starts with the Mac (expansion E4). Read-only: it never loads, unloads, or edits
/// anything. The UI only ever sees this protocol (CLAUDE.md rule 1).
public protocol StartupSource: Sendable {
    /// Every login item, launch agent, launch daemon, and app helper this source can see.
    func items() async throws -> [StartupItem]

    /// How many plists macOS itself ships in `/System/Library/LaunchAgents` and `LaunchDaemons`.
    /// Counted, never listed.
    func macOSItemCount() async throws -> Int
}

extension StartupSource {
    public func macOSItemCount() async throws -> Int {
        0
    }
}

/// Disables and enables the items that can be (`StartupItem.canDisable` / `canEnable`).
/// Callers ask the user first; implementations never delete anything.
public protocol StartupItemToggling: Sendable {
    func disable(_ item: StartupItem) async throws
    func enable(_ item: StartupItem) async throws
}

/// What kind of thing starts.
public enum StartupKind: String, Hashable, Sendable, CaseIterable, Codable {
    /// An app or helper app that opens at login (`Contents/Library/LoginItems`, `SMAppService.mainApp`).
    case loginItem
    /// A launchd agent: runs in the user's session.
    case agent
    /// A launchd daemon: runs as root, for every user, from startup.
    case daemon
    /// An agent or daemon plist shipped inside an app and registered through `SMAppService`.
    case appHelper

    public var title: String {
        switch self {
        case .loginItem: String(localized: "Login item", bundle: .strings, comment: "Startup item kind")
        case .agent: String(localized: "Agent", bundle: .strings, comment: "Startup item kind: a launchd agent")
        case .daemon: String(localized: "Daemon", bundle: .strings, comment: "Startup item kind: a launchd daemon")
        case .appHelper: String(localized: "App helper", bundle: .strings, comment: "Startup item kind")
        }
    }
}

/// Where the item was found.
public enum StartupLocation: String, Hashable, Sendable, Codable {
    /// `~/Library/LaunchAgents`. The only place Mactivity can disable things.
    case userLaunchAgents
    /// `~/Library/LaunchAgents (Disabled by Mactivity)`: disabled here, can be enabled again.
    case disabledByMactivity
    /// `/Library/LaunchAgents`. Needs an administrator to change.
    case launchAgents
    /// `/Library/LaunchDaemons`. Needs an administrator to change.
    case launchDaemons
    /// Inside an installed app's `Contents/Library`.
    case appBundle
    /// Reported by `SMAppService` (Mactivity's own login item).
    case serviceManagement

    public var title: String {
        switch self {
        case .userLaunchAgents: String(localized: "Your LaunchAgents folder", bundle: .strings, comment: "Startup item location")
        case .disabledByMactivity: String(localized: "Disabled by Mactivity", bundle: .strings, comment: "Startup item location and state")
        case .launchAgents: "/Library/LaunchAgents"
        case .launchDaemons: "/Library/LaunchDaemons"
        case .appBundle: String(localized: "Inside the app", bundle: .strings, comment: "Startup item location")
        case .serviceManagement: String(localized: "Login Items", bundle: .strings, comment: "Startup item location: System Settings")
        }
    }
}

/// One `StartCalendarInterval` entry. A nil field means "every" (launchd's wildcard).
public struct CalendarInterval: Hashable, Sendable, Codable {
    public var minute: Int?
    public var hour: Int?
    public var day: Int?
    /// 0 and 7 are Sunday.
    public var weekday: Int?
    public var month: Int?

    public init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
    }
}

/// `KeepAlive`: absent or false, true, or a dictionary of conditions.
public enum KeepAlive: Hashable, Sendable, Codable {
    case off
    case always
    /// The dictionary's keys (`SuccessfulExit`, `NetworkState`, `PathState`, `OtherJobEnabled`, …).
    case conditions([String])
}

/// When the item runs, as far as its plist says.
public enum StartupSchedule: Hashable, Sendable, Codable {
    /// `RunAtLoad`, or a login item.
    case atLoad
    /// `KeepAlive`: launchd restarts it whenever it exits (or when the conditions hold).
    case alwaysRunning(conditional: Bool)
    /// `StartInterval` in seconds.
    case interval(seconds: Int, atLoad: Bool)
    /// `StartCalendarInterval`.
    case calendar([CalendarInterval], atLoad: Bool)
    /// Launched when something asks for it (Mach service, socket, watched path) or not at all.
    case onDemand
}

/// Whether it's switched on, as far as the public APIs can tell.
public enum StartupState: String, Hashable, Sendable, Codable {
    /// Loads at login or startup.
    case on
    /// The plist says `Disabled`.
    case disabledInPlist
    /// Turned off in System Settings → Login Items & Extensions.
    case turnedOffInSettings
    /// Moved aside by Mactivity; Enable moves it back.
    case disabledByMactivity
    /// An app helper the app hasn't registered.
    case notRegistered
    /// Can't be known without the Background Task Management database (login item helpers).
    case unknown

    public var title: String {
        switch self {
        case .on: String(localized: "On", bundle: .strings, comment: "Startup item state: switched on")
        case .disabledInPlist: String(localized: "Disabled in its plist", bundle: .strings, comment: "Startup item state")
        case .turnedOffInSettings: String(localized: "Turned off in System Settings", bundle: .strings, comment: "Startup item state")
        case .disabledByMactivity: String(localized: "Disabled by Mactivity", bundle: .strings, comment: "Startup item location and state")
        case .notRegistered: String(localized: "Not registered by the app", bundle: .strings, comment: "Startup item state")
        case .unknown: String(localized: "Only System Settings knows", bundle: .strings, comment: "Startup item state: can't be read")
        }
    }
}

/// What `SMAppService.statusForLegacyPlist(at:)` reports for a plist.
public enum LoginItemsStatus: String, Hashable, Sendable, Codable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

/// Something worth a second look. Shown as amber tags, never red.
public struct StartupFlag: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// The executable is missing, or the plist doesn't name one.
        case broken
        /// The executable lives outside the usual install locations.
        case unusualLocation
        /// The plist is empty: launchd ignores it, and some updaters (Google's) empty theirs to
        /// switch off. Not broken, and it doesn't start (D-132).
        case empty
    }

    public let kind: Kind
    /// One sentence for the detail pane.
    public let reason: String

    public init(_ kind: Kind, _ reason: String) {
        self.kind = kind
        self.reason = reason
    }

    public var title: String {
        switch kind {
        case .broken: String(localized: "Broken", bundle: .strings, comment: "Startup item tag: its program is missing")
        case .unusualLocation: String(localized: "Unusual", bundle: .strings, comment: "Startup item tag: runs from an unusual folder")
        case .empty: String(localized: "Empty", bundle: .strings, comment: "Startup item tag: its plist file is empty, so it does nothing")
        }
    }
}

/// The app that put an item there.
public struct StartupOwner: Hashable, Sendable, Codable {
    public enum Evidence: String, Hashable, Sendable, Codable {
        /// The plist's `AssociatedBundleIdentifiers`.
        case associatedBundleIdentifier
        /// The executable sits inside this app.
        case executablePath
        /// The plist lives inside this app's bundle.
        case containingApp
        /// The label's reverse-DNS prefix matches this app's bundle ID.
        case labelPrefix
        /// The executable's path names an app that is no longer installed.
        case missingApp
        /// Nothing matched.
        case unknown
    }

    public let name: String
    public let bundleID: String?
    /// The `.app` on disk, for the icon and Reveal in Finder.
    public let bundlePath: String?
    public let evidence: Evidence

    public init(name: String, bundleID: String?, bundlePath: String?, evidence: Evidence) {
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.evidence = evidence
    }

    public static let unknown = StartupOwner(
        name: String(localized: "Unknown", bundle: .strings, comment: "Owner group for startup items no app claims"),
        bundleID: nil,
        bundlePath: nil,
        evidence: .unknown
    )

    /// Stable grouping key.
    public var id: String {
        bundleID ?? bundlePath ?? (evidence == .missingApp ? "missing:\(name)" : "unknown")
    }

    /// An app that's on this Mac now.
    public var isInstalled: Bool {
        bundlePath != nil
    }

    public var isKnown: Bool {
        evidence != .unknown
    }
}

/// One thing that starts with the Mac.
public struct StartupItem: Identifiable, Hashable, Sendable, Codable {
    /// The plist's path, or the login item's bundle path.
    public let id: String
    /// The launchd label, or the login item's bundle identifier.
    public let label: String
    /// What the row shows: the helper app's name, or the label.
    public let name: String
    public let kind: StartupKind
    public let location: StartupLocation
    /// The plist, when there is one.
    public let plistPath: String?
    /// The resolved executable, when the plist names one.
    public let executablePath: String?
    public let arguments: [String]
    public let schedule: StartupSchedule
    /// The plist's key fields, for the detail pane.
    public let plist: LaunchdPlist?
    public let owner: StartupOwner
    public let state: StartupState
    /// Whether `SMAppService` lists it; nil when not asked (login item helpers).
    public let loginItemsStatus: LoginItemsStatus?
    /// Nil when it can't be told from the executable path alone (shared interpreters like `/bin/sh`).
    public let isRunning: Bool?
    public let flags: [StartupFlag]

    public init(
        id: String,
        label: String,
        name: String,
        kind: StartupKind,
        location: StartupLocation,
        plistPath: String?,
        executablePath: String?,
        arguments: [String],
        schedule: StartupSchedule,
        plist: LaunchdPlist?,
        owner: StartupOwner,
        state: StartupState,
        loginItemsStatus: LoginItemsStatus?,
        isRunning: Bool?,
        flags: [StartupFlag]
    ) {
        self.id = id
        self.label = label
        self.name = name
        self.kind = kind
        self.location = location
        self.plistPath = plistPath
        self.executablePath = executablePath
        self.arguments = arguments
        self.schedule = schedule
        self.plist = plist
        self.owner = owner
        self.state = state
        self.loginItemsStatus = loginItemsStatus
        self.isRunning = isRunning
        self.flags = flags
    }

    public var isBroken: Bool {
        flags.contains { $0.kind == .broken }
    }

    public var isUnusual: Bool {
        flags.contains { $0.kind == .unusualLocation }
    }

    /// Counts toward "N things start with your Mac": switched on, or running when its state can't be known.
    public var startsWithMac: Bool {
        switch state {
        case .on: true
        case .unknown: isRunning == true
        case .disabledInPlist, .turnedOffInSettings, .disabledByMactivity, .notRegistered: false
        }
    }

    /// Only user agents in `~/Library/LaunchAgents` can be disabled, and only by moving the file.
    public var canDisable: Bool {
        location == .userLaunchAgents && plistPath != nil
    }

    public var canEnable: Bool {
        location == .disabledByMactivity && plistPath != nil
    }

    /// The file Reveal in Finder selects.
    public var revealPath: String {
        plistPath ?? id
    }
}
