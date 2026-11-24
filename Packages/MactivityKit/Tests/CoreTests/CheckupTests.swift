@testable import Core
import Foundation
import Testing

@Suite("Checkup (D-101)")
struct CheckupTests {
    @Test("Nothing wrong: nothing to say")
    func allClear() {
        var inputs = CheckupInputs()
        inputs.diskFreeBytes = 400_000_000_000
        inputs.diskTotalBytes = 1_000_000_000_000
        inputs.batteryHealthPercent = 95
        #expect(Checkup.items(inputs).isEmpty)
    }

    @Test("Attention first: an almost full disk before an idle server")
    func order() {
        var inputs = CheckupInputs()
        inputs.idleServers = 2
        inputs.idleServersMemory = 1_200_000_000
        inputs.diskFreeBytes = 15_000_000_000
        inputs.diskTotalBytes = 1_000_000_000_000
        let items = Checkup.items(inputs)
        #expect(items.map(\.id) == ["disk", "projects"])
        #expect(items.first?.severity == .attention)
    }

    @Test("A full disk names what Clean Up can get back, from 1 GB")
    func diskReclaimable() {
        var inputs = CheckupInputs()
        inputs.diskFreeBytes = 15_000_000_000
        inputs.diskTotalBytes = 1_000_000_000_000
        #expect(Checkup.items(inputs).first?.detail.contains("Storage shows") == true)
        inputs.reclaimableBytes = 400_000_000
        #expect(Checkup.items(inputs).first?.detail.contains("Storage shows") == true)
        inputs.reclaimableBytes = 12_000_000_000
        let detail = Checkup.items(inputs).first?.detail ?? ""
        #expect(detail.contains("Clean Up can get back"))
        #expect(detail.contains(Formatters.bytes(UInt64(12_000_000_000))))
    }

    @Test("A gap after a restart, only when Mactivity doesn't open at login and opened 10+ minutes late")
    func loginGap() {
        let boot = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Checkup.missedAfterRestart(bootedAt: boot, launchedAt: boot + 300, opensAtLogin: false) == nil)
        #expect(Checkup.missedAfterRestart(bootedAt: boot, launchedAt: boot + 2 * 86400, opensAtLogin: true) == nil)
        let missed = Checkup.missedAfterRestart(bootedAt: boot, launchedAt: boot + 2 * 86400, opensAtLogin: false)
        #expect(missed == TimeInterval(2 * 86400))

        var inputs = CheckupInputs()
        #expect(Checkup.items(inputs).isEmpty)
        inputs.missedAfterRestart = missed
        let item = Checkup.items(inputs).first
        #expect(item?.area == .login)
        #expect(item?.severity == .suggestion)
        #expect(item?.title.contains("2 days") == true)
    }

    @Test("A disk filling within 30 days is worth knowing; within 14, worth doing")
    func forecast() {
        var inputs = CheckupInputs()
        inputs.diskDaysUntilFull = 25
        #expect(Checkup.items(inputs).first?.severity == .suggestion)
        inputs.diskDaysUntilFull = 10
        #expect(Checkup.items(inputs).first?.severity == .attention)
        inputs.diskDaysUntilFull = 60
        #expect(Checkup.items(inputs).isEmpty)
    }

    @Test("Battery below 80% needs attention; a forecast within a year is worth knowing")
    func battery() {
        var inputs = CheckupInputs()
        inputs.batteryHealthPercent = 78
        #expect(Checkup.items(inputs).map(\.severity) == [.attention])
        inputs.batteryHealthPercent = 88
        inputs.batteryMonthsTo80 = 9
        #expect(Checkup.items(inputs).map(\.id) == ["battery"])
        inputs.batteryMonthsTo80 = 30
        #expect(Checkup.items(inputs).isEmpty)
    }

    @Test("Crashes: two in a week are worth knowing, three need attention, one is noise")
    func crashes() {
        var inputs = CheckupInputs()
        inputs.crashesThisWeek = ["Xcode": 4, "Safari": 2, "Notes": 1]
        let items = Checkup.items(inputs)
        #expect(items.map(\.id) == ["crash-Xcode", "crash-Safari"])
        #expect(items.map(\.severity) == [.attention, .suggestion])
    }

    @Test("Memory: high pressure or lots of swap, naming the biggest app")
    func memory() {
        var inputs = CheckupInputs()
        inputs.memoryPressureDay = 64
        inputs.swapBytes = 1_000_000_000
        inputs.biggestMemoryApp = "Chrome"
        let item = Checkup.items(inputs).first
        #expect(item?.id == "memory")
        #expect(item?.detail.contains("Chrome") == true)
        inputs.memoryPressureDay = 30
        #expect(Checkup.items(inputs).isEmpty)
    }

    @Test("Sleep: a night awake, and what holds it awake now (not display-only holds)")
    func sleep() {
        var inputs = CheckupInputs()
        inputs.awakeLastNight = true
        let app = AppIdentity(id: "claude", name: "Claude", bundleID: nil, iconKey: "other", kind: .other)
        inputs.sleepBlockers = [
            SleepBlocker(id: "1", pid: 1, app: app, reason: "Electron", keeps: .system, since: nil),
            SleepBlocker(id: "2", pid: 2, app: .other(executableName: "IINA"), reason: "Video", keeps: .display, since: nil),
        ]
        let items = Checkup.items(inputs)
        #expect(items.map(\.id) == ["sleep-night", "sleep-now"])
        #expect(items.last?.title.contains("Claude") == true)
        #expect(items.last?.title.contains("IINA") == false)
    }

    @Test("Sleep: macOS's own daemons aren't something to quit (D-108)")
    func sleepLeavesOutDaemons() {
        var inputs = CheckupInputs()
        let daemon = AppIdentity(id: "system:sharingd", name: "sharingd", bundleID: nil, iconKey: "system", kind: .system)
        inputs.sleepBlockers = [SleepBlocker(id: "1", pid: 1, app: daemon, reason: "Handoff", keeps: .system, since: nil)]
        #expect(Checkup.items(inputs).isEmpty)
        let claude = AppIdentity(id: "claude", name: "Claude", bundleID: nil, iconKey: "other", kind: .other)
        inputs.sleepBlockers.append(SleepBlocker(id: "2", pid: 2, app: claude, reason: "Electron", keeps: .system, since: nil))
        #expect(Checkup.items(inputs).map(\.title) == ["Keeping your Mac awake: Claude"])
    }

    @Test("Only crashes of something with a bundle count: not test helpers or compilers (D-108)")
    func appCrashes() {
        func report(_ name: String, _ bundleID: String?, _ kind: CrashReport.Kind = .crash) -> CrashReport {
            CrashReport(id: name, at: .now, appName: name, bundleID: bundleID, kind: kind, path: "/\(name).ips")
        }
        #expect(report("1Password", "com.1password.safari.extension").isAppCrash)
        #expect(!report("swiftpm-testing-helper", nil).isAppCrash)
        #expect(!report("swift-frontend", nil).isAppCrash)
        #expect(!report("Safari", "com.apple.Safari", .hang).isAppCrash)
    }

    @Test("Notifications off comes first: every alert depends on it (D-113)")
    func notifications() {
        var inputs = CheckupInputs()
        #expect(Checkup.items(inputs).isEmpty)
        inputs.notificationsOff = true
        inputs.idleServers = 1
        let items = Checkup.items(inputs)
        #expect(items.first?.id == "notifications")
        #expect(items.first?.severity == .attention)
    }

    @Test("A crash of a version since updated doesn't count (D-115)")
    func updatedSince() {
        let report = CrashReport(
            id: "m", at: .now, appName: "Mactivity", bundleID: "app.mactivity.Mactivity", kind: .crash, path: "/m.ips",
            appVersion: "0.1.0"
        )
        #expect(!report.isCurrent(installedVersion: "0.9.7"))
        #expect(report.isCurrent(installedVersion: "0.1.0"))
        #expect(report.isCurrent(installedVersion: nil))
    }

    @Test("Old Messages attachments from 1 GB, and backups over six months old (D-117)")
    func cleanup() {
        var inputs = CheckupInputs()
        inputs.oldMessagesBytes = 900_000_000
        #expect(Checkup.items(inputs).isEmpty)
        inputs.oldMessagesBytes = 6_200_000_000
        inputs.oldBackups = (48_000_000_000, Date(timeIntervalSince1970: 1_710_000_000))
        let items = Checkup.items(inputs)
        #expect(items.map(\.id) == ["messages", "backups"])
        #expect(items.allSatisfy { $0.severity == .suggestion })
    }

    @Test("A Trash over 5 GB is worth knowing (D-119)")
    func trash() {
        var inputs = CheckupInputs()
        inputs.trashBytes = 2_000_000_000
        #expect(Checkup.items(inputs).isEmpty)
        inputs.trashBytes = 14_000_000_000
        #expect(Checkup.items(inputs).map(\.id) == ["trash"])
    }

    @Test("A waiting update is named; several are counted (D-120)")
    func updates() {
        var inputs = CheckupInputs()
        inputs.pendingUpdates = [PendingUpdate(name: "macOS Tahoe", version: "26.1")]
        #expect(Checkup.items(inputs).first?.title.contains("macOS Tahoe 26.1") == true)
        inputs.pendingUpdates.append(PendingUpdate(name: "Safari", version: "26.1"))
        #expect(Checkup.items(inputs).first?.title.contains("2") == true)
    }
}
