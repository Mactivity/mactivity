import AppKit
import Core
import Foundation

/// App launch times (D-215): each app's process start to macOS saying it finished launching,
/// from `NSWorkspace.didLaunchApplicationNotification`. Not in the first five minutes after the
/// Mac starts, and not a launch held up for minutes (`AppLaunch.isWorthKeeping`). Event-driven:
/// nothing runs between launches.
@MainActor
final class LaunchRecorder {
    static let shared = LaunchRecorder()
    private var observer: NSObjectProtocol?

    func start(store: @escaping @MainActor () -> (any AppLaunchStore)?) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            let now = Date()
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let started = app.launchDate, let id = app.bundleIdentifier else {
                return
            }
            let seconds = now.timeIntervalSince(started)
            guard AppLaunch.isWorthKeeping(seconds: seconds, uptime: ProcessInfo.processInfo.systemUptime) else {
                return
            }
            let launch = AppLaunch(at: started, appID: id, name: app.localizedName ?? id, seconds: seconds)
            MainActor.assumeIsolated {
                guard let store = store() else {
                    return
                }
                Task { try? await store.recordLaunch(launch) }
            }
        }
    }
}
