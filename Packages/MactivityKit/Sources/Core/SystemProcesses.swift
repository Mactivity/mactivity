import Foundation

/// macOS's own work, named (D-214): what a system process is for, in a few plain words, beside
/// its name in the macOS row. Only processes people see busy and wonder about.
public enum SystemProcesses {
    public static func describe(_ name: String) -> String? {
        // Variants share the description: "spotlightknowledged.updater",
        // "com.apple.WebKit.WebContent.EnhancedSecurity", "mediaanalysisd-access".
        if let base = ["spotlightknowledged", "com.apple.WebKit.WebContent", "mediaanalysisd"].first(where: {
            name.hasPrefix($0 + ".") || name.hasPrefix($0 + "-")
        }) {
            return describe(base)
        }
        return work(name) ?? place(name)
    }

    /// Background work people notice: indexing, analysis, syncing, updates.
    static func work(_ name: String) -> String? {
        switch name {
        case "mds", "mds_stores", "mdworker", "mdworker_shared", "mdbulkimport", "corespotlightd":
            String(localized: "Spotlight indexing", bundle: .strings, comment: "What a macOS process does")
        case "spotlightknowledged", "knowledgeconstructiond", "knowledge-agent":
            String(localized: "Spotlight learning what's in your files", bundle: .strings, comment: "What a macOS process does")
        case "photoanalysisd", "mediaanalysisd", "photolibraryd":
            String(localized: "Photos analyzing your library", bundle: .strings, comment: "What a macOS process does")
        case "backupd", "backupd-helper":
            String(localized: "Time Machine backing up", bundle: .strings, comment: "What a macOS process does")
        case "bird", "cloudd", "fileproviderd":
            String(localized: "iCloud syncing", bundle: .strings, comment: "What a macOS process does")
        case "softwareupdated", "SoftwareUpdateNotificationManager":
            String(localized: "Checking for or downloading macOS updates", bundle: .strings, comment: "What a macOS process does")
        case "nsurlsessiond":
            String(localized: "Downloads apps asked for in the background", bundle: .strings, comment: "What a macOS process does")
        default:
            nil
        }
    }

    /// The rest of macOS's parts: the screen, sound, radios, safety checks.
    static func place(_ name: String) -> String? {
        switch name {
        case "WindowServer":
            String(localized: "Drawing everything on screen", bundle: .strings, comment: "What a macOS process does")
        case "kernel_task":
            String(
                localized: "The system core; also holds the processor back to keep the Mac cool",
                bundle: .strings,
                comment: "What a macOS process does"
            )
        case "coreaudiod":
            String(localized: "Sound", bundle: .strings, comment: "What a macOS process does")
        case "bluetoothd":
            String(localized: "Bluetooth", bundle: .strings, comment: "What a macOS process does")
        case "airportd", "wifid", "wifianalyticsd":
            String(localized: "Wi-Fi", bundle: .strings, comment: "What a macOS process does")
        case "syspolicyd", "trustd", "XprotectService", "XProtectPluginService", "MRT":
            String(localized: "Checking apps and downloads are safe", bundle: .strings, comment: "What a macOS process does")
        case "biomed", "BiomeAgent", "suggestd", "duetexpertd", "coreduetd":
            String(localized: "Siri Suggestions learning your habits", bundle: .strings, comment: "What a macOS process does")
        case "ReportCrash", "spindump", "diagnosticd":
            String(localized: "Recording a crash or a hang", bundle: .strings, comment: "What a macOS process does")
        case "fseventsd":
            String(localized: "Keeping track of changed files", bundle: .strings, comment: "What a macOS process does")
        case "logd":
            String(localized: "Writing the system log", bundle: .strings, comment: "What a macOS process does")
        case "sharingd", "rapportd":
            String(localized: "AirDrop, Handoff and Continuity", bundle: .strings, comment: "What a macOS process does")
        case "IMDPersistenceAgent", "imagent":
            String(localized: "Messages", bundle: .strings, comment: "What a macOS process does")
        case "VTDecoderXPCService", "VTEncoderXPCService":
            String(localized: "Decoding or encoding video", bundle: .strings, comment: "What a macOS process does")
        case "com.apple.WebKit.WebContent":
            String(localized: "A web page in Safari or an app", bundle: .strings, comment: "What a macOS process does")
        case "com.apple.WebKit.GPU":
            String(localized: "Graphics for web pages", bundle: .strings, comment: "What a macOS process does")
        case "cloudphotod":
            String(localized: "iCloud Photos syncing", bundle: .strings, comment: "What a macOS process does")
        case "com.apple.WebKit.Networking":
            String(localized: "Web page downloads", bundle: .strings, comment: "What a macOS process does")
        case "powerd":
            String(localized: "Sleep and power", bundle: .strings, comment: "What a macOS process does")
        case "launchd":
            String(localized: "Starts and watches every other process", bundle: .strings, comment: "What a macOS process does")
        case "mediaremoted", "nowplaying":
            String(localized: "Now Playing and media keys", bundle: .strings, comment: "What a macOS process does")
        default:
            nil
        }
    }
}

/// Whether the charger keeps up with this Mac (D-214), from what Mactivity measures of the whole
/// Mac: the charger's rating and what the Mac draws now. Not history's power, which counts the
/// processes' own energy only, not the display or the rest of the chip. Pure.
public enum ChargerCheck {
    public enum Verdict: Equatable, Sendable {
        /// The Mac draws more than the charger gives right now: the battery covers the rest.
        case short(drawing: Double, charger: Double)
        /// Plugged in, not charging, well short of full: macOS is holding the battery there.
        case holding(percent: Double, charger: Double)
        case keepsUp(charger: Double, drawing: Double?)
    }

    /// Watts. Nil without a charger rating. `heldAt`: the battery's level when plugged in, not
    /// charging and under 95%.
    public static func verdict(charger: Double?, drawingNow: Double?, heldAt: Double? = nil) -> Verdict? {
        guard let charger, charger > 0 else {
            return nil
        }
        if let drawingNow, drawingNow > charger + 2 {
            return .short(drawing: drawingNow, charger: charger)
        }
        if let heldAt {
            return .holding(percent: heldAt, charger: charger)
        }
        return .keepsUp(charger: charger, drawing: drawingNow)
    }

    public static func text(_ verdict: Verdict) -> String {
        switch verdict {
        case let .short(drawing, charger):
            let draw = Formatters.power(milliwatts: drawing * 1000)
            let rating = Formatters.power(milliwatts: charger * 1000)
            return String(
                localized: "Drawing \(draw) from a \(rating) charger: the battery covers the rest",
                bundle: .strings,
                comment: "Charger check: the Mac draws more than the charger gives"
            )
        case let .holding(percent, charger):
            let level = Formatters.percent(percent)
            let rating = Formatters.power(milliwatts: charger * 1000)
            return String(
                localized: "On a \(rating) charger but not charging at \(level): macOS is holding the battery there, usually to protect it",
                bundle: .strings,
                comment: "Charger check: plugged in, held short of full by Optimized Battery Charging or a charge limit"
            )
        case let .keepsUp(charger, drawing):
            let rating = Formatters.power(milliwatts: charger * 1000)
            guard let drawing else {
                return String(localized: "On a \(rating) charger", bundle: .strings, comment: "Charger check: the charger's rating")
            }
            let draw = Formatters.power(milliwatts: drawing * 1000)
            return String(
                localized: "This \(rating) charger covers the \(draw) this Mac is drawing",
                bundle: .strings,
                comment: "Charger check: the charger gives more than the Mac draws now"
            )
        }
    }
}
