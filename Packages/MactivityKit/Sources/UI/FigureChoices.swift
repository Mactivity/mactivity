import Core
import Foundation
import SwiftUI

// What each metric's figure shows (Settings → General → Figures). One choice per metric, used in
// the menu bar item, the menu bar window's Overview rows, and the headline cards. Automatic keeps
// each place's usual figure, so nothing changes until someone picks.

public enum MemoryFigure: String, CaseIterable, Identifiable, Sendable {
    /// Percent in the menu bar item; GB used on cards and rows.
    case automatic
    /// "20 GB"
    case used
    /// "56%"
    case percent
    /// "Normal", "Elevated", "Critical": the memory status.
    case pressure

    public var id: String {
        rawValue
    }
}

public enum NetworkFigure: String, CaseIterable, Identifiable, Sendable {
    /// Both directions added up in the menu bar item; download with upload beside it elsewhere.
    case automatic
    /// Download and upload.
    case both
    case download
    case upload

    public var id: String {
        rawValue
    }
}

public enum DiskFigure: String, CaseIterable, Identifiable, Sendable {
    /// Free space.
    case automatic
    /// "412 GB free"
    case free
    /// "59%" of the startup disk in use.
    case percentUsed
    /// Read and write rates.
    case activity

    public var id: String {
        rawValue
    }
}

public enum BatteryFigure: String, CaseIterable, Identifiable, Sendable {
    /// Percent, with time left beside it where there's room.
    case automatic
    case percent
    /// "5h 30m", or "Charging" / "Full" / "Not charging" on the power adapter.
    case timeLeft
    /// "84% · 5h 30m"
    case percentAndTime
    /// "11 W" leaving the battery.
    case power

    public var id: String {
        rawValue
    }
}

public enum TemperatureFigure: String, CaseIterable, Identifiable, Sendable {
    /// The CPU sensor.
    case automatic
    case cpu
    case gpu
    /// The hottest sensor the Mac reports.
    case hottest

    public var id: String {
        rawValue
    }

    /// The reading this choice shows, nil when the Mac has no such sensor.
    public func celsius(_ sensors: SensorStats?) -> Double? {
        guard let sensors else {
            return nil
        }
        return switch self {
        case .automatic, .cpu: sensors.temperature(id: "cpu")
        case .gpu: sensors.temperature(id: "gpu")
        case .hottest: sensors.temperatures.map(\.celsius).filter(\.isFinite).max()
        }
    }
}

/// Every metric's figure choice at once. CPU and GPU always show a percentage.
public struct FigureChoices: Hashable, Sendable {
    public var memory: MemoryFigure
    public var network: NetworkFigure
    public var disk: DiskFigure
    public var battery: BatteryFigure
    public var temperature: TemperatureFigure

    public static let automatic = FigureChoices()

    public init(
        memory: MemoryFigure = .automatic,
        network: NetworkFigure = .automatic,
        disk: DiskFigure = .automatic,
        battery: BatteryFigure = .automatic,
        temperature: TemperatureFigure = .automatic
    ) {
        self.memory = memory
        self.network = network
        self.disk = disk
        self.battery = battery
        self.temperature = temperature
    }
}

/// The stored choices, for views: `@StoredFigureChoices private var choices`.
@MainActor
@propertyWrapper
public struct StoredFigureChoices: DynamicProperty {
    @AppStorage(PreferenceKey.memoryFigure) private var memory: MemoryFigure = .automatic
    @AppStorage(PreferenceKey.networkFigure) private var network: NetworkFigure = .automatic
    @AppStorage(PreferenceKey.diskFigure) private var disk: DiskFigure = .automatic
    @AppStorage(PreferenceKey.batteryFigure) private var battery: BatteryFigure = .automatic
    @AppStorage(PreferenceKey.temperatureFigure) private var temperature: TemperatureFigure = .automatic

    public init() {}

    public var wrappedValue: FigureChoices {
        FigureChoices(memory: memory, network: network, disk: disk, battery: battery, temperature: temperature)
    }
}

/// The rows of the menu bar window's Overview, in their fixed order (D-082). Each can be hidden
/// in Settings → Menu Bar.
public enum OverviewRow: String, CaseIterable, Identifiable, Sendable {
    case uptime, cpu, gpu, memory, disk, network, battery, temperature

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .uptime: Self.uptimeTitle
        case .temperature: Self.temperatureTitle
        default: tab?.title ?? rawValue
        }
    }

    /// Looked up once: the menu bar window redraws its rows every second.
    private static let uptimeTitle = String(localized: "Uptime", bundle: .strings)
    private static let temperatureTitle = String(localized: "Temperature", bundle: .strings)

    /// The metric tab the row reads, nil for uptime and temperature.
    public var tab: MetricTab? {
        MetricTab(rawValue: rawValue)
    }

    /// "gpu,disk" ↔ [.gpu, .disk] for `@AppStorage`: the rows turned off. Unknown names are dropped.
    public static func decodeHidden(_ raw: String) -> Set<OverviewRow> {
        Set(raw.split(separator: ",").compactMap { OverviewRow(rawValue: String($0)) })
    }

    /// In row order, so the stored string doesn't depend on the order rows were turned off.
    public static func encodeHidden(_ rows: Set<OverviewRow>) -> String {
        allCases.filter(rows.contains).map(\.rawValue).joined(separator: ",")
    }
}
