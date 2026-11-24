import Foundation

/// The words of "Your next Mac" (D-181), with the figures in them.
public enum UpgradeText {
    /// "28h", "2h 30m", "45m": hours a week read better than "1d 4h".
    public static func hours(_ hours: Double) -> String {
        Duration.seconds(Int((hours * 3600).rounded()))
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: hours >= 10 ? 1 : 2))
    }

    // MARK: Processor and graphics

    public static func chip(_ chip: UpgradeAdvice.ChipClass) -> String {
        switch chip {
        case .base: String(localized: "Base chip", bundle: .strings, comment: "Next Mac: the standard Apple silicon chip (M-series)")
        case .pro: String(localized: "Pro chip", bundle: .strings, comment: "Next Mac: an M-series Pro chip")
        case .max: String(localized: "Max chip", bundle: .strings, comment: "Next Mac: an M-series Max chip")
        }
    }

    static func graphics(_ chip: UpgradeAdvice.ChipClass) -> String {
        switch chip {
        case .base: String(localized: "Standard graphics", bundle: .strings, comment: "Next Mac: the base chip's GPU is enough")
        case .pro: String(localized: "More GPU cores", bundle: .strings, comment: "Next Mac: a Pro chip's GPU")
        case .max: String(localized: "Most GPU cores", bundle: .strings, comment: "Next Mac: a Max chip's GPU")
        }
    }

    static func processorHeadline(_ chip: UpgradeAdvice.ChipClass, busyHours: Double, busy: Double) -> String {
        switch chip {
        case .max:
            String(
                localized: "Near full about \(hours(busyHours)) a week. A Max chip's extra performance cores finish that work sooner.",
                bundle: .strings
            )
        case .pro:
            String(
                localized: "Near full about \(hours(busyHours)) a week. A Pro chip's extra performance cores take that in stride.",
                bundle: .strings
            )
        case .base:
            String(
                localized: "Rarely busy: \(Formatters.percent(busy)) at its busiest. Any current chip handles this with room to spare.",
                bundle: .strings
            )
        }
    }

    static func graphicsHeadline(_ chip: UpgradeAdvice.ChipClass, busyHours: Double, busy: Double) -> String {
        switch chip {
        case .max:
            String(localized: "Heavy graphics about \(hours(busyHours)) a week: worth the most GPU cores.", bundle: .strings)
        case .pro:
            String(localized: "Graphics get busy at times: \(Formatters.percent(busy)) at their busiest.", bundle: .strings)
        case .base:
            String(localized: "Light graphics: \(Formatters.percent(busy)) at their busiest.", bundle: .strings)
        }
    }

    static func typicalBusy(_ typical: Double, _ busy: Double) -> String {
        String(
            localized: "Typical \(Formatters.percent(typical)) · busy \(Formatters.percent(busy))",
            bundle: .strings,
            comment: "Next Mac: the median and the 95th percentile of use"
        )
    }

    static func nearFull(_ hours: Double) -> String {
        hours < 0.25
            ? String(localized: "Rarely near full", bundle: .strings)
            : String(localized: "Near full \(Self.hours(hours)) a week", bundle: .strings)
    }

    // MARK: Memory

    public static func gigabytes(_ gigabytes: UInt64) -> String {
        String(localized: "\(gigabytes) GB", bundle: .strings, comment: "Next Mac: memory size, e.g. 32 GB")
    }

    static func memoryHeadline(busy: Double, peak: Double, swap: Double, fit: UpgradeAdvice.Fit) -> String {
        let busyText = Formatters.memory(busy)
        let peakText = Formatters.memory(peak)
        if fit >= .tight, swap > 0 {
            return String(
                localized: """
                About \(busyText) on a busy day, up to \(peakText), and macOS moved \(Formatters.memory(swap)) to the disk. \
                More memory keeps it fast.
                """,
                bundle: .strings
            )
        }
        return String(localized: "About \(busyText) on a busy day, up to \(peakText). This leaves room to grow.", bundle: .strings)
    }

    static func memoryUse(_ typical: Double, _ busy: Double, _ installed: Double) -> String {
        String(
            localized: "Typical \(Formatters.memory(typical)) · busy \(Formatters.memory(busy)) of \(Formatters.memory(installed))",
            bundle: .strings
        )
    }

    static func pressure(_ minutesPerWeek: Double) -> String {
        minutesPerWeek < 5
            ? String(localized: "Memory pressure stayed low", bundle: .strings)
            : String(localized: "High memory pressure \(hours(minutesPerWeek / 60)) a week", bundle: .strings)
    }

    // MARK: Storage

    public static func storage(_ terabytes: Double) -> String {
        terabytes < 1
            ? String(localized: "\(Int((terabytes * 1000).rounded())) GB", bundle: .strings, comment: "Next Mac: storage, e.g. 512 GB")
            : String(localized: "\(Int(terabytes)) TB", bundle: .strings, comment: "Next Mac: storage, e.g. 2 TB")
    }

    static func storageHeadline(used: Double, capacity: Double, perMonth: Double) -> String {
        let usedText = Formatters.bytes(used)
        let capacityText = Formatters.bytes(capacity)
        return perMonth >= 1e9
            ? String(
                localized: """
                \(usedText) used of \(capacityText), growing about \(Formatters.bytes(perMonth)) a month. \
                Sized for three years.
                """,
                bundle: .strings
            )
            : String(
                localized: "\(usedText) used of \(capacityText), and steady. Sized for three years with room to spare.",
                bundle: .strings
            )
    }

    /// What the size is for: the headline already says how fast it grows, so this says where
    /// that leads.
    static func storageOutlook(used: Double, perMonth: Double, measuredDays: Int) -> String {
        if measuredDays < UpgradeAdvisor.minimumGrowthDays {
            return String(localized: "Growth needs two weeks of history to measure", bundle: .strings)
        }
        let later = Formatters.bytes(used + perMonth * 12 * UpgradeAdvisor.storageYears)
        return String(
            localized: "About \(later) used in three years at this rate",
            bundle: .strings,
            comment: "Next Mac: today's use plus three years of growth"
        )
    }

    // MARK: Battery

    static let allDay = String(localized: "All-day battery", bundle: .strings, comment: "Next Mac: battery life matters")
    static let pluggedIn = String(localized: "Mostly plugged in", bundle: .strings, comment: "Next Mac: battery life matters little")

    static func batteryHeadline(share: Double, charge: Double?) -> String {
        let shareText = Formatters.percent(share * 100)
        guard let charge else {
            return String(localized: "On battery \(shareText) of the time.", bundle: .strings)
        }
        // Light hours on battery make a charge look endless; past a day it's just "more than a day".
        if charge > 24 {
            return String(
                localized: "On battery \(shareText) of the time; a full charge lasts more than a day at your pace.",
                bundle: .strings
            )
        }
        return String(
            localized: "On battery \(shareText) of the time; a full charge lasts about \(hours(charge)) at your pace.",
            bundle: .strings
        )
    }

    static func drain(_ perHour: Double?) -> String {
        perHour.map { String(localized: "Uses \(Formatters.percent($0)) an hour on battery", bundle: .strings) }
            ?? String(localized: "Not enough time on battery to measure", bundle: .strings)
    }

    // MARK: Form

    static func formChip(_ chip: UpgradeAdvice.ChipClass) -> String {
        chip == .max
            ? String(localized: "Max chips come in the MacBook Pro.", bundle: .strings)
            : String(localized: "Pro chips come in the MacBook Pro, and its fan keeps long loads at full speed.", bundle: .strings)
    }

    static let formHeat = String(
        localized: "This Mac slowed down to stay cool for long stretches: the MacBook Pro's fan keeps that work at full speed.",
        bundle: .strings
    )
    static let formMemory = String(localized: "More than 32 GB of memory means a MacBook Pro.", bundle: .strings)
    static let formStorage = String(localized: "More than 2 TB of storage means a MacBook Pro.", bundle: .strings)
    static let formStudioChip = String(
        localized: "Max chips in a desktop come in the Mac Studio, which also takes the most memory.",
        bundle: .strings
    )
    static let formStudioMemory = String(localized: "More than 64 GB of memory means a Mac Studio.", bundle: .strings)

    static func formMini(_ chip: UpgradeAdvice.ChipClass) -> String {
        chip == .pro
            ? String(localized: "A Mac mini with a Pro chip does all of this, quietly, in a few inches of desk.", bundle: .strings)
            : String(
                localized: "A Mac mini does all of this, quietly. An iMac has the same chip with a display built in.",
                bundle: .strings
            )
    }

    // MARK: The desk (D-237)

    static let formClosedDesk = String(
        localized: "Your Mac stays closed on the desk, driving its displays, and hardly ever runs on battery.",
        bundle: .strings,
        comment: "Next Mac: why a desktop, before the desktop's own reason"
    )

    static let alternativeMini = String(
        localized: """
        It stays closed on the desk most of the time: if a laptop isn't needed for travel, a Mac mini there costs less \
        and has more ports.
        """,
        bundle: .strings,
        comment: "Next Mac: a Mac mini worth weighing beside the laptop"
    )

    static func alternativeLaptop(_ form: UpgradeAdvice.Form) -> String {
        String(
            localized: "If it travels too, a \(form.name) does the same work.",
            bundle: .strings,
            comment: "Next Mac: the laptop worth weighing beside the desktop, e.g. If it travels too, a MacBook Air does the same work."
        )
    }

    static let airTwoDisplays = String(
        localized: """
        Two external displays: a MacBook Air needs M4 or later to drive both with the lid open, and they take both of its two ports, \
        so anything else needs a hub.
        """,
        bundle: .strings,
        comment: "Next Mac: what two displays mean for a MacBook Air"
    )

    static func formDisplays(_ count: Int) -> String {
        String(
            localized: "\(count) external displays: more than a MacBook Air drives. A MacBook Pro with a Max chip does.",
            bundle: .strings,
            comment: "Next Mac: why a MacBook Pro, e.g. 3 external displays"
        )
    }

    static func displaysNeedMax(_ count: Int) -> String {
        String(
            localized: "\(count) external displays: on a MacBook Pro, that takes a Max chip.",
            bundle: .strings,
            comment: "Next Mac: displays a MacBook Pro needs a Max chip for"
        )
    }

    static func miniDisplays(_ count: Int) -> String {
        String(
            localized: "\(count) external displays: more than a Mac mini drives. A Mac Studio does.",
            bundle: .strings,
            comment: "Next Mac: why a Mac Studio, e.g. 4 external displays"
        )
    }

    /// "Two 4K displays, lid closed 80% of the time" for the report.
    public static func desk(_ desk: DeskUsage) -> String {
        let largest = DeskUsage.name(width: desk.largestWidth, height: desk.largestHeight)
        let closed = Int((desk.closedShare * 100).rounded())
        let displays = desk.externalDisplays == 0
            ? String(localized: "No external display most of the time", bundle: .strings, comment: "Next Mac: the desk")
            : String(
                localized: "\(desk.externalDisplays) external displays, up to \(largest)",
                bundle: .strings,
                comment: "Next Mac: the desk, e.g. 2 external displays, up to 4K"
            )
        guard desk.closedShare > 0 else {
            return displays
        }
        return String(
            localized: "\(displays), lid closed \(closed)% of the time",
            bundle: .strings,
            comment: "Next Mac: the desk, then how often the lid was closed, e.g. ..., lid closed 80% of the time"
        )
    }

    static let formAir = String(
        localized: "No long heavy loads: a MacBook Air does all of this, silently and without a fan.",
        bundle: .strings
    )
}
