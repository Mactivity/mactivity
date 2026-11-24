import AppKit
import Core
import CoreGraphics
import Foundation
import History
import UI

/// Time in front (D-098): which app is frontmost while someone is using the Mac. Driven by
/// NSWorkspace's notifications; the only timer is a once-a-minute idle check. A stretch ends when
/// another app comes forward, the Mac or its display sleeps, the session locks, or five minutes
/// pass without input (counted to the last input). Stretches under five seconds aren't kept.
@MainActor
final class FocusRecorder {
    static let idleLimit: TimeInterval = 300
    static let shortest: TimeInterval = 5

    private var current: (app: AppIdentity, since: Date)?
    /// Asleep, display off, or the session locked: nothing counts until it's back.
    private var paused = false
    private var observers: [NSObjectProtocol] = []
    private var idleTimer: Timer?
    private let store: () -> (any FocusStore)?

    /// `store` is the running pipeline's, or nil while simulated or turned off.
    init(store: @escaping () -> (any FocusStore)?) {
        self.store = store
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self.switchTo(app) }
        })
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.pause() }
            })
        }
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.resume() }
            })
        }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { self.checkIdle() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
        switchTo(NSWorkspace.shared.frontmostApplication)
    }

    /// Writes the stretch in progress and waits for it: called on quit, which doesn't wait for tasks.
    func flush() async {
        guard let (app, since) = current else {
            return
        }
        current = nil
        let end = Date()
        guard end.timeIntervalSince(since) >= Self.shortest, let store = store() else {
            return
        }
        try? await store.recordFocus(app, from: since, to: end)
    }

    private func switchTo(_ running: NSRunningApplication?) {
        let now = Date()
        close(at: now)
        guard !paused, let running, let identity = Self.identity(running) else {
            return
        }
        current = (identity, now)
    }

    private func pause() {
        close(at: Date())
        paused = true
    }

    private func resume() {
        paused = false
        switchTo(NSWorkspace.shared.frontmostApplication)
    }

    private func checkIdle() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null)
        if idle >= Self.idleLimit {
            close(at: Date().addingTimeInterval(-idle))
        } else if current == nil, !paused {
            switchTo(NSWorkspace.shared.frontmostApplication)
        }
    }

    private func close(at end: Date) {
        guard let (app, since) = current else {
            return
        }
        current = nil
        guard end.timeIntervalSince(since) >= Self.shortest, let store = store() else {
            return
        }
        Task { try? await store.recordFocus(app, from: since, to: end) }
    }

    /// Mactivity itself counts like any app. Apps without a bundle ID (rare in front) aren't kept.
    static func identity(_ running: NSRunningApplication) -> AppIdentity? {
        guard let bundleID = running.bundleIdentifier else {
            return nil
        }
        return AppIdentity(
            id: bundleID, name: running.localizedName ?? bundleID, bundleID: bundleID,
            iconKey: running.bundleURL?.path ?? "other", kind: .app
        )
    }
}
