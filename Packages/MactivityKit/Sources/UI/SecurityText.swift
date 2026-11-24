import AppKit
import Core
import SwiftUI

/// The Security page's words (1.9, D-261).
enum SecurityText {
    /// One of the Mac's protections, as a row: its name, whether on is good, and what it does.
    struct Setting: Identifiable {
        let id: String
        let title: String
        let isOn: Bool?
        /// What it protects, in a sentence.
        let help: String
        /// Where to change it.
        let settingsURL: URL?
        /// Off is worth fixing soon (the ones Checkup names); the rest are worth knowing.
        let important: Bool
    }

    static func settings(_ value: SecuritySettings) -> [Setting] {
        let privacy = URL(string: "x-apple.systempreferences:com.apple.preference.security")
        let updates = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
        let network = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")
        return [
            Setting(
                id: "filevault", title: "FileVault", isOn: value.fileVault,
                help: String(localized: "Encrypts the startup disk, so no one can read it without your password.", bundle: .strings),
                settingsURL: privacy, important: true
            ),
            Setting(
                id: "gatekeeper", title: "Gatekeeper", isOn: value.gatekeeper,
                help: String(localized: "Checks who made an app, and that it isn't known malware, before it opens.", bundle: .strings),
                settingsURL: privacy, important: true
            ),
            Setting(
                id: "sip", title: String(localized: "System Integrity Protection", bundle: .strings), isOn: value.systemIntegrity,
                help: String(localized: "Keeps macOS's own files from being changed, even by an administrator.", bundle: .strings),
                settingsURL: nil, important: true
            ),
            Setting(
                id: "responses", title: String(localized: "Security fixes install by themselves", bundle: .strings),
                isOn: value.securityResponses,
                help: String(
                    localized: "Apple's urgent fixes and malware definitions arrive without waiting for a macOS update.",
                    bundle: .strings
                ),
                settingsURL: updates, important: true
            ),
            Setting(
                id: "updates", title: String(localized: "macOS updates install by themselves", bundle: .strings),
                isOn: value.macOSUpdates,
                help: String(localized: "New versions of macOS install overnight, when the Mac is plugged in.", bundle: .strings),
                settingsURL: updates, important: false
            ),
            Setting(
                id: "firewall", title: String(localized: "Firewall", bundle: .strings, comment: "Security page: the macOS firewall"),
                isOn: value.firewall,
                help: String(
                    localized: """
                    Blocks connections other devices start to apps on your Mac. Off on a new Mac; worth turning on \
                    for public Wi-Fi.
                    """,
                    bundle: .strings
                ),
                settingsURL: network, important: false
            ),
        ]
    }

    static func state(_ isOn: Bool?) -> String {
        switch isOn {
        case true?: String(localized: "On", bundle: .strings, comment: "Security page: a protection is on")
        case false?: String(localized: "Off", bundle: .strings, comment: "Security page: a protection is off")
        case nil: String(localized: "Unknown", bundle: .strings, comment: "Security page: couldn't read a protection")
        }
    }

    static func title(_ kind: PermissionKind) -> String {
        switch kind {
        case .camera: PrivacySensor.camera.title
        case .microphone: PrivacySensor.microphone.title
        case .screenRecording: PrivacySensor.screen.title
        case .fullDiskAccess: String(localized: "Full Disk Access", bundle: .strings, comment: "Privacy permission")
        case .accessibility: String(localized: "Accessibility", bundle: .strings, comment: "Privacy permission: control the Mac")
        case .inputMonitoring: String(localized: "Input Monitoring", bundle: .strings, comment: "Privacy permission: read the keyboard")
        case .automation: String(localized: "Automation", bundle: .strings, comment: "Privacy permission: control other apps")
        case .files: String(localized: "Files and Folders", bundle: .strings, comment: "Privacy permission")
        }
    }

    /// What the permission lets an app do, for its hover.
    static func help(_ kind: PermissionKind) -> String {
        switch kind {
        case .camera, .microphone:
            String(localized: "Can turn it on whenever it's open. macOS shows a dot in the menu bar while it does.", bundle: .strings)
        case .screenRecording:
            String(localized: "Can see and record everything on your screen.", bundle: .strings)
        case .fullDiskAccess:
            String(localized: "Can read every file, including Mail, Messages and other apps' data.", bundle: .strings)
        case .accessibility:
            String(localized: "Can control your Mac: click, type and read what's in other apps' windows.", bundle: .strings)
        case .inputMonitoring:
            String(localized: "Can read every key you press, in any app.", bundle: .strings)
        case .automation:
            String(localized: "Can control another app: open its documents, read them and act in it.", bundle: .strings)
        case .files:
            String(localized: "Can read your Desktop, Documents, Downloads or external drives.", bundle: .strings)
        }
    }

    static func settingsURL(_ kind: PermissionKind) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)")
    }

    /// An app's name from its bundle ID, or a tool's name from its path.
    static func name(_ permission: AppPermission) -> String {
        permission.clientIsPath ? (permission.client as NSString).lastPathComponent : MutedAppsSection.displayName(permission.client)
    }

    static func access(_ access: ExtensionAccess) -> String {
        switch access {
        case .everySite: String(localized: "Every website", bundle: .strings, comment: "Browser extension can read: all sites")
        case .someSites: String(localized: "Some websites", bundle: .strings, comment: "Browser extension can read: listed sites")
        case .history: String(localized: "Your history", bundle: .strings, comment: "Browser extension can read")
        case .cookies: String(localized: "Cookies", bundle: .strings, comment: "Browser extension can read")
        case .webTraffic: String(localized: "Web traffic", bundle: .strings, comment: "Browser extension can see or change requests")
        case .tabs: String(localized: "Your tabs", bundle: .strings, comment: "Browser extension can read")
        case .clipboard: String(localized: "What you copy", bundle: .strings, comment: "Browser extension can read the clipboard")
        case .downloads: String(localized: "Downloads", bundle: .strings, comment: "Browser extension can manage downloads")
        case .bookmarks: String(localized: "Bookmarks", bundle: .strings, comment: "Browser extension can read")
        case .appsOnMac: String(localized: "Apps on your Mac", bundle: .strings, comment: "Browser extension can talk to installed apps")
        case .location: String(localized: "Your location", bundle: .strings, comment: "Browser extension can read")
        case .otherExtensions: String(localized: "Other extensions", bundle: .strings, comment: "Browser extension can manage others")
        }
    }

    /// "Every website · Your tabs · Apps on your Mac", or "Nothing of yours" for an extension
    /// that only stores its own settings.
    static func reach(_ item: BrowserExtension) -> String {
        let access = item.access
        guard !access.isEmpty else {
            return String(localized: "Nothing of yours", bundle: .strings, comment: "Browser extension with no access to pages or data")
        }
        return access.map(Self.access).joined(separator: " · ")
    }

    static func kind(_ item: SystemExtensionItem) -> String {
        switch item.category {
        case "network_extension"?: String(localized: "Network filter or VPN", bundle: .strings, comment: "System extension kind")
        case "driver_extension"?: String(localized: "Driver", bundle: .strings, comment: "System extension kind")
        case "endpoint_security_extension"?: String(localized: "Security tool", bundle: .strings, comment: "System extension kind")
        default:
            if item.kind == .kernelExtension {
                String(localized: "Kernel extension", bundle: .strings, comment: "An older kind of driver, loaded into the kernel")
            } else {
                String(localized: "System extension", bundle: .strings)
            }
        }
    }
}
