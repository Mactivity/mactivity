import Core
import SwiftUI

extension TemperatureUnit {
    /// "Automatic (°F)" names the scale the Mac's region picks, so the choice is clear either way.
    var settingsTitle: String {
        switch self {
        case .automatic:
            let symbol = Formatters.prefersFahrenheit() ? "°F" : "°C"
            return String(localized: "Automatic (\(symbol))", bundle: .strings, comment: "Temperature unit choice; %@ is °F or °C")
        case .celsius: return String(localized: "Celsius (°C)", bundle: .strings)
        case .fahrenheit: return String(localized: "Fahrenheit (°F)", bundle: .strings)
        }
    }
}

/// Settings titles with an example of each figure, formatted as the figure itself would be.
private enum FigureExample {
    static let usedBytes = 20.0 * 1_073_741_824
    static let download = 1_000_000.0
    static let upload = 114_000.0
    static let timeLeft = Formatters.duration(.seconds(5 * 3600 + 30 * 60))

    static var rates: String {
        "\(Formatters.download(download)) · \(Formatters.upload(upload))"
    }

    /// Each figure's first choice: keep each place's usual figure.
    static var automatic: String {
        String(localized: "Automatic", bundle: .strings, comment: "Figure choice: each place shows its usual figure")
    }
}

extension MemoryFigure {
    var settingsTitle: String {
        switch self {
        case .automatic: FigureExample.automatic
        case .used: String(localized: "Used (\(Formatters.memory(FigureExample.usedBytes)))", bundle: .strings)
        case .percent: String(localized: "Percentage (\(Formatters.percent(56)))", bundle: .strings)
        case .pressure: String(localized: "Pressure (\(MetricStatus.normal.title))", bundle: .strings)
        }
    }
}

extension NetworkFigure {
    var settingsTitle: String {
        switch self {
        case .automatic: FigureExample.automatic
        case .both: String(localized: "Download and upload (\(FigureExample.rates))", bundle: .strings)
        case .download: String(localized: "Download (\(Formatters.download(FigureExample.download)))", bundle: .strings)
        case .upload: String(localized: "Upload (\(Formatters.upload(FigureExample.upload)))", bundle: .strings)
        }
    }
}

extension DiskFigure {
    var settingsTitle: String {
        switch self {
        case .automatic: FigureExample.automatic
        case .free: String(localized: "Free (\(Formatters.bytes(412e9)) free)", bundle: .strings)
        case .percentUsed: String(localized: "Percentage used (\(Formatters.percent(59)))", bundle: .strings)
        case .activity:
            String(
                localized: "Activity (\(Formatters.rate(12e6)) read · \(Formatters.rate(3e6)) write)", bundle: .strings,
                comment: "Disk figure choice with example read and write rates"
            )
        }
    }
}

extension BatteryFigure {
    var settingsTitle: String {
        switch self {
        case .automatic: FigureExample.automatic
        case .percent: String(localized: "Percentage (\(Formatters.percent(84)))", bundle: .strings)
        case .timeLeft: String(localized: "Time left (\(FigureExample.timeLeft))", bundle: .strings)
        case .percentAndTime:
            String(localized: "Percentage and time (\(Formatters.percent(84)) · \(FigureExample.timeLeft))", bundle: .strings)
        case .power: String(localized: "Power draw (\(Formatters.power(milliwatts: 11000)))", bundle: .strings)
        }
    }
}

extension TemperatureFigure {
    var settingsTitle: String {
        switch self {
        case .automatic: FigureExample.automatic
        case .cpu: String(localized: "CPU", bundle: .strings)
        case .gpu: String(localized: "GPU", bundle: .strings)
        case .hottest: String(localized: "Hottest sensor", bundle: .strings)
        }
    }
}
