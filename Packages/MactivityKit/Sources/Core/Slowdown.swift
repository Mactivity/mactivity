import Foundation

/// "Why is my Mac slow?" (D-134): a few seconds of snapshots, read as plain causes, most
/// important first, each with what to do. Pure: the UI takes the snapshots (with macOS's own
/// processes read, so Spotlight and Time Machine show) and acts on the result.
public struct SlowdownCause: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case busyCPU, busyApp, memory, swap, heat, diskFull, diskBusy, gpu, lowPower
        case spotlight, timeMachine, photos, iCloud, softwareUpdate, malwareScan, windowServer
        /// Apps open for days without use, when memory is short (D-135).
        case unusedApps
    }

    /// Slowing the Mac now, or just worth knowing.
    public enum Severity: Int, Hashable, Sendable, Comparable {
        case major = 0
        case minor = 1

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// What the cause's button does.
    public enum Action: Hashable, Sendable {
        /// Quit this app, through the usual confirmation.
        case quit(AppIdentity)
        /// Show a tab of the main window.
        case show(Destination)
        /// Open the list of apps open but unused (D-135).
        case showUnusedApps
        /// Nothing to press: it passes on its own.
        case none
    }

    public enum Destination: String, Hashable, Sendable {
        case cpu, memory, disk, storage, gpu, battery
    }

    public var id: String {
        kind.rawValue + (app.map { ":" + $0.id } ?? "")
    }

    public let kind: Kind
    public let severity: Severity
    public let title: String
    public let detail: String
    public let app: AppIdentity?
    public let action: Action

    public init(kind: Kind, severity: Severity, title: String, detail: String, app: AppIdentity? = nil, action: Action = .none) {
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.app = app
        self.action = action
    }
}

public enum Slowdown {
    /// The whole Mac's CPU at which it's busy enough to feel slow.
    static let busyCPUPercent = 70.0
    /// One app using this many cores' worth is worth naming even when the Mac copes.
    static let busyAppCores = 1.5
    static let busyDiskBPS = 150_000_000.0
    static let busyGPUPercent = 90.0
    /// A background job of macOS's (Spotlight, Time Machine…) counts from a third of a core.
    static let backgroundCores = 0.33

    /// macOS processes that are well-known background jobs, by process name.
    static let backgroundJobs: [(kind: SlowdownCause.Kind, names: Set<String>)] = [
        (.spotlight, ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "corespotlightd"]),
        (.timeMachine, ["backupd", "backupd-helper"]),
        (.photos, ["photoanalysisd", "mediaanalysisd", "photolibraryd"]),
        (.iCloud, ["bird", "cloudd", "fileproviderd", "nsurlsessiond"]),
        (.softwareUpdate, ["softwareupdated", "installd", "system_installd", "mobileassetd"]),
        (.malwareScan, ["XProtect", "XprotectService", "syspolicyd"]),
        (.windowServer, ["WindowServer"]),
    ]

    /// - Parameters:
    ///   - snapshots: a few seconds of them, oldest first. Figures are averaged across them.
    ///   - lowPowerMode: `ProcessInfo.isLowPowerModeEnabled`.
    ///   - unused: apps open but unused (D-135); named when memory is short.
    public static func diagnose(_ snapshots: [Snapshot], lowPowerMode: Bool, unused: [UnusedApp] = []) -> [SlowdownCause] {
        guard let window = Window(snapshots) else {
            return []
        }
        var causes: [SlowdownCause] = []
        causes += heat(window)
        let memory = memory(window)
        causes += memory
        let unusedBytes = unused.reduce(0) { $0 + $1.memoryBytes }
        if !memory.isEmpty, unusedBytes >= 1_000_000_000 {
            let names = names(unused.prefix(3).map(\.app))
            let size = Formatters.memory(unusedBytes)
            causes.append(SlowdownCause(
                kind: .unusedApps, severity: .minor,
                title: String(localized: "Open but unused for days: \(names)", bundle: .strings),
                detail: String(localized: "Together they hold \(size) of memory. Quitting frees it.", bundle: .strings),
                action: .showUnusedApps
            ))
        }
        causes += processor(window)
        causes += backgroundJobs(window)
        causes += disk(window)
        causes += graphics(window)
        if lowPowerMode {
            causes.append(SlowdownCause(
                kind: .lowPower, severity: .minor,
                title: String(localized: "Low Power Mode is on", bundle: .strings),
                detail: String(localized: "macOS runs slower to save battery. System Settings → Battery turns it off.", bundle: .strings),
                action: .show(.battery)
            ))
        }
        return causes.enumerated()
            .sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }
            .map(\.element)
    }

    /// The snapshots' figures, averaged: each app present in only some counts zero for the rest.
    struct Window {
        let snapshots: [Snapshot]
        let last: Snapshot
        let cores: Double
        var appCPU: [AppIdentity.ID: Double] = [:]
        var appDisk: [AppIdentity.ID: Double] = [:]
        var appGPU: [AppIdentity.ID: Double] = [:]
        var identities: [AppIdentity.ID: AppIdentity] = [:]

        init?(_ snapshots: [Snapshot]) {
            guard let last = snapshots.last else {
                return nil
            }
            self.snapshots = snapshots
            self.last = last
            cores = Double(max(1, last.system.cpu.perCorePercent.count))
            let count = Double(snapshots.count)
            for snapshot in snapshots {
                for app in snapshot.apps {
                    identities[app.id] = app.app
                    appCPU[app.id, default: 0] += app.cpuPercent / count
                    appDisk[app.id, default: 0] += (app.diskReadBPS + app.diskWriteBPS) / count
                    appGPU[app.id, default: 0] += (app.gpuPercent ?? 0) / count
                }
            }
        }

        func average(_ value: (Snapshot) -> Double) -> Double {
            snapshots.reduce(0) { $0 + value($1) } / Double(snapshots.count)
        }

        var totalCPU: Double {
            average { $0.system.cpu.totalPercent }
        }

        /// The apps (not macOS) with the most of a figure.
        func top(_ values: [AppIdentity.ID: Double], limit: Int = 3) -> [AppIdentity] {
            values.filter { identities[$0.key]?.kind != .system && $0.value > 0 }
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .compactMap { identities[$0.key] }
        }
    }

    private static func names(_ list: [AppIdentity]) -> String {
        list.map(\.name).formatted(.list(type: .and))
    }

    static func heat(_ window: Window) -> [SlowdownCause] {
        guard window.last.system.thermal >= .serious else {
            return []
        }
        let culprits = window.top(window.appCPU)
        return [SlowdownCause(
            kind: .heat, severity: .major,
            title: String(localized: "Your Mac is hot, and slowing itself down to cool", bundle: .strings),
            detail: culprits.isEmpty
                ? String(localized: "Give it air, and close what you don't need until it cools.", bundle: .strings)
                : String(localized: "Working hardest: \(names(culprits)). Quit what you don't need until it cools.", bundle: .strings),
            action: .show(.cpu)
        )]
    }

    static func memory(_ window: Window) -> [SlowdownCause] {
        let memory = window.last.system.memory
        if memory.pressure != .normal {
            let culprits = window.last.apps.filter { $0.app.kind != .system }
                .sorted { $0.memoryBytes > $1.memoryBytes }.prefix(3).map(\.app)
            return [SlowdownCause(
                kind: .memory, severity: .major,
                title: String(localized: "Memory is running short", bundle: .strings),
                detail: String(
                    localized: "macOS is compressing memory and using the disk instead. Using the most: \(names(culprits)).",
                    bundle: .strings
                ),
                action: .show(.memory)
            )]
        }
        guard memory.swapUsedBytes >= 4_000_000_000 else {
            return []
        }
        let swap = Formatters.memory(memory.swapUsedBytes)
        return [SlowdownCause(
            kind: .swap, severity: .minor,
            title: String(localized: "\(swap) of memory is on the disk", bundle: .strings),
            detail: String(localized: "Memory ran short earlier. Apps that come back to it may pause for a moment.", bundle: .strings),
            action: .show(.memory)
        )]
    }

    /// The whole processor, then each app using several cores, so each can be quit.
    static func processor(_ window: Window) -> [SlowdownCause] {
        var causes: [SlowdownCause] = []
        let total = window.totalCPU
        let busy = total >= busyCPUPercent
        if busy {
            let culprits = window.top(window.appCPU)
            let percent = Int(total.rounded())
            causes.append(SlowdownCause(
                kind: .busyCPU, severity: .major,
                title: String(localized: "The processor is \(percent)% busy", bundle: .strings),
                detail: culprits.isEmpty
                    ? String(localized: "Most of it is macOS's own work. CPU shows which part.", bundle: .strings)
                    : String(localized: "Using the most: \(names(culprits)).", bundle: .strings),
                action: .show(.cpu)
            ))
        }
        for (id, percent) in window.appCPU.sorted(by: { $0.value > $1.value }) {
            guard let app = window.identities[id], app.kind != .system else {
                continue
            }
            let used = percent / 100 * window.cores
            guard used >= busyAppCores else {
                break
            }
            let coresText = used.formatted(.number.precision(.fractionLength(1)))
            causes.append(SlowdownCause(
                kind: .busyApp, severity: busy ? .major : .minor,
                title: String(localized: "\(app.name) is using \(coresText) cores", bundle: .strings),
                detail: String(localized: "If it isn't doing something you asked for, quitting it frees them.", bundle: .strings),
                app: app,
                action: .quit(app)
            ))
        }
        return causes
    }

    /// macOS's own background jobs, from its processes (read in full for the diagnosis).
    static func backgroundJobs(_ window: Window) -> [SlowdownCause] {
        var jobCPU: [SlowdownCause.Kind: Double] = [:]
        let count = Double(window.snapshots.count)
        for snapshot in window.snapshots {
            for process in snapshot.processes where snapshot.systemPIDs.contains(process.pid) {
                if let job = backgroundJobs.first(where: { $0.names.contains(process.name) }) {
                    jobCPU[job.kind, default: 0] += process.cpuPercent / 100 * window.cores / count
                }
            }
        }
        let busy = window.totalCPU >= busyCPUPercent
        return backgroundJobs.map(\.kind)
            .filter { (jobCPU[$0] ?? 0) >= backgroundCores }
            .map { backgroundCause($0, busy: busy) }
    }

    static func disk(_ window: Window) -> [SlowdownCause] {
        var causes: [SlowdownCause] = []
        if let boot = window.last.system.disk.bootVolume, boot.totalBytes > 0,
           Double(boot.freeBytes) / Double(boot.totalBytes) < 0.05 || boot.freeBytes < 10_000_000_000 {
            let free = Formatters.bytes(boot.freeBytes)
            causes.append(SlowdownCause(
                kind: .diskFull, severity: .major,
                title: String(localized: "The startup disk is almost full: \(free) free", bundle: .strings),
                detail: String(
                    localized: "macOS needs free space to work. Storage → Clean Up shows what you can get back.",
                    bundle: .strings
                ),
                action: .show(.storage)
            ))
        }
        let rate = window.average { $0.system.disk.readBPS + $0.system.disk.writeBPS }
        if rate >= busyDiskBPS {
            let culprits = window.top(window.appDisk)
            let text = Formatters.rate(rate)
            causes.append(SlowdownCause(
                kind: .diskBusy, severity: .minor,
                title: String(localized: "The disk is busy: \(text)", bundle: .strings),
                detail: culprits.isEmpty
                    ? String(localized: "Apps that open files may wait their turn.", bundle: .strings)
                    : String(localized: "Reading and writing the most: \(names(culprits)).", bundle: .strings),
                action: .show(.disk)
            ))
        }
        return causes
    }

    static func graphics(_ window: Window) -> [SlowdownCause] {
        guard let gpu = window.last.system.gpu, window.average({ $0.system.gpu?.utilizationPercent ?? 0 }) >= busyGPUPercent else {
            return []
        }
        let culprits = window.top(window.appGPU)
        return [SlowdownCause(
            kind: .gpu, severity: .major,
            title: String(localized: "The graphics processor is busy", bundle: .strings),
            detail: culprits.isEmpty
                ? String(localized: "\(gpu.name) is near its limit, so animations and video may stutter.", bundle: .strings)
                : String(localized: "Using it the most: \(names(culprits)).", bundle: .strings),
            action: .show(.gpu)
        )]
    }

    private static func backgroundCause(_ kind: SlowdownCause.Kind, busy: Bool) -> SlowdownCause {
        let severity: SlowdownCause.Severity = busy ? .major : .minor
        let (title, detail): (String, String) = switch kind {
        case .spotlight: (
                String(localized: "Spotlight is indexing", bundle: .strings),
                String(localized: "It catches up after updates and new files, then stops on its own.", bundle: .strings)
            )
        case .timeMachine: (
                String(localized: "Time Machine is backing up", bundle: .strings),
                String(localized: "It finishes on its own. Big changes since the last backup take longer.", bundle: .strings)
            )
        case .photos: (
                String(localized: "Photos is analyzing your library", bundle: .strings),
                String(localized: "It finds faces and scenes, mostly while the Mac is plugged in and idle.", bundle: .strings)
            )
        case .iCloud: (
                String(localized: "iCloud is syncing", bundle: .strings),
                String(localized: "Files are uploading or downloading. It slows down once they're done.", bundle: .strings)
            )
        case .softwareUpdate: (
                String(localized: "macOS is preparing an update", bundle: .strings),
                String(localized: "It downloads and prepares in the background, then asks before installing.", bundle: .strings)
            )
        case .malwareScan: (
                String(localized: "macOS is checking apps for malware", bundle: .strings),
                String(localized: "It runs after new apps or an XProtect update, and stops on its own.", bundle: .strings)
            )
        case .windowServer: (
                String(localized: "The display server is busy", bundle: .strings),
                String(localized: "Many windows, displays, or animations keep it working. Closing some helps.", bundle: .strings)
            )
        case .busyCPU, .busyApp, .memory, .swap, .heat, .diskFull, .diskBusy, .gpu, .lowPower, .unusedApps: ("", "")
        }
        return SlowdownCause(kind: kind, severity: severity, title: title, detail: detail)
    }
}
