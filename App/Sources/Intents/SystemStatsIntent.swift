import AppIntents
import Core
import Foundation
import Readouts

/// CPU, memory, and battery right now, for Shortcuts, Siri, and Spotlight (E6).
struct GetSystemStatsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get System Stats"
    static let description = IntentDescription(
        "Gets your Mac's CPU load, memory used, and battery level from Mactivity.",
        categoryName: "System"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SystemStatsEntity> & ProvidesDialog {
        let snapshot = try await IntentData.snapshot()
        let entity = SystemStatsEntity(snapshot)
        return .result(value: entity, dialog: "\(entity.summary)")
    }
}

/// A reading, not a stored thing: transient, so Shortcuts can pass it along without a query.
struct SystemStatsEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "System Stats")

    @Property(title: "CPU (%)")
    var cpuPercent: Double

    @Property(title: "Memory Used (bytes)")
    var memoryUsedBytes: Int

    @Property(title: "Memory Total (bytes)")
    var memoryTotalBytes: Int

    @Property(title: "Memory Used")
    var memoryUsed: String

    @Property(title: "Memory Total")
    var memoryTotal: String

    @Property(title: "Memory Pressure")
    var memoryPressure: String

    /// Nil on Macs without a battery.
    @Property(title: "Battery (%)")
    var batteryPercent: Double?

    @Property(title: "Charging")
    var isCharging: Bool

    @Property(title: "Summary")
    var summary: String

    @Property(title: "Sampled At")
    var sampledAt: Date

    init() {
        cpuPercent = 0
        memoryUsedBytes = 0
        memoryTotalBytes = 0
        memoryUsed = ""
        memoryTotal = ""
        memoryPressure = MemoryPressure.normal.rawValue
        batteryPercent = nil
        isCharging = false
        summary = ""
        sampledAt = Date()
    }

    init(_ snapshot: Snapshot) {
        self.init()
        let system = snapshot.system
        cpuPercent = (system.cpu.totalPercent * 10).rounded() / 10
        memoryUsedBytes = Int(clamping: system.memory.usedBytes)
        memoryTotalBytes = Int(clamping: system.memory.totalBytes)
        memoryUsed = Formatters.memory(system.memory.usedBytes)
        memoryTotal = Formatters.memory(system.memory.totalBytes)
        memoryPressure = system.memory.pressure.rawValue
        batteryPercent = system.battery?.percent
        isCharging = system.battery?.isCharging ?? false
        summary = Summaries.system(system)
        sampledAt = snapshot.at
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "CPU \(Formatters.percent(cpuPercent)), \(memoryUsed) of \(memoryTotal) memory",
            subtitle: batteryPercent.map { percent -> LocalizedStringResource in "Battery \(Formatters.percent(percent))" }
                ?? "No battery"
        )
    }
}
