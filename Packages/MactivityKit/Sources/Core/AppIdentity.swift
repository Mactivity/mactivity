import Foundation

/// The app a process is attributed to. Every process belongs to exactly one identity (spec 5.1).
public struct AppIdentity: Hashable, Sendable, Identifiable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// A bundled app; `bundleID` is set.
        case app
        /// A terminal app that owns shell-launched processes (Terminal, iTerm, Warp, Ghostty…).
        case terminal
        /// The "macOS" row: system daemons and the unreadable remainder.
        case system
        /// Anything unresolvable, keyed by executable name. Never hidden.
        case other
    }

    /// Stable key. Bundle ID for apps and terminals, `"system"` for macOS, `"other:<exe>"` otherwise.
    public let id: String
    public let name: String
    public let bundleID: String?
    /// Key into the icon cache (Grouping). Usually the bundle path.
    public let iconKey: String
    public let kind: Kind

    public init(id: String, name: String, bundleID: String?, iconKey: String, kind: Kind) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.iconKey = iconKey
        self.kind = kind
    }

    /// The reserved identity for system daemons and the unattributed remainder.
    public static let system = AppIdentity(
        id: "system", name: "macOS", bundleID: nil, iconKey: "system", kind: .system
    )

    /// Processes of the Mac's other signed-in people (Fast User Switching): not this user's apps,
    /// and not this user's to quit. A `.system` kind, so nothing offers to quit or alert (D-221).
    public static let otherUsers = AppIdentity(
        id: "system:otherUsers",
        name: String(
            localized: "Other users",
            bundle: .strings,
            comment: "App list row: the processes of other people signed in to this Mac"
        ),
        bundleID: nil, iconKey: "otherUsers", kind: .system
    )

    /// The fallback identity for a process nothing else could resolve.
    public static func other(executableName: String) -> AppIdentity {
        AppIdentity(
            id: "other:\(executableName)", name: executableName, bundleID: nil,
            iconKey: "other", kind: .other
        )
    }
}
