import Core
import Foundation
import Observation

/// The Security page's state (1.9, D-261): read when the page shows, and again with Refresh.
/// The settings alone are kept for Checkup, read at most every 10 minutes.
@MainActor
@Observable
final class SecurityModel {
    private let source: any SecuritySource
    private(set) var settings: SecuritySettings?
    private(set) var permissions: PermissionsReading?
    private(set) var systemExtensions: [SystemExtensionItem]?
    private(set) var browsers: BrowserExtensionsReading?
    @ObservationIgnored private var settingsReadAt: Date?

    init(source: any SecuritySource) {
        self.source = source
    }

    func load() async {
        async let settings = source.settings()
        async let permissions = source.permissions()
        async let system = source.systemExtensions()
        async let browsers = source.browserExtensions()
        self.settings = await settings
        settingsReadAt = Date()
        self.permissions = await permissions
        systemExtensions = await system
        self.browsers = await browsers
    }

    /// For Checkup: the settings, read again when over 10 minutes old.
    func checkupSettings(now: Date = Date()) async -> SecuritySettings {
        if let settings, let at = settingsReadAt, now.timeIntervalSince(at) < 600, now >= at {
            return settings
        }
        let fresh = await source.settings()
        settings = fresh
        settingsReadAt = now
        return fresh
    }

    /// The permissions, by kind in System Settings' order; within each, allowed first, then by name.
    nonisolated static func grouped(_ permissions: [AppPermission], name: (AppPermission) -> String) -> [(
        PermissionKind,
        [AppPermission]
    )] {
        PermissionKind.allCases.compactMap { kind in
            let found = permissions.filter { $0.kind == kind }
            guard !found.isEmpty else {
                return nil
            }
            return (kind, found.sorted { ($0.allowed ? 0 : 1, name($0).lowercased()) < ($1.allowed ? 0 : 1, name($1).lowercased()) })
        }
    }
}
