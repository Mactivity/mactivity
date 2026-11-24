@testable import Core
import Foundation
import Testing

@Suite("Formatters")
struct FormattersTests {
    let locale = Locale(identifier: "en_US")

    @Test("Bytes: one decimal below 10, none from 10 up, SI units", arguments: [
        (UInt64(0), "0 B"),
        (812, "812 B"),
        (999, "999 B"),
        (1000, "1.0 kB"),
        (4200, "4.2 kB"),
        (9960, "10 kB"),
        (458_000_000, "458 MB"),
        (999_600, "1.0 MB"),
        (3_300_000_000, "3.3 GB"),
        (36_000_000_000, "36 GB"),
    ])
    func bytes(value: UInt64, expected: String) {
        #expect(Formatters.bytes(value, locale: locale) == expected)
    }

    @Test("Download and upload: an arrow, with a space except in the menu bar")
    func directions() {
        #expect(Formatters.download(1_000_000, locale: locale) == "↓ 1.0 MB/s")
        #expect(Formatters.upload(114_000, locale: locale) == "↑ 114 kB/s")
        #expect(Formatters.download(1_000_000, compact: true, locale: locale) == "↓1.0 MB/s")
        #expect(Formatters.upload(0, compact: true, locale: locale) == "↑0 B/s")
    }

    @Test("Battery time left on battery; the charge state on the adapter; a dash while estimating")
    func batteryTime() {
        func battery(
            _ source: BatteryStats.PowerSource,
            charging: Bool = false,
            minutes: Int64? = nil,
            watts: Double? = nil
        ) -> BatteryStats {
            BatteryStats(
                percent: 84, isCharging: charging, source: source, timeRemaining: minutes.map { .seconds($0 * 60) },
                cycleCount: nil, maxCapacityPercent: nil, powerDrawWatts: watts
            )
        }
        #expect(Formatters.batteryTime(battery(.battery, minutes: 330)) == "5h 30m")
        #expect(Formatters.batteryTime(battery(.battery)) == "–")
        // Time to full on the adapter isn't time left.
        #expect(Formatters.batteryTime(battery(.ac, charging: true, minutes: 40)) == "Charging")
        // Plugged in and held at 84% isn't full (D-214).
        #expect(Formatters.batteryTime(battery(.ac)) == "Not charging")
        let full = BatteryStats(
            percent: 100, isCharging: false, source: .ac, timeRemaining: nil, cycleCount: nil, maxCapacityPercent: nil, powerDrawWatts: nil
        )
        #expect(Formatters.batteryTime(full) == "Full")
        #expect(Formatters.batteryPower(battery(.battery, watts: 11.4), locale: locale) == "11 W")
        #expect(Formatters.batteryPower(battery(.battery), locale: locale) == "–")
        #expect(Formatters.batteryPower(battery(.ac, charging: true, watts: 0), locale: locale) == "Charging")
    }

    @Test("Rates")
    func rates() {
        #expect(Formatters.rate(0, locale: locale) == "0 B/s")
        #expect(Formatters.rate(12000, locale: locale) == "12 kB/s")
        #expect(Formatters.rate(1_400_000, locale: locale) == "1.4 MB/s")
    }

    @Test("Percent takes 0...100 and shows no decimals", arguments: [
        (0.0, "0%"), (0.3, "<1%"), (0.5, "1%"), (27.4, "27%"), (99.6, "100%"), (100, "100%"),
    ])
    func percent(value: Double, expected: String) {
        #expect(Formatters.percent(value, locale: locale) == expected)
    }

    @Test("Percent of NaN is a dash")
    func percentNaN() {
        #expect(Formatters.percent(.nan, locale: locale) == "–")
    }

    @Test("Power: always watts, two decimals under 1 W (D-258)", arguments: [
        (0.0, "0 W"), (3, "<0.01 W"), (120, "0.12 W"), (850, "0.85 W"), (999.4, "1.0 W"), (1200, "1.2 W"), (23000, "23 W"),
    ])
    func power(milliwatts: Double, expected: String) {
        #expect(Formatters.power(milliwatts: milliwatts, locale: locale) == expected)
    }

    @Test("Durations", arguments: [
        (0, "0s"), (42, "42s"), (300, "5m"), (9960, "2h 46m"), (7200, "2h"), (273_600, "3d 4h"), (86400, "1d"),
    ])
    func duration(seconds: Int, expected: String) {
        #expect(Formatters.duration(.seconds(seconds)) == expected)
    }

    @Test("Durations convert to fractional seconds and whole milliseconds")
    func durationParts() {
        #expect(Duration.milliseconds(1500).seconds == 1.5)
        #expect(Duration.zero.seconds == 0)
        #expect(Duration.microseconds(2_500_900).milliseconds == 2500)
    }

    @Test("Home abbreviation only matches whole folders")
    func displayPath() {
        #expect(Formatters.displayPath("/Users/demo/x", home: "/Users/demo") == "~/x")
        #expect(Formatters.displayPath("/Users/demo", home: "/Users/demo") == "~")
        #expect(Formatters.displayPath("/Users/demolition/x", home: "/Users/demo") == "/Users/demolition/x")
        #expect(Formatters.displayPath("/Users/demo/x", home: "") == "/Users/demo/x")
    }

    @Test("Temperature follows the locale's unit")
    func temperature() {
        #expect(Formatters.temperature(celsius: 54.4, locale: Locale(identifier: "en_GB"), unit: .automatic) == "54°")
        #expect(Formatters.temperature(celsius: 100, locale: Locale(identifier: "en_US"), unit: .automatic) == "212°")
        // The Mac's Temperature setting over its region (D-221).
        #expect(Formatters.temperature(celsius: 100, locale: Locale(identifier: "en-US-u-mu-celsius"), unit: .automatic) == "100°")
        #expect(Formatters.temperature(celsius: 100, locale: Locale(identifier: "en-GB-u-mu-fahrenhe"), unit: .automatic) == "212°")
        // Settings → General → Temperature overrides the region either way.
        #expect(Formatters.temperature(celsius: 100, locale: Locale(identifier: "en_US"), unit: .celsius) == "100°")
        #expect(Formatters.temperature(celsius: 100, locale: Locale(identifier: "de_DE"), unit: .fahrenheit) == "212°")
    }

    @Test("Uses the locale's decimal separator")
    func decimalSeparator() {
        #expect(Formatters.bytes(UInt64(3_300_000_000), locale: Locale(identifier: "de_DE")) == "3,3 GB")
    }
}

@Suite("Formatters.metric")
struct MetricFormatterTests {
    @Test("Every metric picks its formatter", arguments: [
        (27.4, Metric.cpu, "27%"), (3_543_348_019, .memory, "3.3 GB"), (850, .energy, "0.85 W"),
        (12000, .netIn, "12 kB/s"), (1_400_000, .netOut, "1.4 MB/s"), (62_000_000, .diskWrite, "62 MB/s"),
        (500, .diskRead, "500 B/s"), (40, .gpu, "40%"),
    ] as [(Double, Metric, String)])
    func formats(value: Double, metric: Metric, expected: String) {
        #expect(Formatters.metric(value, metric, locale: Locale(identifier: "en_US")) == expected)
    }

    @Test("nil is a dash")
    func missing() {
        #expect(Formatters.metric(nil, .gpu) == "–")
    }
}

@Suite("Formatters.memory")
struct MemoryFormatterTests {
    @Test("Binary units, Apple's labels", arguments: [
        (UInt64(51_539_607_552), "48 GB"), (UInt64(3_543_348_019), "3.3 GB"), (UInt64(480_247_808), "458 MB"),
        (UInt64(1023), "1,023 B"), (UInt64(1024), "1.0 kB"),
    ])
    func memory(value: UInt64, expected: String) {
        #expect(Formatters.memory(value, locale: Locale(identifier: "en_US")) == expected)
    }
}

@Suite("Energy Impact")
struct EnergyImpactTests {
    let coefficients = EnergyCoefficients.builtIn

    @Test("One core busy for a second, no wakeups, is 100")
    func cpuOnly() {
        #expect(coefficients.impact(cpuSeconds: 1, wakeups: 0, bytesRead: 0, bytesWritten: 0, gpuSeconds: 0, seconds: 1) == 100)
    }

    @Test("Wakeups cost 0.2 ms of CPU each: 500 wakeups a second add 10")
    func wakeups() {
        let impact = coefficients.impact(cpuSeconds: 0, wakeups: 500, bytesRead: 0, bytesWritten: 0, gpuSeconds: 0, seconds: 1)
        #expect(abs(impact - 10) < 1e-9)
    }

    @Test("Zero seconds is zero, not infinity")
    func zeroInterval() {
        #expect(coefficients.impact(cpuSeconds: 1, wakeups: 1, bytesRead: 1, bytesWritten: 1, gpuSeconds: 1, seconds: 0) == 0)
    }

    @Test("Parses a pmenergy plist")
    func parse() throws {
        let plist: [String: Any] = ["energy_constants": [
            "kcpu_time": 1,
            "kcpu_wakeups": 0.0002,
            "kgpu_time": 4.4,
            "kdiskio_bytesread": 1.4e-8,
            "kdiskio_byteswritten": 3.8e-9,
        ]]
        let parsed = try #require(EnergyCoefficients(plist: plist))
        #expect(parsed.gpuTime == 4.4)
        #expect(EnergyCoefficients(plist: [:]) == nil)
    }

    @Test("New metrics format", arguments: [
        (12.34, Metric.energyImpact, "12.3"), (0, .fanSpeed, "Off"), (2317, .fanSpeed, "2,317 rpm"), (2, .thermalPressure, "Serious"),
    ] as [(Double, Metric, String)])
    func formatting(value: Double, metric: Metric, expected: String) {
        #expect(Formatters.metric(value, metric, locale: Locale(identifier: "en_US")) == expected)
    }

    @Test("Axis labels drop decimals a gridline doesn't need")
    func axis() {
        let us = Locale(identifier: "en_US")
        #expect(Formatters.axis(20000, .energyImpact, locale: us) == "20,000")
        #expect(Formatters.metric(20000, .energyImpact, locale: us) == "20,000.0")
    }

    @Test("Percent follows the locale's style")
    func percentStyle() {
        #expect(Formatters.percent(27, locale: Locale(identifier: "en_US")) == "27%")
        #expect(Formatters.percent(27, locale: Locale(identifier: "de_DE")) == "27\u{a0}%")
        #expect(Formatters.percent(0.2, locale: Locale(identifier: "en_US")) == "<1%")
    }
}

/// Days in this Mac's time zone (D-219).
struct LocalDayTests {
    @Test("Local midnight in Berlin is that day, not the day before in UTC")
    func berlin() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        let midnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15)))
        #expect(Formatters.localDay(midnight, timeZone: berlin) == "2026-10-15")
    }

    @Test("French sizes are in octets, as Finder writes them (D-221)")
    func frenchBytes() {
        let french = Locale(identifier: "fr_FR")
        #expect(Formatters.bytes(UInt64(3_300_000_000), locale: french) == "3,3 Go")
        #expect(Formatters.memory(UInt64(48) << 30, locale: french) == "48 Go")
        #expect(Formatters.bytes(UInt64(3_300_000_000), locale: Locale(identifier: "de_DE")) == "3,3 GB")
    }
}
