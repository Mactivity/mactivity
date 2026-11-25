import Foundation

/// One Mac over a span, as a file another Mac can open (1.6, compare two Macs). What it holds is
/// what the comparison shows, nothing more: the Mac, and figures over the span. It goes where the
/// person moves it; nothing is uploaded.
public struct MacProfile: Codable, Sendable, Equatable {
    public static let formatVersion = 1
    public static let fileExtension = "mactivityreport"
    /// A report is a few kilobytes; anything past this isn't one (D-251).
    public static let largestFile = 256 * 1024

    public var formatVersion = MacProfile.formatVersion
    /// The Mac's name, as in Sharing settings: "Robin's MacBook Pro".
    public var name: String
    public var model: String
    public var chip: String
    public var memory: UInt64
    public var disk: UInt64
    public var cores: Int
    public var system: String
    public var hasBattery: Bool
    public var days: Int
    public var start: Date
    public var end: Date
    public var figures: Figures

    public struct Figures: Codable, Sendable, Equatable {
        /// Whole-Mac processor, percent: the average, and the busiest tenth of quarter-hours.
        public var cpuAverage: Double
        public var cpuBusy: Double
        public var memoryAverage: Double
        public var memoryPeak: Double
        /// Memory pressure, percent.
        public var pressureAverage: Double
        public var swapAverage: Double
        public var gpuAverage: Double
        /// Share of the time macOS slowed the Mac to cool it, 0…1.
        public var hotShare: Double
        /// Share of the time on battery, 0…1; nil without a battery.
        public var onBatteryShare: Double?
        public var writtenPerDay: Double
        public var downloadedPerDay: Double
        public var diskFree: Double?
        public var cpuApps: [String]
        public var memoryApps: [String]

        public init(
            cpuAverage: Double, cpuBusy: Double, memoryAverage: Double, memoryPeak: Double, pressureAverage: Double,
            swapAverage: Double, gpuAverage: Double, hotShare: Double, onBatteryShare: Double?, writtenPerDay: Double,
            downloadedPerDay: Double, diskFree: Double?, cpuApps: [String], memoryApps: [String]
        ) {
            self.cpuAverage = cpuAverage
            self.cpuBusy = cpuBusy
            self.memoryAverage = memoryAverage
            self.memoryPeak = memoryPeak
            self.pressureAverage = pressureAverage
            self.swapAverage = swapAverage
            self.gpuAverage = gpuAverage
            self.hotShare = hotShare
            self.onBatteryShare = onBatteryShare
            self.writtenPerDay = writtenPerDay
            self.downloadedPerDay = downloadedPerDay
            self.diskFree = diskFree
            self.cpuApps = cpuApps
            self.memoryApps = memoryApps
        }

        /// From what Your next Mac reads (`UpgradeInputs`), plus the span's disk writes and
        /// downloads.
        public static func from(_ inputs: UpgradeInputs, written: Double, downloaded: Double) -> Figures {
            func average(_ points: [SeriesPoint]) -> Double {
                points.isEmpty ? 0 : points.reduce(0) { $0 + $1.average } / Double(points.count)
            }
            let cpu = inputs.cpu.map(\.average).sorted()
            let busy = cpu.isEmpty ? 0 : cpu[min(cpu.count - 1, Int(Double(cpu.count) * 0.9))]
            let hot = inputs.thermal.isEmpty ? 0 : Double(inputs.thermal.count { $0.maximum >= 2 }) / Double(inputs.thermal.count)
            let days = Double(max(1, inputs.days))
            return Figures(
                cpuAverage: average(inputs.cpu), cpuBusy: busy,
                memoryAverage: average(inputs.memoryUsed), memoryPeak: inputs.memoryUsed.map(\.maximum).max() ?? 0,
                pressureAverage: average(inputs.memoryPressure), swapAverage: average(inputs.swap), gpuAverage: average(inputs.gpu),
                hotShare: hot, onBatteryShare: inputs.hasBattery ? average(inputs.onBattery) : nil,
                writtenPerDay: written / days, downloadedPerDay: downloaded / days, diskFree: inputs.diskFree.last?.average,
                cpuApps: Array(inputs.cpuApps.prefix(3)), memoryApps: Array(inputs.memoryApps.prefix(3))
            )
        }
    }

    public init(
        name: String, model: String, chip: String, memory: UInt64, disk: UInt64, cores: Int, system: String,
        hasBattery: Bool, days: Int, start: Date, end: Date, figures: Figures
    ) {
        self.name = name
        self.model = model
        self.chip = chip
        self.memory = memory
        self.disk = disk
        self.cores = cores
        self.system = system
        self.hasBattery = hasBattery
        self.days = days
        self.start = start
        self.end = end
        self.figures = figures
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Nil for anything that isn't a report this version can read. A report comes from another
    /// Mac, or from anyone, so it's checked before anything uses it (D-251): its span is what
    /// this Mac reads from History, and its figures are formatted and compared.
    public static func decode(_ data: Data) -> MacProfile? {
        guard data.count <= largestFile else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let profile = try? decoder.decode(MacProfile.self, from: data), profile.formatVersion <= formatVersion,
              profile.isSensible
        else {
            return nil
        }
        return profile.trimmed
    }

    /// Pure: a span History can have (a year at most), and figures a Mac can have.
    var isSensible: Bool {
        let f = figures
        let amounts = [
            f.cpuAverage,
            f.cpuBusy,
            f.memoryAverage,
            f.memoryPeak,
            f.pressureAverage,
            f.swapAverage,
            f.gpuAverage,
            f.writtenPerDay,
            f.downloadedPerDay,
            f.diskFree ?? 0,
        ]
        let shares = [f.hotShare, f.onBatteryShare ?? 0]
        return (1 ... 366).contains(days) && cores >= 0 && cores <= 1024
            && amounts.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1e18 }
            && shares.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }

    /// Names cut to a length a sheet can show, and three apps at most.
    var trimmed: MacProfile {
        func cut(_ text: String) -> String {
            String(text.prefix(80))
        }
        var profile = self
        profile.name = cut(name)
        profile.model = cut(model)
        profile.chip = cut(chip)
        profile.system = cut(system)
        profile.figures.cpuApps = figures.cpuApps.prefix(3).map(cut)
        profile.figures.memoryApps = figures.memoryApps.prefix(3).map(cut)
        return profile
    }
}
