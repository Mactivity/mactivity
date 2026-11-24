import Foundation

// Checkup (D-101): what Mactivity knows, as a short list of things worth doing. Pure: the UI
// gathers the inputs, this decides what's worth saying.

public struct CheckupItem: Hashable, Sendable, Identifiable {
    public enum Severity: Int, Comparable, Sendable {
        /// Worth doing soon.
        case attention = 0
        /// Worth knowing.
        case suggestion = 1

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Which part of the app fixes it.
    public enum Area: String, Hashable, Sendable {
        case disk, battery, sleep, crashes, startup, memory, accessories, heat, projects, notifications, messages, backups, trash, updates,
             login, unusedApps, unusual, afterUpdates, builds, flagged, launches, timeMachine, software, security
    }

    public let id: String
    public let area: Area
    public let severity: Severity
    public let title: String
    public let detail: String

    public init(id: String, area: Area, severity: Severity, title: String, detail: String) {
        self.id = id
        self.area = area
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public struct CheckupInputs: Sendable {
    public var diskFreeBytes: UInt64?
    public var diskTotalBytes: UInt64?
    public var diskDaysUntilFull: Double?
    public var batteryHealthPercent: Double?
    public var batteryMonthsTo80: Double?
    public var sleepBlockers: [SleepBlocker] = []
    public var awakeLastNight: Bool?
    /// App crash reports (`CrashReport.isAppCrash`) per app name over the last 7 days.
    public var crashesThisWeek: [String: Int] = [:]
    public var brokenStartupItems = 0
    /// Average memory pressure over the last 24 hours, percent.
    public var memoryPressureDay: Double?
    public var swapBytes: UInt64?
    /// The app using the most memory now, for the memory item's advice.
    public var biggestMemoryApp: String?
    public var lowAccessories: [PeripheralBattery] = []
    /// Minutes today with thermal pressure serious or worse.
    public var throttledMinutesToday: Double?
    public var idleServers = 0
    public var idleServersMemory: UInt64 = 0
    /// macOS isn't letting Mactivity's notifications through (D-113).
    public var notificationsOff = false
    /// Messages attachments on this Mac older than a year, in bytes; nil when unknown (D-117).
    public var oldMessagesBytes: UInt64?
    /// Device backups older than six months: their total size and the oldest one's date.
    public var oldBackups: (bytes: UInt64, oldest: Date)?
    /// What's in the Trash, in bytes; nil when unknown (D-119).
    public var trashBytes: UInt64?
    /// Updates Software Update found and hasn't installed (D-120).
    public var pendingUpdates: [PendingUpdate] = []
    /// Installed software that needs updating, with what it needs, most urgent first (D-252).
    public var software: [(item: InstalledSoftware, concern: SoftwareConcern)] = []
    /// The Mac's protections (D-261); nil when not read.
    public var security: SecuritySettings?
    /// How long after the Mac started Mactivity opened, when it isn't set to open at login and
    /// that's over 10 minutes (`Checkup.missedAfterRestart`): history has nothing for that time.
    public var missedAfterRestart: TimeInterval?
    /// Apps open for days without coming to the front, still holding memory (D-135).
    public var unusedApps: [UnusedApp] = []
    /// Apps doing much more than they usually do today (D-198).
    public var unusual: [UnusualUsage] = []
    /// Updates after which an app, or macOS, is notably heavier (D-206).
    public var heavierUpdates: [UpdateImpact] = []
    /// Projects whose builds got slower this week (D-209).
    public var slowerBuilds: [ProjectBuilds] = []
    /// What macOS flagged in the last week, and apps hanging more than they used to (D-212).
    public var flagged: [MacReport] = []
    public var worseHangs: [HangTrend.Worse] = []
    /// The latest sleep, when it drained the battery fast (D-213).
    public var heavySleep: SleepSpan?
    /// Apps slower to open than they used to be (D-215).
    public var slowerLaunches: [AppLaunchTimes] = []
    /// Time Machine's automatic backups stopped: days since the last one, and when (D-216).
    public var timeMachineStopped: (days: Int, last: Date)?
    /// What Storage → Clean Up starts with ticked, all cleanups together (Space you can get
    /// back, D-119); nil when unknown. A full disk's item names it.
    public var reclaimableBytes: UInt64?
    /// Drives reporting trouble or heavy wear (D-157).
    public var drives: [DriveHealth] = []
    /// Apps using much more memory this week than the three weeks before (D-160).
    public var memoryGrowth: [Trends.Growth] = []
    /// Percent an hour on battery: this week, and the three weeks before.
    public var drain: (now: Double, before: Double)?
    /// The last startup, when it was in the last week (D-171), and the apps busiest after it.
    public var lastStartup: StartupCost?
    public var lastStartupApps: [String] = []

    public init() {}
}

public enum Checkup {
    /// Most urgent first; within a severity, in the order below.
    public static func items(_ inputs: CheckupInputs) -> [CheckupItem] {
        var items: [CheckupItem] = []
        items += notifications(inputs)
        items += security(inputs)
        items += disk(inputs)
        items += drives(inputs)
        items += battery(inputs)
        items += sleep(inputs)
        items += crashes(inputs)
        items += memory(inputs)
        items += heat(inputs)
        items += startup(inputs)
        items += slowStartup(inputs)
        items += accessories(inputs)
        items += projects(inputs)
        items += cleanup(inputs)
        items += updates(inputs)
        items += software(inputs)
        items += login(inputs)
        items += unusedApps(inputs)
        items += unusual(inputs)
        items += afterUpdates(inputs)
        items += slowerBuilds(inputs)
        items += flagged(inputs)
        items += heavySleep(inputs)
        items += slowerLaunches(inputs)
        items += timeMachine(inputs)
        items += trends(inputs)
        return items.enumerated()
            .sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }
            .map(\.element)
    }

    private static let storageHint = String(localized: "Storage shows what's taking the space.", bundle: .strings)

    /// What to do about a filling disk: the space Clean Up can get back when it's worth
    /// mentioning (1 GB or more), or where to look.
    private static func diskHint(_ inputs: CheckupInputs) -> String {
        guard let bytes = inputs.reclaimableBytes, bytes >= 1_000_000_000 else {
            return storageHint
        }
        let size = Formatters.bytes(bytes)
        return String(localized: "Storage → Clean Up can get back \(size).", bundle: .strings)
    }

    /// Every alert and the weekly summary depend on it, and nothing else says so unless the
    /// Alerts tab is open (D-113).
    static func notifications(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard inputs.notificationsOff else {
            return []
        }
        return [CheckupItem(
            id: "notifications", area: .notifications, severity: .attention,
            title: String(localized: "Mactivity can't send notifications", bundle: .strings),
            detail: String(
                localized: "Alerts only show inside the app, and the weekly summary can't reach you. The Alerts tab can turn them on.",
                bundle: .strings
            )
        )]
    }

    static func disk(_ inputs: CheckupInputs) -> [CheckupItem] {
        if let free = inputs.diskFreeBytes, let total = inputs.diskTotalBytes, total > 0,
           Double(free) / Double(total) < 0.1 || free < 20_000_000_000 {
            let freeText = Formatters.bytes(free)
            let totalText = Formatters.bytes(total)
            return [CheckupItem(
                id: "disk", area: .disk, severity: .attention,
                title: String(localized: "Your startup disk is almost full", bundle: .strings),
                detail: String(localized: "\(freeText) free of \(totalText). \(diskHint(inputs))", bundle: .strings)
            )]
        }
        if let days = inputs.diskDaysUntilFull, days <= 30 {
            let span = Duration.seconds(max(86400, days * 86400)).formatted(.units(
                allowed: [.weeks, .days],
                width: .wide,
                maximumUnitCount: 1
            ))
            return [CheckupItem(
                id: "disk", area: .disk, severity: days <= 14 ? .attention : .suggestion,
                title: String(localized: "Your startup disk fills up in about \(span)", bundle: .strings),
                detail: String(localized: "At the rate of the last 30 days. \(diskHint(inputs))", bundle: .strings)
            )]
        }
        return []
    }

    static func battery(_ inputs: CheckupInputs) -> [CheckupItem] {
        if let health = inputs.batteryHealthPercent, health < 80 {
            let level = Formatters.percent(health)
            return [CheckupItem(
                id: "battery", area: .battery, severity: .attention,
                title: String(localized: "Battery health is \(level)", bundle: .strings),
                detail: String(
                    localized: "Below 80%, macOS may recommend service. System Settings → Battery has the details.",
                    bundle: .strings
                )
            )]
        }
        if let months = inputs.batteryMonthsTo80, months > 0, months <= 12 {
            // At least 2: "about 1 months" isn't English, and under two months "about 2" is fair.
            let count = max(2, Int(months.rounded(.up)))
            return [CheckupItem(
                id: "battery", area: .battery, severity: .suggestion,
                title: String(localized: "Battery health reaches 80% in about \(count) months", bundle: .strings),
                detail: String(
                    localized: "At its rate over the last year. Optimized Battery Charging, in System Settings → Battery, slows this.",
                    bundle: .strings
                )
            )]
        }
        return []
    }

    static func sleep(_ inputs: CheckupInputs) -> [CheckupItem] {
        var items: [CheckupItem] = []
        if inputs.awakeLastNight == true {
            items.append(CheckupItem(
                id: "sleep-night", area: .sleep, severity: .attention,
                title: String(localized: "Your Mac didn't sleep last night", bundle: .strings),
                detail: String(localized: "History → Sleep shows the night and what woke it.", bundle: .strings)
            ))
        }
        var names: [String] = []
        for blocker in inputs.sleepBlockers where blocker.keeps == .system && blocker.isUserFacing && !names.contains(blocker.app.name) {
            names.append(blocker.app.name)
        }
        if !names.isEmpty {
            let list = names.formatted(.list(type: .and))
            items.append(CheckupItem(
                id: "sleep-now", area: .sleep, severity: .suggestion,
                title: String(localized: "Keeping your Mac awake: \(list)", bundle: .strings),
                detail: String(
                    localized: "While it runs, your Mac won't sleep when idle. Quit it when you're done to save power.",
                    bundle: .strings
                )
            ))
        }
        return items
    }

    static func crashes(_ inputs: CheckupInputs) -> [CheckupItem] {
        inputs.crashesThisWeek
            .filter { $0.value >= 2 }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { name, count in
                CheckupItem(
                    id: "crash-\(name)", area: .crashes, severity: count >= 3 ? .attention : .suggestion,
                    title: String(localized: "\(name) crashes this week: \(count)", bundle: .strings),
                    detail: String(localized: "An update often fixes it. History → Crashes and hangs has the reports.", bundle: .strings)
                )
            }
    }

    static func memory(_ inputs: CheckupInputs) -> [CheckupItem] {
        let pressure = inputs.memoryPressureDay ?? 0
        let swap = inputs.swapBytes ?? 0
        guard pressure >= 60 || swap >= 4_000_000_000 else {
            return []
        }
        let level = Formatters.percent(pressure)
        let swapText = Formatters.bytes(swap)
        let advice = inputs.biggestMemoryApp.map {
            String(localized: "Quitting \($0) would free the most.", bundle: .strings, comment: "Checkup: the app using the most memory")
        } ?? ""
        return [CheckupItem(
            id: "memory", area: .memory, severity: .suggestion,
            title: String(localized: "Memory has been tight today", bundle: .strings),
            detail: String(localized: "Pressure averaged \(level), with \(swapText) in swap. \(advice)", bundle: .strings)
                .trimmingCharacters(in: .whitespaces)
        )]
    }

    static func heat(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard let minutes = inputs.throttledMinutesToday, minutes >= 15 else {
            return []
        }
        let span = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2))
        return [CheckupItem(
            id: "heat", area: .heat, severity: .suggestion,
            title: String(localized: "Your Mac slowed down to stay cool", bundle: .strings),
            detail: String(localized: "For \(span) today. The CPU tab shows which apps were busiest.", bundle: .strings)
        )]
    }

    static func startup(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard inputs.brokenStartupItems > 0 else {
            return []
        }
        return [CheckupItem(
            id: "startup", area: .startup, severity: .suggestion,
            title: String(localized: "Broken startup items: \(inputs.brokenStartupItems)", bundle: .strings),
            detail: String(localized: "They point to apps or files that are gone. Startup shows them.", bundle: .strings)
        )]
    }

    static func accessories(_ inputs: CheckupInputs) -> [CheckupItem] {
        inputs.lowAccessories.map { device in
            let level = Formatters.percent(device.percent)
            return CheckupItem(
                id: "accessory-\(device.id)", area: .accessories, severity: .suggestion,
                title: String(localized: "\(device.name) is at \(level)", bundle: .strings),
                detail: String(localized: "Charge it soon.", bundle: .strings)
            )
        }
    }

    /// Space this Mac's own copies take (D-117): Messages attachments over a year old, from 1 GB,
    /// and device backups over six months old.
    static func cleanup(_ inputs: CheckupInputs) -> [CheckupItem] {
        var items: [CheckupItem] = []
        if let bytes = inputs.oldMessagesBytes, bytes >= 1_000_000_000 {
            let size = Formatters.bytes(bytes)
            items.append(CheckupItem(
                id: "messages", area: .messages, severity: .suggestion,
                title: String(localized: "Messages attachments older than a year: \(size)", bundle: .strings),
                detail: String(
                    localized: "This Mac's copies; your iPhone keeps its own. Storage → Clean Up can move them to the Trash.",
                    bundle: .strings
                )
            ))
        }
        if let old = inputs.oldBackups, old.bytes > 0 {
            let size = Formatters.bytes(old.bytes)
            let date = old.oldest.formatted(.dateTime.month(.abbreviated).year())
            items.append(CheckupItem(
                id: "backups", area: .backups, severity: .suggestion,
                title: String(localized: "iPhone and iPad backups older than six months: \(size)", bundle: .strings),
                detail: String(
                    localized: "The oldest is from \(date). Storage → Clean Up shows them; check you don't need one first.",
                    bundle: .strings
                )
            ))
        }
        if let trash = inputs.trashBytes, trash >= 5_000_000_000 {
            let size = Formatters.bytes(trash)
            items.append(CheckupItem(
                id: "trash", area: .trash, severity: .suggestion,
                title: String(localized: "The Trash holds \(size)", bundle: .strings),
                detail: String(localized: "It's still using the space. Empty the Trash in Finder when you're sure.", bundle: .strings)
            ))
        }
        return items
    }

    /// A waiting update: security fixes arrive this way (D-120). Named when there's one.
    static func updates(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard let first = inputs.pendingUpdates.first else {
            return []
        }
        let title = inputs.pendingUpdates.count == 1
            ? String(localized: "An update is ready: \(first.title)", bundle: .strings)
            : String(localized: "Updates ready: \(inputs.pendingUpdates.count)", bundle: .strings)
        return [CheckupItem(
            id: "updates", area: .updates, severity: .suggestion, title: title,
            detail: String(
                localized: "System Settings → General → Software Update installs it. Updates often include security fixes.",
                bundle: .strings
            )
        )]
    }

    /// Pure: how long Mactivity missed after the Mac started, or nil when it opens at login or
    /// opened within 10 minutes of the Mac (someone who opens it by hand right away loses little).
    public static func missedAfterRestart(bootedAt: Date, launchedAt: Date, opensAtLogin: Bool) -> TimeInterval? {
        let missed = launchedAt.timeIntervalSince(bootedAt)
        return !opensAtLogin && missed > 600 ? missed : nil
    }

    /// History has a gap because Mactivity didn't open with the Mac. Only on that evidence, not
    /// for everyone with Open at login off: Checkup items can't be dismissed, and some people
    /// choose to open it by hand.
    static func login(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard let missed = inputs.missedAfterRestart else {
            return []
        }
        let span = Duration.seconds(missed).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 1))
        return [CheckupItem(
            id: "login", area: .login, severity: .suggestion,
            title: String(localized: "History has a gap: \(span) after your Mac started", bundle: .strings),
            detail: String(
                localized: "Mactivity wasn't open then, so nothing was recorded. Turn on Open at login in Settings → General.",
                bundle: .strings
            )
        )]
    }

    /// From 1 GB together: a few hundred MB isn't worth a line.
    static func unusedApps(_ inputs: CheckupInputs) -> [CheckupItem] {
        let total = inputs.unusedApps.reduce(0) { $0 + $1.memoryBytes }
        guard total >= 1_000_000_000 else {
            return []
        }
        let names = inputs.unusedApps.prefix(3).map(\.app.name).formatted(.list(type: .and))
        let size = Formatters.memory(total)
        return [CheckupItem(
            id: "unusedApps", area: .unusedApps, severity: .suggestion,
            title: String(localized: "Open but unused for days: \(names)", bundle: .strings),
            detail: String(localized: "Together they hold \(size) of memory. Quitting frees it.", bundle: .strings)
        )]
    }

    /// One line for whatever is out of the ordinary today: the apps, most unusual first (D-198).
    static func unusual(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard !inputs.unusual.isEmpty else {
            return []
        }
        var seen = Set<String>()
        let names = inputs.unusual.filter { seen.insert($0.app.id).inserted }.prefix(3).map(\.app.name).formatted(.list(type: .and))
        return [CheckupItem(
            id: "unusual", area: .unusual, severity: .suggestion,
            title: String(localized: "Busier than usual today: \(names)", bundle: .strings),
            detail: String(
                localized: "Compared with each app's usual day on this Mac. Overview says by how much; each app's history shows when.",
                bundle: .strings
            )
        )]
    }

    static func projects(_ inputs: CheckupInputs) -> [CheckupItem] {
        guard inputs.idleServers > 0 else {
            return []
        }
        let memory = Formatters.bytes(inputs.idleServersMemory)
        return [CheckupItem(
            id: "projects", area: .projects, severity: .suggestion,
            title: String(localized: "Idle dev servers: \(inputs.idleServers)", bundle: .strings),
            detail: String(localized: "They hold \(memory). Projects can stop them.", bundle: .strings)
        )]
    }
}
