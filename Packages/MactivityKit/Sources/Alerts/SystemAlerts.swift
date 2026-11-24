import Core
import Foundation

/// What the Mac-level rules look at, gathered every 10 minutes (D-099).
public struct SystemAlertInputs: Sendable {
    /// Connected accessories and their levels.
    public var devices: [PeripheralBattery]
    /// `DiskForecast.daysUntilFull` for the startup disk, nil when it isn't shrinking.
    public var diskDaysUntilFull: Double?
    public var diskName: String
    /// Crash reports per app within the crash rule's window.
    public var crashes: [AppIdentity: Int]
    /// Whether the Mac stayed awake last night, once it's morning; nil when it isn't known.
    public var awakeOvernight: Bool?
    /// What's keeping it awake now, for the overnight alert's text.
    public var awakeBecause: [String]
    /// Data each app used on an expensive connection since the last check (D-136).
    public var hotspotUsage: [HotspotSession.Usage]
    /// The startup disk's free space now, and its name (D-149).
    public var diskFreeBytes: UInt64?
    /// Minutes of the last 10 with thermal pressure serious or worse, and the busiest app then.
    public var hotMinutes: Double?
    public var hotBusiest: String?
    /// How long the Mac has been without a network connection, when it is.
    public var offlineFor: TimeInterval?
    /// Dev processes stuck at a full core or leaking memory, just found (D-156).
    public var runaways: [RunawayReport]
    /// Apps far beyond their usual day, from `Baselines` (D-201); empty until the day has enough
    /// in it to compare.
    public var unusual: [UnusualUsage]
    /// The coding-agent sessions running now, for the agent limits (D-227).
    public var agentSessions: [AgentSession]
    /// What added itself to start with the Mac since the last look (D-231).
    public var startupAdditions: [StartupAddition]
    /// The month's data against the budget, when one is set (D-235).
    public var dataBudget: DataBudgetStatus?
    /// Installed software with a high or critical vulnerability or past its end of life (D-252).
    public var urgentSoftware: [(item: InstalledSoftware, concern: SoftwareConcern)] = []

    public init(
        devices: [PeripheralBattery] = [], diskDaysUntilFull: Double? = nil, diskName: String = "Macintosh HD",
        crashes: [AppIdentity: Int] = [:], awakeOvernight: Bool? = nil, awakeBecause: [String] = [],
        hotspotUsage: [HotspotSession.Usage] = [],
        diskFreeBytes: UInt64? = nil, hotMinutes: Double? = nil, hotBusiest: String? = nil, offlineFor: TimeInterval? = nil,
        runaways: [RunawayReport] = [], unusual: [UnusualUsage] = [], agentSessions: [AgentSession] = [],
        startupAdditions: [StartupAddition] = [], dataBudget: DataBudgetStatus? = nil
    ) {
        self.dataBudget = dataBudget
        self.agentSessions = agentSessions
        self.startupAdditions = startupAdditions
        self.runaways = runaways
        self.unusual = unusual
        self.hotspotUsage = hotspotUsage
        self.diskFreeBytes = diskFreeBytes
        self.hotMinutes = hotMinutes
        self.hotBusiest = hotBusiest
        self.offlineFor = offlineFor
        self.devices = devices
        self.diskDaysUntilFull = diskDaysUntilFull
        self.diskName = diskName
        self.crashes = crashes
        self.awakeOvernight = awakeOvernight
        self.awakeBecause = awakeBecause
    }
}

/// The Mac-level rules (D-099). Pure, like `AlertEngine`: quiet hours and muting apply the same
/// way, and each rule keeps its own repeat interval, longer than the snapshot rules' cooldown,
/// since a low battery or a filling disk stays true for hours or days.
public enum SystemAlertRules {
    static let repeatAfter: [AlertRule: TimeInterval] = [
        .accessoryBatteryLow: 12 * 3600,
        .diskFilling: 3 * 86400,
        .appCrashing: 24 * 3600,
        .notSleeping: 20 * 3600,
        .hotspotData: 3600,
        .diskLow: 24 * 3600,
        .overheating: 3600,
        .connectionLost: 3600,
        // The watch reports each process once; another one in the same app still alerts.
        .runawayProcess: 0,
        // Once a day per app: today's figures only move slowly.
        .outOfTheOrdinary: 20 * 3600,
        // Keyed per session (its PID and start), so once per session, a relaunch included.
        .agentLongSession: 30 * 86400,
        .agentMemory: 30 * 86400,
        // Each item is reported once by the watch; a week, should it come back after removal.
        .newStartupItem: 7 * 86400,
        // Keyed per period and step: once at the warning, once at the allowance (D-235).
        .dataBudget: 40 * 86400,
        // Keyed per package and version: once, and again a month on if it's still there.
        .vulnerableSoftware: 30 * 86400,
    ]

    public static func evaluate(
        settings: AlertSettings, inputs: SystemAlertInputs, state: AlertState, now: Date, calendar: Calendar
    ) -> AlertEvaluation {
        if let quietHours = settings.quietHours, quietHours.contains(now, calendar: calendar) {
            return AlertEvaluation(alerts: [], state: state)
        }
        var newState = state
        var alerts: [Alert] = []
        func fire(_ rule: AlertRule, _ app: AppIdentity, title: String, body: String) {
            guard settings.settings(for: rule).isEnabled, !settings.mutedAppIDs.contains(app.id) else {
                return
            }
            let key = AlertKey(appID: app.id, rule: rule)
            // A time ahead of now is from a clock since set back (D-221).
            if let last = newState.lastFired[key], last <= now, last.addingTimeInterval(repeatAfter[rule] ?? 86400) > now {
                return
            }
            alerts.append(Alert(rule: rule, app: app, firedAt: now, title: title, body: body))
            newState.lastFired[key] = now
        }

        let low = settings.settings(for: .accessoryBatteryLow).threshold
        for device in inputs.devices where device.percent <= low {
            let level = Formatters.percent(device.percent)
            fire(
                .accessoryBatteryLow, deviceIdentity(device),
                title: String(localized: "\(device.name) battery is low", bundle: .strings, comment: "Alert title; the accessory's name"),
                body: String(localized: "\(level) left. Charge it soon.", bundle: .strings, comment: "Accessory battery alert")
            )
        }

        if let days = inputs.diskDaysUntilFull, days <= settings.settings(for: .diskFilling).threshold {
            let span = Duration.seconds(max(86400, days * 86400))
                .formatted(.units(allowed: [.weeks, .days], width: .wide, maximumUnitCount: 1))
            fire(
                .diskFilling, diskIdentity(inputs.diskName),
                title: String(localized: "\(inputs.diskName) is filling up", bundle: .strings, comment: "Alert title; the disk's name"),
                body: String(
                    localized: "At this rate it's full in about \(span). Storage shows what's taking the space.", bundle: .strings
                )
            )
        }

        let crashing = settings.settings(for: .appCrashing)
        for (app, count) in inputs.crashes.sorted(by: { $0.key.name < $1.key.name }) where Double(count) >= crashing.threshold {
            fire(
                .appCrashing, app,
                title: String(localized: "\(app.name) keeps crashing", bundle: .strings, comment: "Alert title; the app's name"),
                body: String(localized: "Crashes in the last day: \(count).", bundle: .strings)
            )
        }

        if inputs.awakeOvernight == true {
            let because = inputs.awakeBecause.formatted(.list(type: .and))
            fire(
                .notSleeping, sleepIdentity,
                title: String(localized: "Your Mac stayed awake last night", bundle: .strings),
                body: inputs.awakeBecause.isEmpty
                    ? String(localized: "Nothing is holding it awake now. History → Sleep shows the night.", bundle: .strings)
                    : String(localized: "Keeping it awake now: \(because).", bundle: .strings)
            )
        }
        for alert in macAlerts(inputs, settings: settings) + agentAlerts(inputs.agentSessions, settings: settings, now: now) {
            fire(alert.rule, alert.app, title: alert.title, body: alert.body)
        }
        return AlertEvaluation(alerts: alerts, state: newState)
    }

    /// Apps that used more than `threshold` of an iPhone hotspot's data since the last check (D-136).
    static func hotspotAlerts(_ usage: [HotspotSession.Usage], threshold: Double) -> [(app: AppIdentity, title: String, body: String)] {
        usage.filter { $0.bytes >= threshold }.map { usage in
            let amount = Formatters.bytes(usage.bytes)
            return (
                usage.app,
                String(
                    localized: "\(usage.app.name) is using your hotspot's data",
                    bundle: .strings,
                    comment: "Alert title; the app's name"
                ),
                String(localized: "\(amount) in the last 10 minutes. Quit or pause it if it can wait for Wi-Fi.", bundle: .strings)
            )
        }
    }

    /// What an out-of-the-ordinary figure must reach to be worth a notification: 5% of the
    /// processor, 1.5 GB of memory, a watt.
    static func alertFloor(_ metric: Metric) -> Double {
        switch metric {
        case .memory: 1_500_000_000
        case .energy: 1000
        default: 5
        }
    }

    struct Candidate {
        let rule: AlertRule
        let app: AppIdentity
        let title: String
        let body: String
    }

    /// Hotspot data (D-136), low disk space, a hot Mac, a lost connection (D-149).
    static func macAlerts(_ inputs: SystemAlertInputs, settings: AlertSettings) -> [Candidate] {
        var alerts = hotspotAlerts(inputs.hotspotUsage, threshold: settings.settings(for: .hotspotData).threshold).map {
            Candidate(rule: .hotspotData, app: $0.app, title: $0.title, body: $0.body)
        }
        if let free = inputs.diskFreeBytes, Double(free) < settings.settings(for: .diskLow).threshold {
            let amount = Formatters.bytes(free)
            alerts.append(Candidate(
                rule: .diskLow, app: diskIdentity(inputs.diskName),
                title: String(localized: "\(inputs.diskName) is almost full", bundle: .strings, comment: "Alert title; the disk's name"),
                body: String(localized: "\(amount) free. Storage → Clean Up shows what you can get back.", bundle: .strings)
            ))
        }
        if let minutes = inputs.hotMinutes, minutes >= settings.settings(for: .overheating).threshold {
            let count = Int(minutes.rounded())
            alerts.append(Candidate(
                rule: .overheating, app: heatIdentity,
                title: String(localized: "Your Mac is running hot", bundle: .strings),
                body: inputs.hotBusiest.map {
                    String(localized: "Slowed down to cool for \(count) of the last 10 minutes. Working hardest: \($0).", bundle: .strings)
                } ?? String(localized: "Slowed down to cool for \(count) of the last 10 minutes.", bundle: .strings)
            ))
        }
        if let offline = inputs.offlineFor, offline >= settings.settings(for: .connectionLost).threshold {
            alerts.append(Candidate(
                rule: .connectionLost, app: connectionIdentity,
                title: String(localized: "Your Mac lost its connection", bundle: .strings),
                body: String(localized: "No network for a minute or more. Check Wi-Fi or the cable.", bundle: .strings)
            ))
        }
        alerts += inputs.runaways.map(runawayAlert)
        alerts += budgetAlerts(inputs.dataBudget, warnAt: settings.settings(for: .dataBudget).threshold)
        alerts += inputs.startupAdditions.map { addition in
            Candidate(
                rule: .newStartupItem,
                app: AppIdentity(id: "startup:\(addition.label)", name: addition.name, bundleID: nil, iconKey: "other", kind: .other),
                title: String(
                    localized: "\(addition.name) now starts with your Mac",
                    bundle: .strings,
                    comment: "Alert title: an app or item's name"
                ),
                body: String(
                    localized: "It added \(addition.what) (\(addition.label)). Startup shows it, and can turn it off.",
                    bundle: .strings,
                    comment: "New startup item alert: what was added, e.g. an agent that runs at login, then its launchd label"
                )
            )
        }
        alerts += unusualAlerts(inputs.unusual, threshold: settings.settings(for: .outOfTheOrdinary).threshold)
        alerts += softwareAlerts(inputs.urgentSoftware)
        return alerts
    }

    /// One alert per app at `threshold` times its usual or more, about its most unusual figure;
    /// an app that's usually idle always counts (D-201).
    static func unusualAlerts(_ unusual: [UnusualUsage], threshold: Double) -> [Candidate] {
        var seen = Set<AppIdentity.ID>()
        return unusual
            .filter { usage in usage.ratio.map { $0 >= threshold } ?? true }
            // A notification needs a figure worth an interruption, not just a big multiple of a
            // small one: the first one seen was Safari at 347 mW, "4× its usual 80 mW" (D-218).
            .filter { $0.today >= alertFloor($0.metric) }
            .sorted { Baselines.score($0) > Baselines.score($1) }
            .filter { seen.insert($0.app.id).inserted }
            .map { usage in
                let detail = UnusualText.detail(usage)
                return Candidate(
                    rule: .outOfTheOrdinary, app: usage.app,
                    title: String(
                        localized: "\(usage.app.name) is out of the ordinary today",
                        bundle: .strings,
                        comment: "Alert title; the app's name. It's doing far more than it usually does on this Mac."
                    ),
                    body: String(
                        localized: "\(detail). Overview shows what else stands out.",
                        bundle: .strings,
                        comment: "Alert body; the detail is like “5.5 GB of memory today, 4× its usual 1.3 GB”"
                    )
                )
            }
    }

    /// "node is stuck at full speed" / "node's memory keeps climbing", with where it runs.
    static func runawayAlert(_ report: RunawayReport) -> Candidate {
        let name = report.finding.name
        let place = switch (report.project, report.agent) {
        case let (project?, agent?):
            String(
                localized: "It runs in \(project), started by \(agent).",
                bundle: .strings,
                comment: "Runaway alert: project, then agent"
            )
        case let (project?, nil):
            String(localized: "It runs in \(project).", bundle: .strings, comment: "Runaway alert: the project folder")
        case let (nil, agent?):
            String(localized: "\(agent) started it.", bundle: .strings, comment: "Runaway alert: the AI agent that started it")
        case (nil, nil):
            ""
        }
        let stop = String(localized: "Quit it from the CPU tab if it isn't meant to be busy.", bundle: .strings)
        switch report.finding.kind {
        case let .stuck(seconds):
            let minutes = Int((seconds / 60).rounded())
            return Candidate(
                rule: .runawayProcess, app: report.app,
                title: String(
                    localized: "\(name) is stuck at full speed",
                    bundle: .strings,
                    comment: "Alert title; a process name like node"
                ),
                body: [String(localized: "A full core for \(minutes) minutes.", bundle: .strings), place, stop]
                    .filter { !$0.isEmpty }.joined(separator: " ")
            )
        case let .leaking(bytes, grewBy):
            let now = Formatters.memory(bytes)
            let grew = Formatters.memory(grewBy)
            return Candidate(
                rule: .runawayProcess, app: report.app,
                title: String(
                    localized: "\(name)'s memory keeps climbing",
                    bundle: .strings,
                    comment: "Alert title; a process name like node"
                ),
                body: [String(localized: "Now \(now), up \(grew) in 30 minutes.", bundle: .strings), place, stop]
                    .filter { !$0.isEmpty }.joined(separator: " ")
            )
        }
    }

    static let heatIdentity = AppIdentity(id: "mac:heat", name: "Mac", bundleID: nil, iconKey: "other", kind: .other)
    static let connectionIdentity = AppIdentity(id: "mac:network", name: "Mac", bundleID: nil, iconKey: "other", kind: .other)

    /// Pseudo-apps, so muting, the alert log and cooldowns work per accessory and per disk.
    public static func deviceIdentity(_ device: PeripheralBattery) -> AppIdentity {
        AppIdentity(id: "device:\(device.id)", name: device.name, bundleID: nil, iconKey: "other", kind: .other)
    }

    static func diskIdentity(_ name: String) -> AppIdentity {
        AppIdentity(id: "mac:disk", name: name, bundleID: nil, iconKey: "other", kind: .other)
    }

    static let sleepIdentity = AppIdentity(id: "mac:sleep", name: "Mac", bundleID: nil, iconKey: "other", kind: .other)
}

extension AlertMonitor {
    /// The Mac-level rules, every 10 minutes (D-099).
    public func checkSystem(_ inputs: SystemAlertInputs, now: Date = Date()) async {
        await runSystemRules(inputs, now: now)
    }
}

/// The overheating rule fed from the snapshot stream (D-149): asks for a check at most once a
/// minute, and only while the Mac has been hot for the rule's minutes.
public struct HeatCheck: Sendable {
    private var watch = HeatWatch()
    private var checkedAt = Date.distantPast

    public init() {}

    public mutating func consider(_ snapshot: Snapshot, threshold: Double) -> SystemAlertInputs? {
        let minutes = watch.record(snapshot.system.thermal, at: snapshot.at)
        guard minutes >= threshold, snapshot.at.timeIntervalSince(checkedAt) >= 60 || snapshot.at < checkedAt else {
            return nil
        }
        checkedAt = snapshot.at
        return SystemAlertInputs(hotMinutes: minutes, hotBusiest: HeatWatch.busiest(snapshot))
    }
}
