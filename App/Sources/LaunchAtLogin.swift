import Foundation
import os
import ServiceManagement

/// Launch at login via `SMAppService.mainApp` (spec 5.10). The system owns the state; this
/// reads it fresh every time rather than caching a copy that can drift.
@MainActor
enum LaunchAtLogin {
    private static let log = Logger(subsystem: "app.mactivity.app", category: "login")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Needs approval in System Settings → General → Login Items.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            log.error("Launch at login \(enabled ? "on" : "off") failed: \(String(describing: error))")
            return false
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
