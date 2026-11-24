import Core
import SwiftUI

/// How each alert rule looks: its symbol, its color, and the group it's listed under (D-239).
extension AlertRule {
    var symbol: String {
        switch self {
        case .highCPU: "cpu"
        case .growingMemory: "memorychip"
        case .heavyDisk: "internaldrive"
        case .heavyNetwork: "network"
        case .hotspotData: "personalhotspot"
        case .accessoryBatteryLow: "battery.25percent"
        case .diskFilling: "chart.line.uptrend.xyaxis"
        case .diskLow: "externaldrive.badge.exclamationmark"
        case .appCrashing: "exclamationmark.triangle"
        case .notSleeping: "moon.zzz"
        case .overheating: "thermometer.high"
        case .connectionLost: "wifi.exclamationmark"
        case .runawayProcess: "terminal"
        case .outOfTheOrdinary: "waveform.path.ecg"
        case .agentLongSession: "clock.badge.exclamationmark"
        case .agentMemory: "sparkles"
        case .newStartupItem: "power"
        case .dataBudget: "gauge.with.dots.needle.67percent"
        case .vulnerableSoftware: "shippingbox"
        }
    }

    var tint: Color {
        switch self {
        case .highCPU: Tokens.SidebarTint.cpu
        case .growingMemory: Tokens.SidebarTint.memory
        case .heavyDisk, .diskFilling, .diskLow: Tokens.SidebarTint.disk
        case .heavyNetwork, .connectionLost, .dataBudget: Tokens.SidebarTint.network
        case .hotspotData, .accessoryBatteryLow: Tokens.SidebarTint.battery
        case .appCrashing, .overheating: .red
        case .notSleeping: .indigo
        case .runawayProcess: Tokens.SidebarTint.projects
        case .outOfTheOrdinary: .pink
        case .agentLongSession, .agentMemory: Tokens.SidebarTint.agents
        case .newStartupItem: Tokens.SidebarTint.startup
        case .vulnerableSoftware: .red
        }
    }

    /// The Rules view's groups, in order.
    enum Group: CaseIterable {
        case apps, mac, network, developers

        var title: String {
            switch self {
            case .apps: String(localized: "Apps", bundle: .strings, comment: "Alert rules group: rules about one app")
            case .mac: String(localized: "Your Mac", bundle: .strings, comment: "Alert rules group: the disk, heat, sleep, accessories")
            case .network: String(localized: "Network and security", bundle: .strings, comment: "Alert rules group")
            case .developers: String(
                    localized: "Developers",
                    bundle: .strings,
                    comment: "Alert rules group: dev processes and coding agents"
                )
            }
        }

        var rules: [AlertRule] {
            switch self {
            case .apps: [.highCPU, .growingMemory, .heavyDisk, .heavyNetwork, .appCrashing, .outOfTheOrdinary]
            case .mac: [.diskFilling, .diskLow, .overheating, .notSleeping, .accessoryBatteryLow]
            case .network: [.connectionLost, .hotspotData, .dataBudget, .newStartupItem, .vulnerableSoftware]
            case .developers: [.runawayProcess, .agentLongSession, .agentMemory]
            }
        }
    }
}

/// A rule's symbol, white on its color, the way System Settings marks its panes.
struct RuleBadge: View {
    let rule: AlertRule
    var size: CGFloat = 28

    var body: some View {
        SymbolBadge(symbol: rule.symbol, tint: rule.tint, size: size)
    }
}

/// A symbol, white on a rounded square of its color (D-239): Alerts, Checkup and the other lists
/// of things that happened or need doing.
struct SymbolBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A section's title at the page's own weight, not the small caption a grouped form gives it.
struct SectionHeading: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
    }
}
