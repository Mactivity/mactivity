import AppKit
import Core
import SwiftUI

/// Muted apps, and a menu of running apps to mute. The running apps are read from the latest
/// snapshot when the pane appears, when the pointer reaches the menu, and every 10 s while it's
/// open, not in `body`: that read the snapshot, so the whole pane re-evaluated and re-sorted every
/// app by name on every tick (D-086).
struct MutedAppsSection: View {
    let services: AppServices

    @State private var running: [AppIdentity] = []

    var body: some View {
        Section(String(
            localized: "Apps with muted alerts",
            bundle: .strings,
            comment: "Alert settings section: apps whose alerts are silenced (not their sound)"
        )) {
            let muted = services.alertSettings.mutedAppIDs.sorted()
            if muted.isEmpty {
                Text(String(
                    localized: "alerts.mutedApps.none",
                    defaultValue: "None",
                    bundle: .strings,
                    comment: "Alert settings: no app has its alerts muted"
                )).foregroundStyle(.secondary)
            }
            ForEach(muted, id: \.self) { id in
                HStack {
                    Text(running.first { $0.id == id }?.name ?? Self.name(forMuted: id, services: services))
                    Spacer()
                    Button(String(localized: "Unmute", bundle: .strings)) { services.alertSettings.mutedAppIDs.remove(id) }
                }
            }
            Menu(String(localized: "Mute an App", bundle: .strings)) {
                ForEach(running.filter { !services.alertSettings.mutedAppIDs.contains($0.id) }, id: \.id) { app in
                    Button(app.name) { services.alertSettings.mutedAppIDs.insert(app.id) }
                }
            }
            .onHover { inside in
                if inside {
                    refresh()
                }
            }
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(10), tolerance: .seconds(2))
            }
        }
    }

    /// Running apps except macOS, by name. Assigned only when the list changed.
    private func refresh() {
        let apps = Self.runningApps(services.metrics.snapshot)
        if apps != running {
            running = apps
        }
    }

    static func runningApps(_ snapshot: Snapshot?) -> [AppIdentity] {
        (snapshot?.apps ?? [])
            .map(\.app)
            .filter { $0.kind != .system }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension MutedAppsSection {
    /// A muted entry that isn't a running app: an accessory, the disk, the Mac's sleep, or an app
    /// that crashed (D-099). Otherwise the ID itself.
    static func name(forMuted id: String, services: AppServices) -> String {
        if id.hasPrefix("device:") {
            let deviceID = String(id.dropFirst("device:".count))
            return services.metrics.snapshot?.system.sensors?.peripherals.first { $0.id == deviceID }?.name
                ?? String(localized: "An accessory", bundle: .strings, comment: "Muted alerts: an accessory not connected now")
        }
        switch id {
        case "mac:disk": return AlertRule.diskFilling.title
        case "mac:sleep": return AlertRule.notSleeping.title
        default:
            let key = id.hasPrefix("crash:") ? String(id.dropFirst("crash:".count)) : id
            return displayName(key)
        }
    }

    /// An app that isn't running, by name, not by ID (D-196): a bundle ID's app from Launch
    /// Services ("com.tinyspeck.slackmacgap" is Slack), "other:node" as node.
    nonisolated static func displayName(_ id: String) -> String {
        if id.hasPrefix("other:") {
            return String(id.dropFirst("other:".count))
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id
    }
}
