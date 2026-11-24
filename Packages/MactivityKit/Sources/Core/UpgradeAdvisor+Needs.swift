import Foundation

extension UpgradeAdvisor {
    /// More performance cores pay off when the processor sits near full for hours a week; a few
    /// busy minutes a day finish fast on any Apple silicon chip.
    static func processor(_ inputs: UpgradeInputs, perWeek: Double) -> (chip: UpgradeAdvice.ChipClass, need: UpgradeAdvice.Need) {
        let busyHours = minutes(inputs.cpu, inputs.bucketSeconds) { $0.average >= busyCPU } / 60 * perWeek
        let typical = percentile(inputs.cpu, 0.5)
        let busy = percentile(inputs.cpu, 0.95)
        // The busiest quarter-hour, not its one-second spike: a 100% blip says nothing about fit.
        let peak = inputs.cpu.map(\.average).max() ?? 0
        let chip: UpgradeAdvice.ChipClass = busyHours >= maxHoursPerWeek && busy >= 85 ? .max
            : busyHours >= proHoursPerWeek || busy >= 70 ? .pro : .base
        let fit: UpgradeAdvice.Fit = busyHours >= maxHoursPerWeek ? .short
            : busyHours >= proHoursPerWeek ? .tight : busy >= 40 ? .comfortable : .plenty
        let need = UpgradeAdvice.Need(
            kind: .processor, fit: fit, verdict: UpgradeText.chip(chip),
            headline: UpgradeText.processorHeadline(chip, busyHours: busyHours, busy: busy),
            evidence: [UpgradeText.typicalBusy(typical, busy), UpgradeText.nearFull(busyHours)],
            usage: UpgradeAdvice.Usage(typical: typical / 100, busy: busy / 100, peak: min(1, peak / 100)),
            topApp: inputs.cpuApps.first
        )
        return (chip, need)
    }

    /// Enough for a busy day with room to spare, never less than this Mac has when it's short.
    static func memory(_ inputs: UpgradeInputs, perWeek: Double) -> (gigabytes: UInt64, need: UpgradeAdvice.Need)? {
        guard !inputs.memoryUsed.isEmpty, inputs.installedMemory > 0 else {
            return nil
        }
        let installed = Double(inputs.installedMemory)
        let typical = percentile(inputs.memoryUsed, 0.5)
        let busy = percentile(inputs.memoryUsed, 0.95)
        let peak = inputs.memoryUsed.map(\.maximum).max() ?? busy
        let swap = inputs.swap.map(\.maximum).max() ?? 0
        let pressuredMinutes = minutes(inputs.memoryPressure, inputs.bucketSeconds) { $0.average >= pressured } * perWeek
        let fit: UpgradeAdvice.Fit = pressuredMinutes >= 60 || swap > installed / 4 ? .short
            : pressuredMinutes >= 10 || busy / installed >= 0.8 ? .tight
            : busy / installed >= 0.6 ? .comfortable : .plenty
        var needed = max(busy * 1.4, peak * 1.15 + swap * 0.5) / gib
        if fit >= .tight {
            needed = max(needed, installed / gib + 1)
        }
        let gigabytes = size(UInt64(needed.rounded(.up)), in: memorySizes)
        let need = UpgradeAdvice.Need(
            kind: .memory, fit: fit, verdict: UpgradeText.gigabytes(gigabytes),
            headline: UpgradeText.memoryHeadline(busy: busy, peak: peak, swap: swap, fit: fit),
            evidence: [UpgradeText.memoryUse(typical, busy, installed), UpgradeText.pressure(pressuredMinutes)],
            usage: UpgradeAdvice.Usage(typical: typical / installed, busy: busy / installed, peak: min(1, peak / installed)),
            topApp: inputs.memoryApps.first
        )
        return (gigabytes, need)
    }

    /// A Max chip's extra GPU cores for hours of heavy graphics a week; a Pro's for some.
    static func graphics(_ inputs: UpgradeInputs, perWeek: Double) -> (chip: UpgradeAdvice.ChipClass, need: UpgradeAdvice.Need)? {
        guard !inputs.gpu.isEmpty else {
            return nil
        }
        let busyHours = minutes(inputs.gpu, inputs.bucketSeconds) { $0.average >= busyGPU } / 60 * perWeek
        let typical = percentile(inputs.gpu, 0.5)
        let busy = percentile(inputs.gpu, 0.95)
        let peak = inputs.gpu.map(\.average).max() ?? 0
        let chip: UpgradeAdvice.ChipClass = busyHours >= 5 ? .max : busyHours >= 1 || busy >= 60 ? .pro : .base
        let fit: UpgradeAdvice.Fit = busyHours >= 5 ? .short : busyHours >= 1 ? .tight : busy >= 40 ? .comfortable : .plenty
        let need = UpgradeAdvice.Need(
            kind: .graphics, fit: fit, verdict: UpgradeText.graphics(chip),
            headline: UpgradeText.graphicsHeadline(chip, busyHours: busyHours, busy: busy),
            evidence: [UpgradeText.typicalBusy(typical, busy), UpgradeText.nearFull(busyHours)],
            usage: UpgradeAdvice.Usage(typical: typical / 100, busy: busy / 100, peak: min(1, peak / 100)),
            topApp: inputs.gpuApps.first
        )
        return (chip, need)
    }

    /// Today's use plus three years at the recent rate, with a fifth left free.
    static func storage(_ inputs: UpgradeInputs) -> (bytes: UInt64, need: UpgradeAdvice.Need)? {
        guard let latest = inputs.diskFree.last, inputs.diskCapacity > 0 else {
            return nil
        }
        let capacity = Double(inputs.diskCapacity)
        let used = max(0, capacity - latest.average)
        let perMonth = growthPerMonth(inputs.diskFree)
        let projected = (used + perMonth * 12 * storageYears) * 1.25
        let terabytes = size(projected / 1e12, in: storageSizes)
        let free = latest.average / capacity
        let fit: UpgradeAdvice.Fit = free < 0.1 ? .short : free < 0.2 ? .tight : free < 0.4 ? .comfortable : .plenty
        let need = UpgradeAdvice.Need(
            kind: .storage, fit: fit, verdict: UpgradeText.storage(terabytes),
            headline: UpgradeText.storageHeadline(used: used, capacity: capacity, perMonth: perMonth),
            evidence: [UpgradeText.storageOutlook(used: used, perMonth: perMonth, measuredDays: inputs.diskFree.count)],
            usage: UpgradeAdvice.Usage(typical: used / capacity, busy: used / capacity, peak: used / capacity),
            topApp: nil
        )
        return (UInt64(terabytes * 1e12), need)
    }

    /// Space used per month from the daily free space, by least squares; nothing under two weeks
    /// of days (one big download or a week of builds would read as a trend), and never negative.
    static func growthPerMonth(_ days: [DayValue]) -> Double {
        guard days.count >= minimumGrowthDays, let first = days.first?.day else {
            return 0
        }
        let xs = days.map { $0.day.timeIntervalSince(first) / 86400 }
        let ys = days.map { -$0.average }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let numerator = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let denominator = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard denominator > 0 else {
            return 0
        }
        return max(0, numerator / denominator * 30)
    }

    /// How much of the time it's unplugged, and how long a charge lasts at this Mac's pace.
    static func battery(_ inputs: UpgradeInputs) -> UpgradeAdvice.Need? {
        guard inputs.hasBattery, !inputs.onBattery.isEmpty else {
            return nil
        }
        let share = min(1, max(0, inputs.onBattery.reduce(0) { $0 + min(1, max(0, $1.average)) } / Double(inputs.onBattery.count)))
        let onBattery = Dictionary(inputs.onBattery.map { ($0.at, $0.average) }, uniquingKeysWith: max)
        var drained = 0.0
        var hours = 0.0
        for (earlier, later) in zip(inputs.batteryLevel, inputs.batteryLevel.dropFirst())
            where (onBattery[earlier.at] ?? 0) > 0.9 && later.at.timeIntervalSince(earlier.at) <= inputs.bucketSeconds * 1.5 {
            drained += max(0, earlier.average - later.average)
            hours += later.at.timeIntervalSince(earlier.at) / 3600
        }
        let perHour = hours >= 1 ? drained / hours : nil
        let charge = perHour.flatMap { $0 > 0.5 ? 100 / $0 : nil }
        let unplugged = share >= 0.25
        let fit: UpgradeAdvice.Fit = unplugged && (charge ?? 99) < 8 ? .tight : unplugged ? .comfortable : .plenty
        return UpgradeAdvice.Need(
            kind: .battery, fit: fit, verdict: unplugged ? UpgradeText.allDay : UpgradeText.pluggedIn,
            headline: UpgradeText.batteryHeadline(share: share, charge: charge),
            evidence: [UpgradeText.drain(perHour)],
            usage: UpgradeAdvice.Usage(typical: share, busy: share, peak: share),
            topApp: nil
        )
    }
}
