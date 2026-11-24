import Foundation
import os
import Sparkle

/// Sparkle, only when this build has an appcast URL and a public EdDSA key (spec 5.10, 12.4).
/// The update check is the one network call Mactivity makes on its own (CLAUDE.md rule 3).
@MainActor
final class Updates {
    static let shared = Updates()

    private static let log = Logger(subsystem: "app.mactivity.app", category: "updates")

    private let controller: SPUStandardUpdaterController?

    /// Whether this build can check for updates at all.
    var isConfigured: Bool {
        controller != nil
    }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        guard !feed.isEmpty, !key.isEmpty else {
            Self.log.info("Updates not configured in this build (no SUFeedURL or SUPublicEDKey)")
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
