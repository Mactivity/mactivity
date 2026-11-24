import Core
import Export
import Foundation
import Observation

/// "Your next Mac" (D-181): the advice, with what it was drawn from, for the sheet and the PDF.
public struct NextMacReport: Sendable {
    public let advice: UpgradeAdvice
    public let days: Int
    public let start: Date
    public let end: Date
    /// "MacBook Pro", "Apple M5 Pro", 36 GB, 1 TB: the Mac the history comes from.
    public let macName: String
    public let chip: String
    public let installedMemory: UInt64
    public let diskCapacity: UInt64
    public let cores: Int
}

/// Reads 7 or 30 days of History into a `NextMacReport`. Quarter-hours either way: fine enough
/// for a day's shape, and kept for 30 days.
@MainActor
enum NextMacLoader {
    static func load(_ services: AppServices, days: Int, end: Date = Date()) async -> NextMacReport {
        let start = end.addingTimeInterval(-Double(days) * 86400)
        let inputs = await inputs(services, days: days, end: end)
        return NextMacReport(
            advice: UpgradeAdvisor.advise(inputs), days: days, start: start, end: end,
            macName: MacModel.name(), chip: MacModel.chip(), installedMemory: inputs.installedMemory,
            diskCapacity: inputs.diskCapacity, cores: inputs.performanceCores
        )
    }

    /// The span's figures from History, for Your next Mac and Compare two Macs (1.6).
    static func inputs(_ services: AppServices, days: Int, end: Date = Date()) async -> UpgradeInputs {
        let start = end.addingTimeInterval(-Double(days) * 86400)
        let system = services.metrics.snapshot?.system
        let memory = system?.memory.totalBytes ?? ProcessInfo.processInfo.physicalMemory
        let cores = system?.cpu.perCorePercent.count ?? ProcessInfo.processInfo.activeProcessorCount
        // Before the first snapshot (just launched), the startup disk's size from the file system.
        let disk = system?.disk.bootVolume?.totalBytes
            ?? (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity)
            .flatMap { $0.map(UInt64.init) }
            ?? 0
        var inputs = UpgradeInputs(
            days: days, installedMemory: memory, performanceCores: cores, diskCapacity: disk,
            hasBattery: services.metrics.hardware.hasBattery
        )
        if let daily = services.history as? any DailyHistoryStore {
            func series(_ metric: Metric) async -> [SeriesPoint] {
                await (try? daily.series(metric: metric, app: nil, from: start, to: end)) ?? []
            }
            // The app behind a resource, not macOS itself: "Most of it: macOS" says nothing.
            func apps(_ metric: Metric) async -> [String] {
                await ((try? daily.topApps(metric: metric, from: start, to: end, limit: 5)) ?? [])
                    .filter { $0.app.kind != .system }
                    .map(\.app.name)
            }
            inputs.cpu = await series(.cpu)
            inputs.memoryUsed = await series(.memory)
            inputs.memoryPressure = await series(.memoryPressure)
            inputs.swap = await series(.swapUsed)
            inputs.gpu = await series(.gpu)
            inputs.thermal = await series(.thermalPressure)
            if inputs.hasBattery {
                inputs.onBattery = await series(.onBattery)
                inputs.batteryLevel = await series(.batteryLevel)
            }
            // Storage growth from up to 90 days whatever the span: one busy week isn't a trend.
            inputs.diskFree = await (try? daily.dailyValues(metric: .diskFree, days: max(days, 90))) ?? []
            inputs.cpuApps = await apps(.cpu)
            inputs.memoryApps = await apps(.memory)
            inputs.gpuApps = await apps(.gpu)
        }
        // The desk: displays and the lid over the span (D-237).
        if let desk = services.history as? any DeskHistoryStore {
            inputs.desk = await DeskUsage.from((try? desk.deskSamples(from: start, to: end)) ?? [])
        }
        return inputs
    }
}

/// The sheet's state: the span and the report for it.
@MainActor
@Observable
public final class NextMacModel {
    public var isPresented = false
    var days = 30
    private(set) var report: NextMacReport?

    public init() {}

    /// Already measured: render tests.
    init(report: NextMacReport) {
        self.report = report
        days = report.days
    }

    public func open() {
        isPresented = true
    }

    func load(_ services: AppServices) async {
        report = await NextMacLoader.load(services, days: days)
    }
}
