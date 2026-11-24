import Core
import Foundation

/// The Security page for previews and Simulated data (D-261): a Mac with the firewall off, a
/// handful of permissions, a network filter, and three browsers' extensions.
public struct SimulatedSecurity: SecuritySource {
    public init() {}

    public func settings() async -> SecuritySettings {
        SecuritySettings(
            fileVault: true, firewall: false, gatekeeper: true, systemIntegrity: true, securityResponses: true, macOSUpdates: false
        )
    }

    public func permissions() async -> PermissionsReading {
        let changed = Date().addingTimeInterval(-40 * 86400)
        return .read([
            AppPermission(kind: .camera, client: "com.apple.FaceTime", clientIsPath: false, allowed: true, changed: changed),
            AppPermission(kind: .camera, client: "com.apple.PhotoBooth", clientIsPath: false, allowed: true, changed: changed),
            AppPermission(kind: .microphone, client: "com.apple.FaceTime", clientIsPath: false, allowed: true, changed: changed),
            AppPermission(kind: .microphone, client: "com.apple.VoiceMemos", clientIsPath: false, allowed: true, changed: changed),
            AppPermission(kind: .microphone, client: "com.apple.Safari", clientIsPath: false, allowed: false, changed: changed),
            AppPermission(
                kind: .screenRecording,
                client: "com.apple.QuickTimePlayerX",
                clientIsPath: false,
                allowed: true,
                changed: changed
            ),
            AppPermission(kind: .fullDiskAccess, client: "com.apple.Terminal", clientIsPath: false, allowed: true, changed: changed),
            AppPermission(kind: .fullDiskAccess, client: "app.mactivity.Mactivity", clientIsPath: false, allowed: true, changed: changed),
            AppPermission(kind: .accessibility, client: "com.apple.Terminal", clientIsPath: false, allowed: true, changed: changed),
            AppPermission(
                kind: .inputMonitoring,
                client: "/usr/local/bin/keyboard-tool",
                clientIsPath: true,
                allowed: false,
                changed: changed
            ),
            AppPermission(
                kind: .automation, client: "com.apple.Terminal", clientIsPath: false, allowed: true, changed: changed,
                target: "com.apple.finder"
            ),
        ], unreadable: [])
    }

    public func systemExtensions() async -> [SystemExtensionItem] {
        [
            SystemExtensionItem(
                kind: .systemExtension, identifier: "com.example.vpn.tunnel", name: "Example VPN", version: "3.4",
                teamID: "ABCDE12345", category: "network_extension", isOn: true
            ),
        ]
    }

    public func browserExtensions() async -> BrowserExtensionsReading {
        BrowserExtensionsReading(extensions: [
            BrowserExtension(
                browser: .safari, identifier: "com.1password.safari.extension", name: "1Password", version: "8.12", isOn: nil,
                permissions: ["<all_urls>", "tabs", "nativeMessaging", "storage"]
            ),
            BrowserExtension(
                browser: .chrome, identifier: "cjpalhdlnbpafiamejdnhcphjbkeiagm", name: "uBlock Origin", version: "1.60", isOn: true,
                permissions: ["<all_urls>", "webRequest", "storage", "tabs"]
            ),
            BrowserExtension(
                browser: .chrome, identifier: "aapbdbdomjkkjkaonfhkkikfgjllcleb", name: "Google Translate", version: "2.0", isOn: false,
                permissions: ["activeTab", "contextMenus", "storage"]
            ),
            BrowserExtension(
                browser: .firefox, identifier: "dark@example.org", name: "Dark Reader", version: "4.9", isOn: true,
                permissions: ["<all_urls>", "storage"]
            ),
        ], blocked: [])
    }
}
