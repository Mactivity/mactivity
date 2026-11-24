import Core
import SwiftUI

/// The words, symbol and color for each kind of day event (D-191).
enum DayEventText {
    static func title(_ event: DayEvent) -> String {
        switch event.kind {
        case let .wake(cause):
            guard let cause, cause != .other else {
                return String(localized: "Woke up", bundle: .strings, comment: "Your day: the Mac woke from sleep")
            }
            return String(
                localized: "Woke up: \(SleepCard.causeText(cause))",
                bundle: .strings,
                comment: "Your day: the Mac woke, and what woke it, e.g. Woke up: Lid opened"
            )
        case .sleep:
            return String(localized: "Went to sleep", bundle: .strings, comment: "Your day: the Mac slept")
        case let .busy(peak):
            return String(
                localized: "Busy, the processor up to \(Formatters.percent(peak))",
                bundle: .strings,
                comment: "Your day: a stretch of heavy but not overwhelming processor use, e.g. up to 72%"
            )
        case let .slowdown(causes):
            let cause = causes.first.map(EarlierSlowdown.title) ?? EarlierSlowdown.title(.cpu)
            return String(
                localized: "Slowdown: \(cause)",
                bundle: .strings,
                comment: "Your day: a slowdown and its cause, e.g. Slowdown: Memory ran short"
            )
        case let .unplugged(level):
            return level.map {
                String(
                    localized: "Unplugged at \(Formatters.percent($0))",
                    bundle: .strings,
                    comment: "Your day: taken off the charger, e.g. at 96%"
                )
            } ?? String(localized: "Unplugged", bundle: .strings, comment: "Your day: taken off the charger")
        case let .pluggedIn(level):
            return level.map {
                String(
                    localized: "Plugged in at \(Formatters.percent($0))",
                    bundle: .strings,
                    comment: "Your day: put on the charger, e.g. at 31%"
                )
            } ?? String(localized: "Plugged in", bundle: .strings, comment: "Your day: put on the charger")
        case let .download(bytes):
            return String(
                localized: "Downloaded \(Formatters.bytes(bytes))",
                bundle: .strings,
                comment: "Your day: an hour that received a lot of data, e.g. Downloaded 3.2 GB"
            )
        case let .alert(title, _, count):
            // "×4": the same in every language, so no new phrase to translate.
            return count > 1 ? "\(title) ×\(count.formatted())" : title
        case .agent, .crash:
            return appTitle(event.kind)
        case let .network(kind):
            return networkTitle(kind)
        case let .note(_, text):
            return text
        case let .sensor(sensors, app):
            return sensorTitle(sensors, app: app)
        }
    }

    /// "FaceTime used the camera and microphone" (D-259).
    private static func sensorTitle(_ sensors: [PrivacySensor], app: String?) -> String {
        let name = app.map(MutedAppsSection.displayName)
            ?? String(localized: "An app", bundle: .strings, comment: "Camera and microphone history: macOS didn't say which app")
        if sensors.contains(.camera), sensors.contains(.microphone) {
            return String(
                localized: "\(name) used the camera and microphone",
                bundle: .strings,
                comment: "Your day: e.g. FaceTime used the camera and microphone"
            )
        }
        if sensors.contains(.camera) {
            return String(localized: "\(name) used the camera", bundle: .strings, comment: "Your day: e.g. Photo Booth used the camera")
        }
        if sensors.contains(.microphone) {
            return String(
                localized: "\(name) used the microphone",
                bundle: .strings,
                comment: "Your day: e.g. Voice Memos used the microphone"
            )
        }
        return String(
            localized: "\(name) recorded the screen",
            bundle: .strings,
            comment: "Your day: e.g. QuickTime Player recorded the screen"
        )
    }

    /// A drop, or time on a hotspot, a VPN or Ethernet (D-233).
    private static func networkTitle(_ kind: NetworkKind) -> String {
        switch kind {
        case .offline: String(localized: "Lost the network connection", bundle: .strings, comment: "Your day: the Mac was offline")
        case .hotspot: String(localized: "On Personal Hotspot", bundle: .strings, comment: "Your day: connected through an iPhone")
        case .vpn: String(localized: "On a VPN", bundle: .strings, comment: "Your day: connected through a VPN")
        case .ethernet: String(localized: "On Ethernet", bundle: .strings, comment: "Your day: connected by cable")
        case .wifi, .cellular, .other, .asleep: kind.title
        }
    }

    /// Agents and crashes: titled by their app.
    private static func appTitle(_ kind: DayEvent.Kind) -> String {
        switch kind {
        case let .agent(name, project):
            return project.isEmpty
                ? name
                : String(
                    localized: "\(name) in \(project)",
                    bundle: .strings,
                    comment: "Your day: a coding agent's session, e.g. Claude Code in mactivity"
                )
        case let .crash(app, hang):
            return hang
                ? String(localized: "\(app) stopped responding", bundle: .strings, comment: "Your day: an app hung")
                : String(localized: "\(app) quit unexpectedly", bundle: .strings, comment: "Your day: an app crashed")
        default:
            return ""
        }
    }

    static func symbol(_ kind: DayEvent.Kind) -> String {
        switch kind {
        case .wake: "sun.max"
        case .sleep: "moon.zzz"
        case .busy: "cpu"
        case .slowdown: "tortoise"
        case .unplugged: "battery.75percent"
        case .pluggedIn: "powerplug"
        case .download: "arrow.down.circle"
        case .alert: "bell"
        case .crash: "exclamationmark.triangle"
        case .agent: SidebarItem.agents.symbol
        case let .network(kind): WiFiText.symbol(kind)
        case .note: "note.text"
        case let .sensor(sensors, _):
            sensors.contains(.camera) ? PrivacySensor.camera.symbol : (sensors.first ?? .microphone).symbol
        }
    }

    static func tint(_ kind: DayEvent.Kind) -> Color {
        switch kind {
        case .wake: .orange
        case .sleep: .indigo
        case .busy: MetricTab.cpu.tint
        // Red, not the strain orange: on the Today ribbon it sat beside agents' orange (D-194).
        case .slowdown: .red
        case .unplugged, .pluggedIn: MetricTab.battery.tint
        case .download: MetricTab.network.tint
        case .alert: .yellow
        case .crash: .red
        case .agent: Tokens.SidebarTint.agents
        case let .network(kind): kind == .offline ? .red : MetricTab.network.tint
        case .note: .purple
        // Green, like the camera's light.
        case .sensor: .green
        }
    }
}
