import Foundation

/// Every number on screen goes through here (spec 7.2). Views never hand-format.
///
/// Rounding rule for bytes, rates, and watts: one decimal below 10, none at 10 and above
/// ("3.3 GB", "458 MB", "12 kB/s"). See D-009.
public enum Formatters {

    // MARK: Bytes and rates (SI, 1 kB = 1000 B)

    private static let byteUnits = ["B", "kB", "MB", "GB", "TB", "PB"]

    /// French writes octets, as Finder does there: "3,3 Go" (D-221). The other languages
    /// Mactivity speaks keep the English letters.
    private static func byteUnits(_ locale: Locale) -> [String] {
        locale.language.languageCode == .french ? ["o", "ko", "Mo", "Go", "To", "Po"] : byteUnits
    }

    /// "0 B", "812 B", "4.2 kB", "458 MB", "3.3 GB".
    public static func bytes(_ value: UInt64, locale: Locale = .current) -> String {
        bytes(Double(value), locale: locale)
    }

    public static func bytes(_ value: Double, locale: Locale = .current) -> String {
        let (scaled, unit) = scaleSI(max(0, value))
        // Whole bytes never get a decimal.
        let digits = unit == 0 ? 0 : decimals(for: scaled)
        return "\(number(scaled, fractionDigits: digits, locale: locale)) \(byteUnits(locale)[unit])"
    }

    /// Memory sizes in binary units labeled the way Apple labels them ("48 GB" for 48 GiB), so a
    /// 48 GB Mac reads 48 GB, as in About This Mac and Activity Monitor. Storage and rates stay SI.
    /// See D-021.
    public static func memory(_ value: UInt64, locale: Locale = .current) -> String {
        memory(Double(value), locale: locale)
    }

    public static func memory(_ value: Double, locale: Locale = .current) -> String {
        var scaled = max(0, value)
        var unit = 0
        while unit < byteUnits.count - 1, roundTo(scaled, fractionDigits: unit == 0 ? 0 : decimals(for: scaled)) >= 1024 {
            scaled /= 1024
            unit += 1
        }
        let digits = unit == 0 ? 0 : decimals(for: scaled)
        return "\(number(scaled, fractionDigits: digits, locale: locale)) \(byteUnits(locale)[unit])"
    }

    /// "0 B/s", "12 kB/s", "1.4 MB/s".
    public static func rate(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        "\(bytes(bytesPerSecond, locale: locale))/s"
    }

    /// "↓ 1.0 MB/s": download. `compact` drops the space, for the menu bar ("↓1.0 MB/s").
    public static func download(_ bytesPerSecond: Double, compact: Bool = false, locale: Locale = .current) -> String {
        "↓" + (compact ? "" : " ") + rate(bytesPerSecond, locale: locale)
    }

    /// "↑ 114 kB/s": upload. `compact` drops the space, for the menu bar ("↑114 kB/s").
    public static func upload(_ bytesPerSecond: Double, compact: Bool = false, locale: Locale = .current) -> String {
        "↑" + (compact ? "" : " ") + rate(bytesPerSecond, locale: locale)
    }

    // MARK: Percent

    /// Takes 0...100 (not a fraction). "27%" in the US, "27 %" in Germany or France: the locale's
    /// own percent style. Rounds half up; values between 0 and 1 show "<1%".
    /// With `fractionDigits`, that many decimals and no "<1%" ("0.18%", for idle CPU costs).
    public static func percent(_ value: Double, fractionDigits: Int = 0, locale: Locale = .current) -> String {
        guard value.isFinite else {
            return "–"
        }
        if fractionDigits > 0 {
            return (value / 100).formatted(.percent.precision(.fractionLength(fractionDigits)).locale(locale))
        }
        if value > 0, value < 0.5 {
            let onePercent = percent(1, locale: locale)
            return String(
                localized: "<\(onePercent)", bundle: .strings,
                comment: "A percentage below 1%. The argument is \"1%\" in the locale's style."
            )
        }
        return (value.rounded() / 100).formatted(.percent.precision(.fractionLength(0)).grouping(.automatic).locale(locale))
    }

    // MARK: Load average

    /// "2.41  1.87  1.52": the 1, 5, and 15 minute load averages, two decimals each.
    public static func loadAverage(_ load: LoadAverage, locale: Locale = .current) -> String {
        [load.one, load.five, load.fifteen]
            .map { number($0, fractionDigits: 2, locale: locale) }
            .joined(separator: "  ")
    }

    // MARK: Power

    /// "0 mW", "850 mW", "1.2 W", "23 W".
    public static func power(milliwatts: Double, locale: Locale = .current) -> String {
        // Always watts, the unit chargers and Apple's specs use: "0.85 W", not "850 mW" (D-258).
        let watts = max(0, milliwatts) / 1000
        if watts > 0, watts < 0.005 {
            return "<\(number(0.01, fractionDigits: 2, locale: locale)) W"
        }
        let digits = watts == 0 ? 0 : roundTo(watts, fractionDigits: 2) < 1 ? 2 : decimals(for: watts)
        return "\(number(watts, fractionDigits: digits, locale: locale)) W"
    }

    // MARK: Days

    /// "2026-10-15": the day in this Mac's time zone. `.iso8601` alone formats in UTC, which east
    /// of Greenwich puts local midnight on the day before (D-219).
    public static func localDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
    }

    // MARK: Durations

    /// "1.4s", "12s": a few seconds, to a tenth under ten (D-215).
    public static func seconds(_ value: Double) -> String {
        Duration.seconds(max(0, value)).formatted(
            .units(allowed: [.minutes, .seconds], width: .narrow, maximumUnitCount: 2, fractionalPart: .show(length: value < 10 ? 1 : 0))
        )
    }

    /// "42s", "5m", "2h 46m", "3d 4h". Truncates toward zero; never shows seconds past a minute.
    public static func duration(_ duration: Duration) -> String {
        let total = max(0, duration.components.seconds)
        let days = Int(total / 86400)
        let hours = Int((total % 86400) / 3600)
        let minutes = Int((total % 3600) / 60)
        let seconds = Int(total % 60)
        if days > 0 {
            return hours > 0
                ? String(localized: "\(days)d \(hours)h", bundle: .strings, comment: "Duration abbreviated: d = days, h = hours.")
                : String(localized: "\(days)d", bundle: .strings, comment: "Duration: days, abbreviated (d = days).")
        }
        if hours > 0 {
            return minutes > 0
                ? String(localized: "\(hours)h \(minutes)m", bundle: .strings, comment: "Duration abbreviated: h = hours, m = minutes.")
                : String(localized: "\(hours)h", bundle: .strings, comment: "Duration: hours, abbreviated (h = hours).")
        }
        if minutes > 0 {
            return String(localized: "\(minutes)m", bundle: .strings, comment: "Duration: minutes, abbreviated (m = minutes).")
        }
        return String(localized: "\(seconds)s", bundle: .strings, comment: "Duration: seconds, abbreviated (s = seconds).")
    }

    // MARK: Battery

    /// Time left on battery ("5h 30m"). On the power adapter, the charge state instead ("Charging",
    /// "Full", "Not charging"): time to full would read like time left. "–" while macOS is still
    /// estimating. Plugged in and not charging is "Full" only when it nearly is: macOS also holds a
    /// battery well short of full, to protect it (D-214).
    public static func batteryTime(_ battery: BatteryStats) -> String {
        if battery.source == .ac {
            return battery.isCharging ? charging : battery.percent >= 95 ? full : notCharging
        }
        return battery.timeRemaining.map { duration($0) } ?? "–"
    }

    /// Every text `batteryTime` and `batteryPower` can show that isn't a duration or a power: the
    /// charge states and the placeholder. The menu bar measures these for its fixed widths.
    public static var batteryStateTexts: [String] {
        [charging, full, notCharging, "–"]
    }

    // Looked up once: the menu bar redraws these every tick.
    private static let charging = String(localized: "Charging", bundle: .strings, comment: "Battery state on the power adapter.")
    private static let full = String(localized: "Full", bundle: .strings, comment: "Battery state: fully charged, on the power adapter.")
    private static let notCharging = String(
        localized: "Not charging", bundle: .strings, comment: "Battery state: on the power adapter, held short of full"
    )

    /// Watts leaving the battery ("11 W"). On the power adapter the battery powers nothing, so the
    /// charge state instead ("Charging", "Full", "Not charging") rather than "0 mW". "–" without a reading.
    public static func batteryPower(_ battery: BatteryStats, locale: Locale = .current) -> String {
        guard battery.source == .battery else {
            return batteryTime(battery)
        }
        return battery.powerDrawWatts.map { power(milliwatts: $0 * 1000, locale: locale) } ?? "–"
    }

    // MARK: Paths

    /// "~/Library/Caches" for a path inside the home folder, "~" for the home folder itself, any
    /// other path unchanged. Matches whole folders only: "/Users/demolition" isn't in "/Users/demo".
    public static func displayPath(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else {
            return path
        }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: Temperature

    /// "54°" in °C or °F, no decimals. Automatic follows the Mac's Temperature setting.
    public static func temperature(celsius: Double, locale: Locale = .current, unit: TemperatureUnit = .current) -> String {
        let usesFahrenheit = switch unit {
        case .automatic: prefersFahrenheit(locale)
        case .celsius: false
        case .fahrenheit: true
        }
        let value = usesFahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(number(value.rounded(), fractionDigits: 0, locale: locale))°"
    }

    /// The Mac's Temperature setting (System Settings → General → Language & Region), which can
    /// differ from its region: a US Mac set to Celsius, a British one to Fahrenheit. Foundation
    /// applies it when formatting for weather; `measurementSystem` doesn't see it (D-221).
    public static func prefersFahrenheit(_ locale: Locale = .current) -> Bool {
        let digits = FloatingPointFormatStyle<Double>.number.grouping(.never).locale(Locale(identifier: "en_US_POSIX"))
        let text = Measurement(value: 100, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: digits).locale(locale))
        return text.contains("212") || text.contains("٢١٢")
    }

    // MARK: Helpers

    /// Scales to the largest SI unit that keeps the value at or above 1, and rounds before
    /// choosing so 999.96 kB becomes "1 MB", not "1,000 kB".
    static func scaleSI(_ value: Double) -> (value: Double, unit: Int) {
        var scaled = value
        var unit = 0
        while unit < byteUnits.count - 1 {
            let rounded = roundTo(scaled, fractionDigits: unit == 0 ? 0 : decimals(for: scaled))
            guard rounded >= 1000 else {
                break
            }
            scaled /= 1000
            unit += 1
        }
        return (scaled, unit)
    }

    static func decimals(for value: Double) -> Int {
        roundTo(value, fractionDigits: 1) < 10 ? 1 : 0
    }

    private static func roundTo(_ value: Double, fractionDigits: Int) -> Double {
        let factor = pow(10, Double(fractionDigits))
        return (value * factor).rounded() / factor
    }

    private static func number(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .grouping(.automatic)
                .locale(locale)
        )
    }
}

/// Which scale temperatures use: the Mac's region (Automatic), or one picked in Settings → General.
public enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case automatic, celsius, fahrenheit

    /// The Settings choice's key in `UserDefaults.standard`.
    public static let defaultsKey = "temperatureUnit"

    /// The choice in Settings. Read per call; UserDefaults keeps it in memory.
    public static var current: TemperatureUnit {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(TemperatureUnit.init) ?? .automatic
    }

    public var id: String {
        rawValue
    }
}

extension Formatters {
    /// An axis label: the metric's figure without decimals a gridline doesn't need.
    public static func axis(_ value: Double, _ kind: Metric, locale: Locale = .current) -> String {
        switch kind {
        case .energyImpact: number(value, fractionDigits: 0, locale: locale)
        default: metric(value, kind, locale: locale)
        }
    }

    /// Formats one figure for a metric. nil → "–".
    public static func metric(_ value: Double?, _ metric: Metric, locale: Locale = .current) -> String {
        guard let value, value.isFinite else {
            return "–"
        }
        switch metric {
        case .cpu, .gpu: return percent(value, locale: locale)
        case .memory: return memory(value, locale: locale)
        case .energy, .powerDraw: return power(milliwatts: value, locale: locale)
        case .diskRead, .diskWrite, .netIn, .netOut: return rate(value, locale: locale)
        case .energyImpact: return number(value, fractionDigits: 1, locale: locale)
        case .cpuTemperature, .gpuTemperature, .batteryTempCharging, .batteryTempInUse: return temperature(celsius: value, locale: locale)
        case .fanSpeed:
            guard value >= 1 else {
                return fanOff
            }
            let speed = number(value.rounded(), fractionDigits: 0, locale: locale)
            return String(localized: "\(speed) rpm", bundle: .strings, comment: "Fan speed; rpm = revolutions per minute.")
        case .thermalPressure: return thermalStates[min(3, max(0, Int(value.rounded())))]
        case .batteryLevel, .memoryPressure: return percent(value, locale: locale)
        case .swapUsed: return memory(value, locale: locale)
        case .diskFree: return bytes(value, locale: locale)
        case .onBattery: return percent(value * 100, locale: locale)
        }
    }

    // Looked up once: the menu bar redraws these every tick.
    private static let fanOff = String(localized: "Off", bundle: .strings, comment: "Fan speed when the fans are stopped.")
    private static let thermalStates = [
        String(localized: "Nominal", bundle: .strings, comment: "Thermal pressure level (macOS): normal."),
        String(localized: "Fair", bundle: .strings, comment: "Thermal pressure level (macOS): moderate."),
        String(localized: "Serious", bundle: .strings, comment: "Thermal pressure level (macOS): high."),
        String(localized: "Critical", bundle: .strings, comment: "Thermal pressure level (macOS): highest."),
    ]
}

extension Duration {
    /// Fractional seconds, for rates and time arithmetic ("1.5" for 1500 ms).
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Whole milliseconds, rounded toward zero.
    public var milliseconds: Int64 {
        components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }
}
