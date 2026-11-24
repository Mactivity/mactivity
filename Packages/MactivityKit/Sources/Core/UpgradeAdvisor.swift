import Foundation

/// Reads `UpgradeInputs` into `UpgradeAdvice` (D-181). Pure: every threshold is here, with the
/// reason for it, and tested with fixtures.
public enum UpgradeAdvisor {
    /// A bucket at or over this average is "near full" for the processor or graphics.
    static let busyCPU = 75.0
    static let busyGPU = 70.0
    /// Memory pressure at or over this is macOS compressing and swapping hard.
    static let pressured = 60.0
    /// Hours near full a week before a Pro chip earns its cores, and before a Max does.
    static let proHoursPerWeek = 2.0
    static let maxHoursPerWeek = 10.0
    /// Memory sizes Apple sells, in GB, and storage sizes in TB (0.25 and 0.5 for 256 and 512 GB).
    static let memorySizes: [UInt64] = [8, 16, 24, 32, 48, 64, 96, 128]
    static let storageSizes: [Double] = [0.256, 0.512, 1, 2, 4, 8]
    /// The most memory and storage a MacBook Air takes.
    static let airMemoryLimit: UInt64 = 32
    static let airStorageLimit = 2.0
    /// The most memory a Mac mini takes; past it, a Mac Studio.
    static let miniMemoryLimit: UInt64 = 64
    /// Storage is sized for three years of growth, with a fifth left free.
    static let storageYears = 3.0
    static let gib: Double = 1_073_741_824
    /// Days of free space before storage growth counts.
    static let minimumGrowthDays = 14

    public static func advise(_ inputs: UpgradeInputs, calendar: Calendar = .current) -> UpgradeAdvice {
        var advice = UpgradeAdvice()
        advice.hoursRecorded = Double(inputs.cpu.count) * inputs.bucketSeconds / 3600
        guard advice.hoursRecorded > 0 else {
            return advice
        }
        let perWeek = 168 / advice.hoursRecorded
        let processor = processor(inputs, perWeek: perWeek)
        advice.chip = processor.chip
        advice.needs.append(processor.need)
        if let memory = memory(inputs, perWeek: perWeek) {
            advice.memoryVerdict = memory.gigabytes
            advice.needs.append(memory.need)
        }
        if let graphics = graphics(inputs, perWeek: perWeek) {
            advice.chip = max(advice.chip, graphics.chip)
            advice.needs.append(graphics.need)
        }
        if let storage = storage(inputs) {
            advice.storageVerdict = storage.bytes
            advice.needs.append(storage.need)
        }
        if let battery = battery(inputs) {
            advice.needs.append(battery)
        }
        let throttledPerWeek = minutes(inputs.thermal, inputs.bucketSeconds) { $0.average >= 1.5 } * perWeek
        (advice.form, advice.formReason) = inputs.hasBattery
            ? form(advice, throttledMinutesPerWeek: throttledPerWeek)
            : desktop(advice)
        desk(&advice, inputs)
        advice.day = day(inputs, calendar: calendar)
        advice.busiestHours = busiest(advice.day)
        return advice
    }

    // MARK: Helpers

    /// The value below which `fraction` of the points' averages fall.
    static func percentile(_ points: [SeriesPoint], _ fraction: Double) -> Double {
        let sorted = points.map(\.average).sorted()
        guard !sorted.isEmpty else {
            return 0
        }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    /// Minutes of the buckets that match.
    static func minutes(_ points: [SeriesPoint], _ bucket: TimeInterval, where match: (SeriesPoint) -> Bool) -> Double {
        Double(points.count(where: match)) * bucket / 60
    }

    /// The smallest size at or above `needed`; the largest if none is.
    static func size<T: Comparable>(_ needed: T, in sizes: [T]) -> T {
        sizes.first { $0 >= needed } ?? sizes.last ?? needed
    }

    /// The average day: each hour's mean across the range.
    static func day(_ inputs: UpgradeInputs, calendar: Calendar) -> [UpgradeAdvice.Hour] {
        func byHour(_ points: [SeriesPoint], scale: Double = 1) -> [Int: Double] {
            var sums: [Int: (Double, Int)] = [:]
            for point in points {
                let hour = calendar.component(.hour, from: point.at)
                let entry = sums[hour] ?? (0, 0)
                sums[hour] = (entry.0 + point.average * scale, entry.1 + 1)
            }
            return sums.mapValues { $0.0 / Double($0.1) }
        }
        let cpu = byHour(inputs.cpu)
        let memory = byHour(inputs.memoryUsed, scale: inputs.installedMemory > 0 ? 100 / Double(inputs.installedMemory) : 0)
        let gpu = byHour(inputs.gpu)
        // Only hours with history: a Mac asleep at night has none, and that isn't 0% busy.
        return (0 ..< 24).compactMap { hour in
            cpu[hour].map { UpgradeAdvice.Hour(
                hour: hour,
                cpu: $0,
                memory: memory[hour] ?? 0,
                gpu: inputs.gpu.isEmpty ? nil : gpu[hour] ?? 0
            ) }
        }
    }

    /// The three hours in a row with the most processor use, when the day has any to speak of.
    static func busiest(_ day: [UpgradeAdvice.Hour]) -> ClosedRange<Int>? {
        let cpu = Dictionary(day.map { ($0.hour, $0.cpu) }, uniquingKeysWith: max)
        let windows = (0 ..< 22).compactMap { start -> (Int, Double)? in
            let hours = (start ... start + 2).compactMap { cpu[$0] }
            return hours.count == 3 ? (start, hours.reduce(0, +)) : nil
        }
        guard let best = windows.max(by: { $0.1 < $1.1 }), best.1 / 3 >= 10 else {
            return nil
        }
        return best.0 ... best.0 + 2
    }

    /// A MacBook Air until something rules it out: it has no fan, so long heavy loads slow it
    /// down, and it takes the base chip, up to 32 GB and 2 TB.
    static func form(_ advice: UpgradeAdvice, throttledMinutesPerWeek: Double) -> (UpgradeAdvice.Form, String) {
        if advice.chip > .base {
            return (.pro, UpgradeText.formChip(advice.chip))
        }
        if throttledMinutesPerWeek >= 30 {
            return (.pro, UpgradeText.formHeat)
        }
        if advice.memoryVerdict > airMemoryLimit {
            return (.pro, UpgradeText.formMemory)
        }
        if Double(advice.storageVerdict) / 1e12 > airStorageLimit {
            return (.pro, UpgradeText.formStorage)
        }
        return (.air, UpgradeText.formAir)
    }

    /// The desk (D-237): how many displays, the ports they take, and a laptop that mostly stays
    /// closed on the desk.
    static func desk(_ advice: inout UpgradeAdvice, _ inputs: UpgradeInputs) {
        guard let desk = inputs.desk else {
            return
        }
        advice.desk = desk
        let displays = desk.isMostlyDocked || desk.externalDisplays >= 2 ? desk.externalDisplays : 0
        if inputs.hasBattery {
            let onBattery = inputs.onBattery.isEmpty ? 0 : inputs.onBattery.reduce(0) { $0 + $1.average } / Double(inputs.onBattery.count)
            // Closed on the desk, displays on, and hardly ever on battery: a desktop's life.
            if desk.isMostlyClosed, desk.isMostlyDocked {
                let laptop = (advice.form, advice.formReason)
                if onBattery < 0.05 {
                    (advice.form, advice.formReason) = desktop(advice)
                    advice.formReason = UpgradeText.formClosedDesk + " " + advice.formReason
                    advice.alternative = .init(form: laptop.0, reason: UpgradeText.alternativeLaptop(laptop.0))
                } else {
                    advice.alternative = .init(form: .mini, reason: UpgradeText.alternativeMini)
                }
            }
        }
        switch (advice.form, displays) {
        case (.air, 3...):
            (advice.form, advice.chip) = (.pro, max(advice.chip, .max))
            advice.formReason = UpgradeText.formDisplays(displays)
        case (.air, 2):
            advice.deskNotes.append(UpgradeText.airTwoDisplays)
        case (.pro, 3...):
            advice.chip = max(advice.chip, .max)
            advice.deskNotes.append(UpgradeText.displaysNeedMax(displays))
        case (.mini, 4...):
            // A Mac mini drives three; a Mac Studio with a Max chip, five.
            (advice.form, advice.chip) = (.studio, max(advice.chip, .max))
            advice.formReason = UpgradeText.miniDisplays(displays)
        default:
            break
        }
    }

    /// A desktop for someone on a desktop: a Mac mini until a Max chip or more than 64 GB of
    /// memory calls for a Mac Studio. No heat rule: both have fans.
    static func desktop(_ advice: UpgradeAdvice) -> (UpgradeAdvice.Form, String) {
        if advice.chip == .max {
            return (.studio, UpgradeText.formStudioChip)
        }
        if advice.memoryVerdict > miniMemoryLimit {
            return (.studio, UpgradeText.formStudioMemory)
        }
        return (.mini, UpgradeText.formMini(advice.chip))
    }
}
