import Foundation
import os
import Sampling
import ServiceManagement
import UI

/// Registers the privileged helper with `SMAppService.daemon` (spec 6.9). Off by default; the
/// user turns it on in Settings and approves it in System Settings → Login Items.
@MainActor
enum HelperControl {
    private static let log = Logger(subsystem: "app.mactivity.app", category: "helper")

    /// The app's own team, baked in at build time. Nil in ad-hoc builds, where the helper can't
    /// pin code signatures and stays unavailable.
    static let teamID: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "MactivityTeamID") as? String ?? ""
        return value.isEmpty ? nil : value
    }()

    private static var service: SMAppService {
        SMAppService.daemon(plistName: HelperIdentity.plistName)
    }

    static var status: HelperStatus {
        guard teamID != nil else {
            return .needsSignedBuild
        }
        switch service.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    static func set(_ enabled: Bool) -> HelperStatus {
        guard teamID != nil else {
            return .needsSignedBuild
        }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            log.error("Helper \(enabled ? "register" : "unregister") failed: \(String(describing: error))")
        }
        return status
    }
}
