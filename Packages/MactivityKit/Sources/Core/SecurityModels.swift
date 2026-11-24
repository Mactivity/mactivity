import Foundation

// Who can do what on your Mac (1.9, D-261): the security settings, the permissions apps have,
// and the extensions that run with the system's privileges or inside a browser. Read-only.

/// The Mac's main protections, each on, off, or nil when it couldn't be read.
public struct SecuritySettings: Hashable, Sendable {
    /// The startup disk is encrypted (`fdesetup status`).
    public var fileVault: Bool?
    /// The application firewall (`socketfilterfw --getglobalstate`).
    public var firewall: Bool?
    /// Gatekeeper checks apps before they open (`spctl --status`).
    public var gatekeeper: Bool?
    /// System Integrity Protection (`csrutil status`).
    public var systemIntegrity: Bool?
    /// Security responses and system files install by themselves (Software Update's
    /// `CriticalUpdateInstall` and `ConfigDataInstall`).
    public var securityResponses: Bool?
    /// macOS updates install by themselves (`AutomaticallyInstallMacOSUpdates`).
    public var macOSUpdates: Bool?

    public init(
        fileVault: Bool? = nil, firewall: Bool? = nil, gatekeeper: Bool? = nil, systemIntegrity: Bool? = nil,
        securityResponses: Bool? = nil, macOSUpdates: Bool? = nil
    ) {
        self.fileVault = fileVault
        self.firewall = firewall
        self.gatekeeper = gatekeeper
        self.systemIntegrity = systemIntegrity
        self.securityResponses = securityResponses
        self.macOSUpdates = macOSUpdates
    }
}

/// What an app can be allowed to use, as System Settings → Privacy & Security lists it.
public enum PermissionKind: String, CaseIterable, Hashable, Sendable {
    case camera, microphone, screenRecording, fullDiskAccess, accessibility, inputMonitoring, automation, files

    /// The service names macOS's permission records use.
    public static func kind(service: String) -> PermissionKind? {
        switch service {
        case "kTCCServiceCamera": .camera
        case "kTCCServiceMicrophone": .microphone
        case "kTCCServiceScreenCapture": .screenRecording
        case "kTCCServiceSystemPolicyAllFiles": .fullDiskAccess
        case "kTCCServiceAccessibility", "kTCCServicePostEvent": .accessibility
        case "kTCCServiceListenEvent": .inputMonitoring
        case "kTCCServiceAppleEvents": .automation
        case "kTCCServiceSystemPolicyDesktopFolder", "kTCCServiceSystemPolicyDocumentsFolder",
             "kTCCServiceSystemPolicyDownloadsFolder", "kTCCServiceSystemPolicyRemovableVolumes",
             "kTCCServiceSystemPolicyNetworkVolumes":
            .files
        default: nil
        }
    }

    /// The kinds macOS keeps per person, not for the whole Mac.
    public static let perUser: [PermissionKind] = [.camera, .microphone, .automation, .files]

    /// The anchor of its pane in System Settings → Privacy & Security.
    public var settingsAnchor: String {
        switch self {
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .screenRecording: "Privacy_ScreenCapture"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .automation: "Privacy_Automation"
        case .files: "Privacy_FilesAndFolders"
        }
    }
}

/// One app's answer for one permission (D-261).
public struct AppPermission: Hashable, Sendable, Identifiable {
    public let kind: PermissionKind
    /// A bundle ID, or a path for a command-line tool.
    public let client: String
    public let clientIsPath: Bool
    public let allowed: Bool
    /// When it was last changed.
    public let changed: Date?
    /// Automation: the app it may control (a bundle ID).
    public let target: String?

    public var id: String {
        "\(kind.rawValue):\(client):\(target ?? "")"
    }

    public init(kind: PermissionKind, client: String, clientIsPath: Bool, allowed: Bool, changed: Date?, target: String? = nil) {
        self.kind = kind
        self.client = client
        self.clientIsPath = clientIsPath
        self.allowed = allowed
        self.changed = changed
        self.target = target
    }
}

/// The permissions, or why they couldn't be read.
public enum PermissionsReading: Hashable, Sendable {
    /// macOS keeps them where only Full Disk Access can read.
    case noAccess
    /// What could be read, and the kinds that couldn't: macOS 27 keeps a person's own permissions
    /// where even Full Disk Access can't read them (D-263).
    case read([AppPermission], unreadable: [PermissionKind])
}

/// Code that runs with the system's own privileges: a system extension or a kernel extension.
public struct SystemExtensionItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        /// A system extension: a network filter, an endpoint security tool, a driver (DriverKit).
        case systemExtension
        /// A kernel extension: older, loaded into the kernel itself.
        case kernelExtension
    }

    public let kind: Kind
    public let identifier: String
    public let name: String
    public let version: String
    /// The developer's team ID, when the listing gives one.
    public let teamID: String?
    /// "network_extension", "driver_extension", "endpoint_security_extension"…
    public let category: String?
    public let isOn: Bool

    public var id: String {
        identifier
    }

    public init(kind: Kind, identifier: String, name: String, version: String, teamID: String?, category: String?, isOn: Bool) {
        self.kind = kind
        self.identifier = identifier
        self.name = name
        self.version = version
        self.teamID = teamID
        self.category = category
        self.isOn = isOn
    }
}

public enum Browser: String, CaseIterable, Hashable, Sendable {
    case safari, chrome, edge, brave, arc, firefox

    public var title: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .arc: "Arc"
        case .firefox: "Firefox"
        }
    }

    public var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        case .arc: "company.thebrowser.Browser"
        case .firefox: "org.mozilla.firefox"
        }
    }
}

/// An extension installed in a browser (D-261).
public struct BrowserExtension: Hashable, Sendable, Identifiable {
    public let browser: Browser
    public let identifier: String
    public let name: String
    public let version: String
    /// Switched on in the browser; nil when the browser doesn't say.
    public let isOn: Bool?
    /// What it asked for, as written in its manifest: "tabs", "<all_urls>", "https://*.example.com/*".
    public let permissions: [String]

    public var id: String {
        "\(browser.rawValue):\(identifier)"
    }

    public init(browser: Browser, identifier: String, name: String, version: String, isOn: Bool?, permissions: [String]) {
        self.browser = browser
        self.identifier = identifier
        self.name = name
        self.version = version
        self.isOn = isOn
        self.permissions = permissions
    }

    /// What the permissions let it reach, in plain words, broadest first.
    public var access: [ExtensionAccess] {
        ExtensionAccess.from(permissions)
    }
}

/// What a browser extension can reach, from its permissions (D-261).
public enum ExtensionAccess: String, CaseIterable, Hashable, Sendable, Comparable {
    case everySite, someSites, history, cookies, webTraffic, tabs, clipboard, downloads, bookmarks, appsOnMac, location,
         otherExtensions

    /// Pure: the permissions as access, without the ones that reach nothing of yours (storage,
    /// alarms, menus).
    public static func from(_ permissions: [String]) -> [ExtensionAccess] {
        var found: Set<ExtensionAccess> = []
        for permission in permissions {
            if let access = access(permission) {
                found.insert(access)
            }
        }
        if found.contains(.everySite) {
            found.remove(.someSites)
        }
        return found.sorted()
    }

    static func access(_ permission: String) -> ExtensionAccess? {
        switch permission {
        case "<all_urls>", "*://*/*", "http://*/*", "https://*/*", "file:///*": return .everySite
        case "history", "topSites": return .history
        case "cookies": return .cookies
        case "webRequest", "webRequestBlocking", "declarativeNetRequest", "declarativeNetRequestWithHostAccess", "proxy": return .webTraffic
        case "tabs", "activeTab", "tabGroups": return .tabs
        case "clipboardRead": return .clipboard
        case "downloads": return .downloads
        case "bookmarks": return .bookmarks
        case "nativeMessaging": return .appsOnMac
        case "geolocation": return .location
        case "management": return .otherExtensions
        default:
            // A site pattern: "https://*.example.com/*".
            return permission.contains("://") ? .someSites : nil
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }
}

/// The browsers' extensions, and the browsers whose files Mactivity couldn't read.
public struct BrowserExtensionsReading: Hashable, Sendable {
    public let extensions: [BrowserExtension]
    /// Installed, but their profiles need Full Disk Access to read.
    public let blocked: [Browser]

    public init(extensions: [BrowserExtension], blocked: [Browser]) {
        self.extensions = extensions
        self.blocked = blocked
    }
}

/// Where the Security page reads from (D-261): the real Mac, or Simulated.
public protocol SecuritySource: Sendable {
    func settings() async -> SecuritySettings
    func permissions() async -> PermissionsReading
    func systemExtensions() async -> [SystemExtensionItem]
    func browserExtensions() async -> BrowserExtensionsReading
}
