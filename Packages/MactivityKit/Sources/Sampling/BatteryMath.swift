import Core
import Foundation

/// Pure battery conversion (spec 6.10), kept apart from IOKit so it runs on fixture dictionaries.
///
/// Keys are spelled out rather than taken from `IOPSKeys.h` so the fixtures read the same as the
/// code; the values are the ones `IOPSGetPowerSourceDescription` returns.
public enum BatteryMath {
    enum PowerSourceKey {
        static let type = "Type"
        static let isPresent = "Is Present"
        static let currentCapacity = "Current Capacity"
        static let maxCapacity = "Max Capacity"
        static let isCharging = "Is Charging"
        static let state = "Power Source State"
        static let timeToEmpty = "Time to Empty"
        static let timeToFull = "Time to Full Charge"
        static let internalBattery = "InternalBattery"
        static let acPower = "AC Power"
    }

    /// `AppleSmartBattery` IORegistry keys the sampler reads. Health: changes over days, so the
    /// sampler reads these every few minutes.
    public static let smartBatteryHealthKeys = [
        "CycleCount", "AppleRawMaxCapacity", "NominalChargeCapacity", "DesignCapacity", "BatteryData",
    ]
    /// Power draw, the battery's own time estimates, the whole Mac's load and the adapter: read on
    /// every tick. The two dictionaries are small (about 25 and 15 numbers).
    public static let smartBatteryPowerKeys = [
        "Amperage", "Voltage", "AvgTimeToEmpty", "AvgTimeToFull", "PowerTelemetryData", "AdapterDetails", "Temperature",
    ]

    /// Whether an IOPS power source description is the Mac's own battery (not a UPS or an
    /// accessory), and present.
    public static func isInternalBattery(_ powerSource: [String: Any]) -> Bool {
        (powerSource[PowerSourceKey.type] as? String) == PowerSourceKey.internalBattery
            && PropertyValue.bool(powerSource[PowerSourceKey.isPresent]) != false
    }

    /// `BatteryStats` from an IOPS power source description plus, when readable, the
    /// `AppleSmartBattery` properties. Nil unless `powerSource` is a present internal battery.
    public static func stats(powerSource: [String: Any], smartBattery: [String: Any]?) -> BatteryStats? {
        guard isInternalBattery(powerSource),
              let current = PropertyValue.double(powerSource[PowerSourceKey.currentCapacity]),
              let max = PropertyValue.double(powerSource[PowerSourceKey.maxCapacity]), max > 0
        else {
            return nil
        }
        let source: BatteryStats.PowerSource =
            (powerSource[PowerSourceKey.state] as? String) == PowerSourceKey.acPower ? .ac : .battery
        let minutesKey = source == .ac ? PowerSourceKey.timeToFull : PowerSourceKey.timeToEmpty
        return BatteryStats(
            percent: Swift.min(Swift.max(current / max * 100, 0), 100),
            isCharging: PropertyValue.bool(powerSource[PowerSourceKey.isCharging]) ?? false,
            source: source,
            timeRemaining: timeRemaining(
                minutes: PropertyValue.int64(powerSource[minutesKey]),
                smartBatteryMinutes: smartBattery.flatMap { PropertyValue.int64($0[source == .ac ? "AvgTimeToFull" : "AvgTimeToEmpty"]) }
            ),
            cycleCount: smartBattery.flatMap { PropertyValue.int64($0["CycleCount"]) }.map { Int($0) },
            maxCapacityPercent: smartBattery.flatMap(maxCapacityPercent),
            powerDrawWatts: smartBattery.flatMap { powerDrawWatts($0, source: source) },
            systemLoadWatts: smartBattery.flatMap(systemLoadWatts),
            adapterWatts: source == .ac ? smartBattery.flatMap(adapterWatts) : nil,
            temperatureCelsius: smartBattery.flatMap(temperatureCelsius),
            adapterInputWatts: source == .ac ? smartBattery.flatMap(adapterInputWatts) : nil
        )
    }

    /// The battery's own average estimate when it has one, else IOPS's.
    ///
    /// IOPS caps its estimate at 20 hours (1,200 minutes), so on a light load it read "20h" at 36%
    /// and at 100% alike; `AvgTimeToEmpty` / `AvgTimeToFull` from `AppleSmartBattery` aren't capped.
    /// The smart battery reports 65,535 for "no estimate"; IOPS reports −1 while it's still
    /// estimating and 0 when there's nothing to estimate (fully charged on AC). All are "unknown".
    public static func timeRemaining(minutes: Int64?, smartBatteryMinutes: Int64? = nil) -> Duration? {
        if let average = smartBatteryMinutes, average > 0, average < 65535 {
            return .seconds(average * 60)
        }
        guard let minutes, minutes > 0 else {
            return nil
        }
        return .seconds(minutes * 60)
    }

    /// Health: raw full-charge capacity ÷ design capacity, both in mAh.
    ///
    /// Prefers the top-level `AppleRawMaxCapacity` and `DesignCapacity`. On the M5 Pro under
    /// macOS 27 neither is published at the top level; the `BatteryData` dictionary carries
    /// `NominalChargeCapacity` (the raw full-charge capacity) and `DesignCapacity` instead.
    /// A new battery can read above design; capped at 100, as System Settings shows it.
    public static func maxCapacityPercent(_ smartBattery: [String: Any]) -> Double? {
        let data = smartBattery["BatteryData"] as? [String: Any]
        let raw = PropertyValue.double(smartBattery["AppleRawMaxCapacity"])
            ?? PropertyValue.double(smartBattery["NominalChargeCapacity"])
            ?? PropertyValue.double(data?["NominalChargeCapacity"])
        let design = PropertyValue.double(smartBattery["DesignCapacity"])
            ?? PropertyValue.double(data?["DesignCapacity"])
        guard let raw, let design, design > 0, raw >= 0 else {
            return nil
        }
        return Swift.min(raw / design * 100, 100)
    }

    /// `PowerTelemetryData.SystemLoad` (mW) as watts: what the whole Mac draws, whichever source
    /// powers it (D-109). On the adapter the battery's own draw is 0, which read as "Power draw
    /// 0 mW" on a Mac drawing 9 W. 0 or missing is unknown: the telemetry is still starting.
    public static func systemLoadWatts(_ smartBattery: [String: Any]) -> Double? {
        guard let telemetry = smartBattery["PowerTelemetryData"] as? [String: Any],
              let load = PropertyValue.double(telemetry["SystemLoad"]), load > 0
        else {
            return nil
        }
        return load / 1000
    }

    /// `AdapterDetails.Watts`: the adapter's rating, e.g. 100 for a 100 W charger.
    public static func adapterWatts(_ smartBattery: [String: Any]) -> Double? {
        guard let adapter = smartBattery["AdapterDetails"] as? [String: Any],
              let watts = PropertyValue.double(adapter["Watts"]), watts > 0
        else {
            return nil
        }
        return watts
    }

    /// `PowerTelemetryData.SystemPowerIn` (mW) as watts: what the adapter really delivers, the Mac's
    /// load plus what goes into the battery (D-274). 0 on battery or while the telemetry starts.
    public static func adapterInputWatts(_ smartBattery: [String: Any]) -> Double? {
        guard let telemetry = smartBattery["PowerTelemetryData"] as? [String: Any],
              let power = PropertyValue.double(telemetry["SystemPowerIn"]), power > 0
        else {
            return nil
        }
        return power / 1000
    }

    /// `Temperature` in hundredths of a degree Celsius (D-275): 2579 is 25.79 °C. Top level where a
    /// Mac publishes it there; on the M5 Pro under macOS 27 it's only in the `BatteryData` of
    /// `AppleSmartBatteryPack`, the entry's child, which the sampler reads under this same key. It's
    /// an undocumented key, so anything outside what a battery can be is taken as unreadable
    /// rather than shown.
    public static func temperatureCelsius(_ smartBattery: [String: Any]) -> Double? {
        let data = smartBattery["BatteryData"] as? [String: Any]
        guard let raw = PropertyValue.double(smartBattery["Temperature"]) ?? PropertyValue.double(data?["Temperature"]) else {
            return nil
        }
        let celsius = raw / 100
        return (-30.0 ... 90.0).contains(celsius) && raw != 0 ? celsius : nil
    }

    /// |Amperage (mA, signed) × Voltage (mV)| ÷ 10⁶ = watts leaving the battery. 0 on AC while the
    /// battery isn't discharging (charging or full), since then the battery powers nothing.
    public static func powerDrawWatts(_ smartBattery: [String: Any], source: BatteryStats.PowerSource) -> Double? {
        guard let amperage = PropertyValue.int64(smartBattery["Amperage"]),
              let voltage = PropertyValue.int64(smartBattery["Voltage"])
        else {
            return nil
        }
        if source == .ac, amperage >= 0 {
            return 0
        }
        return abs(Double(amperage) * Double(voltage)) / 1e6
    }
}
