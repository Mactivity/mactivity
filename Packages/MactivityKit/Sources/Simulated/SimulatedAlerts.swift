import Core
import Foundation

/// A few days of alerts for the simulated Mac (D-239), so the Alerts page, the screenshots and the
/// demo show what the page is for rather than its empty state.
public enum SimulatedAlerts {
    public static func recent(now: Date = Date()) -> [Alert] {
        func app(_ name: String) -> AppIdentity {
            SimulatedCatalog.apps.first { $0.identity.name == name }?.identity
                ?? AppIdentity(id: name, name: name, bundleID: nil, iconKey: "other", kind: .other)
        }
        let mac = AppIdentity(id: "mac", name: "Mac", bundleID: nil, iconKey: "macos", kind: .system)
        let hour: TimeInterval = 3600
        return [
            Alert(
                rule: .growingMemory, app: app("Safari"), firedAt: now - 0.4 * hour,
                title: "Safari's memory keeps climbing", body: "Up 1.4 GB in an hour, now 3.3 GB."
            ),
            Alert(
                rule: .highCPU, app: app("Xcode"), firedAt: now - 3 * hour,
                title: "Xcode is using a lot of CPU", body: "94% of a core for 6 minutes."
            ),
            Alert(
                rule: .newStartupItem, app: mac, firedAt: now - 26 * hour,
                title: "Zoom now starts with your Mac", body: "It added us.zoom.updater, an agent that runs at login."
            ),
            Alert(
                rule: .overheating, app: mac, firedAt: now - 74 * hour,
                title: "Your Mac is running hot", body: "Slowed down to cool for 7 of the last 10 minutes."
            ),
        ]
    }
}
