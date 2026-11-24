import Foundation

// Configuration profiles (D-287): what's installed, who put it there and what it changes, as far
// as macOS tells a program that isn't running as root.

/// What one part of a profile does: macOS's name for the kind of setting.
public struct ProfilePayload: Hashable, Sendable {
    /// "com.apple.wifi.managed".
    public let type: String
    public let name: String?

    public init(type: String, name: String?) {
        self.type = type
        self.name = name
    }
}

public struct ConfigurationProfile: Hashable, Sendable, Identifiable {
    /// Who put it there, as far as the profile says.
    public enum Origin: Hashable, Sendable {
        /// macOS wrote it for Screen Time, or for an app using Screen Time's controls.
        case screenTime
        /// macOS wrote it for itself.
        case macOS
        /// A device management system installed it, for the organization when it names one.
        case management(organization: String?)
        /// Installed some other way, and it names an organization. Anyone can write that name.
        case named(String)
        /// Installed some other way, and it names nobody.
        case unnamed
    }

    public let identifier: String
    public let name: String?
    public let description: String?
    public let organization: String?
    public let installed: Date?
    public let installedByManagement: Bool
    public let removalDisallowed: Bool
    /// `internaldata: TRUE`: written by macOS rather than from a profile file.
    public let isInternal: Bool
    public let payloads: [ProfilePayload]

    public var id: String {
        identifier
    }

    public init(
        identifier: String, name: String?, description: String? = nil, organization: String? = nil, installed: Date? = nil,
        installedByManagement: Bool = false, removalDisallowed: Bool = false, isInternal: Bool = false, payloads: [ProfilePayload] = []
    ) {
        self.identifier = identifier
        self.name = name
        self.description = description
        self.organization = organization
        self.installed = installed
        self.installedByManagement = installedByManagement
        self.removalDisallowed = removalDisallowed
        self.isInternal = isInternal
        self.payloads = payloads
    }

    /// Pure. Management comes first because it's the one fact macOS vouches for. The Apple
    /// prefixes count only with `internaldata`, since a profile file can claim any identifier.
    public var origin: Origin {
        if installedByManagement {
            return .management(organization: organization)
        }
        if isInternal, identifier.hasPrefix("com.apple.ManagedSettings.") {
            return .screenTime
        }
        if isInternal, identifier.hasPrefix("com.apple.") {
            return .macOS
        }
        return organization.map(Origin.named) ?? .unnamed
    }
}

/// Whether this Mac is enrolled in device management (`profiles status -type enrollment`). Each is
/// nil when the command didn't say.
public struct ManagementEnrollment: Hashable, Sendable {
    /// Set up by an organization through Apple's automated enrollment (DEP).
    public let automated: Bool?
    public let managed: Bool?

    public init(automated: Bool?, managed: Bool?) {
        self.automated = automated
        self.managed = managed
    }
}

public struct ProfilesReading: Hashable, Sendable {
    /// This user's profiles. macOS lists the whole Mac's only to root, and Mactivity doesn't ask.
    public let profiles: [ConfigurationProfile]
    public let enrollment: ManagementEnrollment?

    public init(profiles: [ConfigurationProfile], enrollment: ManagementEnrollment?) {
        self.profiles = profiles
        self.enrollment = enrollment
    }
}

/// Where the profiles come from (D-287): the real Mac, or Simulated.
public protocol ProfilesSource: Sendable {
    /// Nil when the command is missing, fails or prints something unfamiliar.
    func read() async -> ProfilesReading?
}
