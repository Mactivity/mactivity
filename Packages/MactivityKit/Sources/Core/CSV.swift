import Foundation

/// CSV for the history export and recordings (RFC 4180).
public enum CSV {
    /// Empty for no figure; whole numbers without a fraction; the rest to three decimals.
    public static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return ""
        }
        return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(format: "%.3f", value)
    }

    /// Quoted when it holds a comma, a quote or a line break.
    public static func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else {
            return text
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension Metric {
    /// The CSV column's name and unit. A switch, so a new metric can't miss its column.
    public var csvName: String {
        switch self {
        case .cpu: "CPU (%)"
        case .memory: "Memory (bytes)"
        case .energy: "Power (mW)"
        case .diskRead: "Disk read (bytes/s)"
        case .diskWrite: "Disk write (bytes/s)"
        case .netIn: "Network in (bytes/s)"
        case .netOut: "Network out (bytes/s)"
        case .gpu: "GPU (%)"
        case .energyImpact: "Energy Impact"
        case .cpuTemperature: "CPU temperature (°C)"
        case .gpuTemperature: "GPU temperature (°C)"
        case .fanSpeed: "Fan (rpm)"
        case .thermalPressure: "Thermal pressure (0 nominal to 3 critical)"
        case .batteryLevel: "Battery level (%)"
        case .memoryPressure: "Memory pressure (%)"
        case .swapUsed: "Swap used (bytes)"
        case .diskFree: "Free space on the startup disk (bytes)"
        case .onBattery: "On battery (share of the hour, 0 to 1)"
        case .powerDraw: "Power draw of the whole Mac (mW)"
        case .batteryTempCharging: "Battery temperature while charging (°C)"
        case .batteryTempInUse: "Battery temperature while not charging (°C)"
        }
    }
}
