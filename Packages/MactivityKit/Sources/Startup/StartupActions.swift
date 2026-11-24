import AppKit
import ServiceManagement

/// The read-only actions: show a file, open the system's own list.
@MainActor
public enum StartupActions {
    /// Selects the plist (or the helper app) in a Finder window.
    public static func revealInFinder(_ item: StartupItem) {
        let url = URL(fileURLWithPath: item.revealPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// System Settings → General → Login Items & Extensions, the complete list and the only place
    /// to turn off items Mactivity can't.
    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
