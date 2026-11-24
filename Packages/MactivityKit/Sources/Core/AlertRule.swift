import Foundation

public enum AlertRule: String, CaseIterable, Hashable, Sendable, Codable {
    case highCPU, growingMemory, heavyDisk, heavyNetwork
    /// About the Mac, its accessories, and apps' crash reports, not a running app's figures:
    /// checked every 10 minutes rather than on each snapshot (D-099).
    /// Raw values are what's saved, so the order here is only Settings' order. `diskLow`,
    /// `overheating` and `connectionLost` (D-149); `hotspotData`, an app using a lot of data on an
    /// iPhone's hotspot (D-136).
    case accessoryBatteryLow, diskFilling, diskLow, appCrashing, notSleeping, overheating, connectionLost, hotspotData
    /// A dev process stuck at a full core, or leaking memory (D-156).
    case runawayProcess
    /// An app far beyond its own usual day on this Mac, once a day (D-201).
    case outOfTheOrdinary
    /// An agent session running longer, or holding more memory, than set; once each (D-227).
    case agentLongSession, agentMemory
    /// Something added itself to start with the Mac (D-231).
    case newStartupItem
    /// The month's data past a share of the budget, and past all of it (D-235).
    case dataBudget
    /// Installed software with a high or critical vulnerability, or past its end of life (D-252).
    case vulnerableSoftware

    /// The rules the snapshot engine evaluates for each running app.
    public static let appRules: [AlertRule] = [.highCPU, .growingMemory, .heavyDisk, .heavyNetwork]
    public static let systemRules: [AlertRule] = [
        .accessoryBatteryLow, .diskFilling, .diskLow, .appCrashing, .notSleeping, .overheating, .connectionLost, .hotspotData,
        .runawayProcess, .outOfTheOrdinary, .agentLongSession, .agentMemory, .newStartupItem, .dataBudget,
        .vulnerableSoftware,
    ]

    public var isPerApp: Bool {
        Self.appRules.contains(self)
    }
}
