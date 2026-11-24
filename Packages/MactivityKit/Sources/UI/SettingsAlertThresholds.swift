import Core
import SwiftUI

/// The Mac-level rules' thresholds in Settings → Alerts (D-099 on), and the agent limits' (D-227).
extension AlertSettingsPane {
    @ViewBuilder
    func systemThresholdField(_ rule: AlertRule) -> some View {
        switch rule {
        case .accessoryBatteryLow:
            Picker(String(localized: "At or below", bundle: .strings, comment: "Alert threshold"), selection: binding(rule, \.threshold)) {
                ForEach([10.0, 15, 20, 25], id: \.self) { Text(Formatters.percent($0)).tag($0) }
            }
        case .diskFilling:
            Picker(
                String(localized: "Full within", bundle: .strings, comment: "Alert threshold: days until the disk is full"),
                selection: binding(rule, \.threshold)
            ) {
                ForEach([7.0, 14, 30], id: \.self) { days in
                    Text(Duration.seconds(days * 86400).formatted(.units(allowed: [.weeks, .days], width: .wide))).tag(days)
                }
            }
        case .appCrashing:
            Picker(
                String(localized: "Crashes in a day", bundle: .strings, comment: "Alert threshold"),
                selection: binding(rule, \.threshold)
            ) {
                ForEach([2.0, 3, 5], id: \.self) { Text(Int($0).formatted()).tag($0) }
            }
        case .hotspotData:
            Picker(
                String(localized: "In 10 minutes, above", bundle: .strings, comment: "Alert threshold: data used on a hotspot"),
                selection: binding(rule, \.threshold)
            ) {
                ForEach([50_000_000.0, 200_000_000, 500_000_000, 1_000_000_000], id: \.self) { Text(Formatters.bytes($0)).tag($0) }
            }
        case .diskLow:
            Picker(
                String(localized: "Free space below", bundle: .strings, comment: "Alert threshold"), selection: binding(rule, \.threshold)
            ) {
                ForEach([5_000_000_000.0, 10_000_000_000, 20_000_000_000, 50_000_000_000], id: \.self) {
                    Text(Formatters.bytes($0)).tag($0)
                }
            }
        case .overheating:
            Picker(
                String(localized: "Slowed down for", bundle: .strings, comment: "Alert threshold: minutes of the last 10 the Mac was hot"),
                selection: binding(rule, \.threshold)
            ) {
                ForEach([3.0, 5, 8], id: \.self) { Text(Formatters.duration(.seconds($0 * 60))).tag($0) }
            }
        case .runawayProcess, .outOfTheOrdinary, .agentLongSession, .agentMemory:
            newerThresholdField(rule)
        case .dataBudget:
            Picker(
                String(localized: "At", bundle: .strings, comment: "Alert threshold: percent of the data budget used"),
                selection: binding(rule, \.threshold)
            ) {
                ForEach([50.0, 75, 80, 90], id: \.self) { Text(Formatters.percent($0)).tag($0) }
            }
        case .notSleeping, .connectionLost, .highCPU, .growingMemory, .heavyDisk, .heavyNetwork, .newStartupItem,
             .vulnerableSoftware:
            EmptyView()
        }
    }

    /// Runaway processes (D-156), out of the ordinary (D-201) and the agent limits (D-227).
    @ViewBuilder
    func newerThresholdField(_ rule: AlertRule) -> some View {
        switch rule {
        case .runawayProcess:
            Picker(
                String(localized: "At a full core for", bundle: .strings, comment: "Alert threshold: minutes a dev process is stuck"),
                selection: binding(rule, \.threshold)
            ) {
                ForEach([5.0, 10, 15, 30], id: \.self) { Text(Formatters.duration(.seconds($0 * 60))).tag($0) }
            }
        case .outOfTheOrdinary:
            Picker(
                String(localized: "At least", bundle: .strings, comment: "Alert threshold: times an app's usual day"),
                selection: binding(rule, \.threshold)
            ) {
                ForEach([3.0, 4, 6, 10], id: \.self) { Text(verbatim: "\(Int($0).formatted())×").tag($0) }
            }
        case .agentLongSession:
            Picker(
                String(localized: "Running longer than", bundle: .strings, comment: "Alert threshold: hours an agent session has run"),
                selection: binding(rule, \.threshold)
            ) {
                ForEach([1.0, 2, 4, 8, 12], id: \.self) { Text(Formatters.duration(.seconds($0 * 3600))).tag($0) }
            }
        case .agentMemory:
            Picker(
                String(localized: "Holding at least", bundle: .strings, comment: "Alert threshold: memory an agent's processes hold"),
                selection: binding(rule, \.threshold)
            ) {
                ForEach([4.0, 8, 16, 32].map { $0 * 1_073_741_824 }, id: \.self) {
                    Text(Formatters.memory($0)).tag($0)
                }
            }
        default:
            EmptyView()
        }
    }
}
