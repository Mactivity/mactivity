import Foundation

/// Something that added itself to start with the Mac since the last look (1.5, D-231): what the
/// new-startup-item alert says.
public struct StartupAddition: Sendable, Hashable {
    /// The launchd label or the login item's bundle ID: the alert's key, once per item.
    public let label: String
    /// The app it belongs to, or its own name.
    public let name: String
    /// "a login item", "an agent that runs at login", "a daemon that runs at startup as root".
    public let what: String

    public init(label: String, name: String, what: String) {
        self.label = label
        self.name = name
        self.what = what
    }
}
