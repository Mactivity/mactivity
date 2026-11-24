@testable import Alerts
import Core
import Foundation
import Testing

@Suite("Mac-level alerts (D-099)")
struct SystemAlertTests {
    private let now = Date(timeIntervalSince1970: 1_790_600_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private func evaluate(
        _ inputs: SystemAlertInputs, settings: AlertSettings = .defaults, state: AlertState = AlertState(), at date: Date? = nil
    ) -> AlertEvaluation {
        SystemAlertRules.evaluate(settings: settings, inputs: inputs, state: state, now: date ?? now, calendar: calendar)
    }

    private let airPods = PeripheralBattery(id: "aa", name: "AirPods Pro", kind: .airPods, percent: 12)

    @Test("An accessory at or under 15% alerts once, then not again for 12 hours")
    func accessory() {
        let first = evaluate(SystemAlertInputs(devices: [airPods]))
        #expect(first.alerts.map(\.rule) == [.accessoryBatteryLow])
        #expect(first.alerts.first?.app.id == "device:aa")
        #expect(first.alerts.first?.title.contains("AirPods Pro") == true)
        let soon = evaluate(SystemAlertInputs(devices: [airPods]), state: first.state, at: now + 3600)
        #expect(soon.alerts.isEmpty)
        let later = evaluate(SystemAlertInputs(devices: [airPods]), state: first.state, at: now + 13 * 3600)
        #expect(later.alerts.count == 1)
        let fine = PeripheralBattery(id: "m", name: "Mouse", kind: .mouse, percent: 60)
        #expect(evaluate(SystemAlertInputs(devices: [fine])).alerts.isEmpty)
    }

    @Test("The disk alerts when full within the threshold's days, not after")
    func disk() {
        #expect(evaluate(SystemAlertInputs(diskDaysUntilFull: 10)).alerts.map(\.rule) == [.diskFilling])
        #expect(evaluate(SystemAlertInputs(diskDaysUntilFull: 40)).alerts.isEmpty)
        #expect(evaluate(SystemAlertInputs(diskDaysUntilFull: nil)).alerts.isEmpty)
    }

    @Test("An app alerts at three crashes in the window")
    func crashes() {
        let xcode = AppIdentity(id: "com.apple.dt.Xcode", name: "Xcode", bundleID: "com.apple.dt.Xcode", iconKey: "/x", kind: .app)
        #expect(evaluate(SystemAlertInputs(crashes: [xcode: 3])).alerts.map(\.app.name) == ["Xcode"])
        #expect(evaluate(SystemAlertInputs(crashes: [xcode: 2])).alerts.isEmpty)
    }

    @Test("A night awake alerts, naming what's keeping it awake")
    func overnight() {
        let alert = evaluate(SystemAlertInputs(awakeOvernight: true, awakeBecause: ["Claude"])).alerts.first
        #expect(alert?.rule == .notSleeping)
        #expect(alert?.body.contains("Claude") == true)
        #expect(evaluate(SystemAlertInputs(awakeOvernight: false)).alerts.isEmpty)
        #expect(evaluate(SystemAlertInputs(awakeOvernight: nil)).alerts.isEmpty)
    }

    @Test("An app over 200 MB of hotspot data in 10 minutes alerts, then not again for an hour (D-136)")
    func hotspot() throws {
        func usage(_ bytes: Double) -> HotspotSession.Usage {
            HotspotSession.Usage(app: AppIdentity(id: "dropbox", name: "Dropbox", bundleID: nil, iconKey: "", kind: .app), bytes: bytes)
        }
        #expect(evaluate(SystemAlertInputs(hotspotUsage: [usage(150_000_000)])).alerts.isEmpty)
        let first = evaluate(SystemAlertInputs(hotspotUsage: [usage(600_000_000)]))
        let alert = try #require(first.alerts.first)
        #expect(alert.rule == .hotspotData)
        #expect(alert.title == "Dropbox is using your hotspot's data")
        let again = evaluate(SystemAlertInputs(hotspotUsage: [usage(600_000_000)]), state: first.state, at: now.addingTimeInterval(600))
        #expect(again.alerts.isEmpty)
        let later = evaluate(SystemAlertInputs(hotspotUsage: [usage(600_000_000)]), state: first.state, at: now.addingTimeInterval(3601))
        #expect(later.alerts.count == 1)
    }

    @Test("Low disk space alerts under 10 GB free, once a day (D-149)")
    func diskLow() {
        let first = evaluate(SystemAlertInputs(diskFreeBytes: 6_000_000_000))
        #expect(first.alerts.map(\.rule) == [.diskLow])
        #expect(first.alerts.first?.title.contains("Macintosh HD") == true)
        #expect(evaluate(SystemAlertInputs(diskFreeBytes: 6_000_000_000), state: first.state, at: now + 3600).alerts.isEmpty)
        #expect(evaluate(SystemAlertInputs(diskFreeBytes: 60_000_000_000)).alerts.isEmpty)
        // The filling forecast and the low-space alert are separate rules on the same disk.
        let both = evaluate(SystemAlertInputs(diskDaysUntilFull: 3, diskFreeBytes: 2_000_000_000))
        #expect(Set(both.alerts.map(\.rule)) == [.diskFilling, .diskLow])
    }

    @Test("Hot for 5 of the last 10 minutes alerts, naming the busiest app (D-149)")
    func overheating() {
        let alert = evaluate(SystemAlertInputs(hotMinutes: 6, hotBusiest: "Xcode")).alerts.first
        #expect(alert?.rule == .overheating)
        #expect(alert?.body.contains("Xcode") == true)
        #expect(evaluate(SystemAlertInputs(hotMinutes: 2)).alerts.isEmpty)
    }

    @Test("Connection lost alerts only when turned on (D-149)")
    func connectionLost() {
        #expect(evaluate(SystemAlertInputs(offlineFor: 90)).alerts.isEmpty)
        var settings = AlertSettings.defaults
        settings.rules[.connectionLost] = RuleSettings(isEnabled: true, threshold: 60, window: .zero)
        #expect(evaluate(SystemAlertInputs(offlineFor: 90), settings: settings).alerts.map(\.rule) == [.connectionLost])
        #expect(evaluate(SystemAlertInputs(offlineFor: 30), settings: settings).alerts.isEmpty)
    }

    @Test("A runaway process alerts on its app, naming its project and agent (D-156)")
    func runaway() {
        let terminal = AppIdentity(id: "com.apple.Terminal", name: "Terminal", bundleID: "com.apple.Terminal", iconKey: "/t", kind: .app)
        let finding = RunawayWatch.Finding(pid: 4, name: "node", app: terminal.id, kind: .stuck(seconds: 640))
        let report = RunawayReport(finding: finding, app: terminal, project: "storefront-web", agent: "Claude Code")
        let alert = evaluate(SystemAlertInputs(runaways: [report])).alerts.first
        #expect(alert?.rule == .runawayProcess)
        #expect(alert?.app.id == "com.apple.Terminal")
        #expect(alert?.title.contains("node") == true)
        #expect(alert?.body.contains("storefront-web") == true)
        #expect(alert?.body.contains("Claude Code") == true)
        #expect(alert?.body.contains("11 minutes") == true)
        // A second process in the same app, found later, still alerts.
        let other = RunawayReport(
            finding: RunawayWatch.Finding(
                pid: 5,
                name: "python3",
                app: terminal.id,
                kind: .leaking(bytes: 3_000_000_000, grewBy: 1_200_000_000)
            ),
            app: terminal, project: nil, agent: nil
        )
        let first = evaluate(SystemAlertInputs(runaways: [report]))
        #expect(evaluate(SystemAlertInputs(runaways: [other]), state: first.state, at: now + 60).alerts.count == 1)
    }

    @Test("An app at 4× its usual day alerts once a day, about its most unusual figure (D-201)")
    func outOfTheOrdinary() {
        let safari = AppIdentity(id: "com.apple.Safari", name: "Safari", bundleID: "com.apple.Safari", iconKey: "/s", kind: .app)
        let docker = AppIdentity(id: "com.docker.docker", name: "Docker", bundleID: nil, iconKey: "/d", kind: .app)
        let unusual = [
            UnusualUsage(app: safari, metric: .memory, today: 5.5e9, usual: 1.3e9),
            UnusualUsage(app: safari, metric: .cpu, today: 12, usual: 4),
            UnusualUsage(app: docker, metric: .cpu, today: 18, usual: 0),
        ]
        let first = evaluate(SystemAlertInputs(unusual: unusual))
        #expect(first.alerts.map(\.rule) == [.outOfTheOrdinary, .outOfTheOrdinary])
        #expect(Set(first.alerts.map(\.app.name)) == ["Safari", "Docker"])
        let safariAlert = first.alerts.first { $0.app.id == safari.id }
        #expect(safariAlert?.title.contains("Safari") == true)
        #expect(safariAlert?.body.contains("memory") == true, "the bigger multiple, not the processor's 3×")
        #expect(evaluate(SystemAlertInputs(unusual: unusual), state: first.state, at: now + 6 * 3600).alerts.isEmpty)
        #expect(evaluate(SystemAlertInputs(unusual: unusual), state: first.state, at: now + 21 * 3600).alerts.count == 2)
        // 4× a tiny usual isn't worth a notification: Safari at 347 mW, usually 80 mW (D-218).
        #expect(evaluate(SystemAlertInputs(unusual: [UnusualUsage(app: safari, metric: .energy, today: 347, usual: 80)])).alerts.isEmpty)
        // 3× stands out on Overview but is under the alert's 4×.
        #expect(evaluate(SystemAlertInputs(unusual: [unusual[1]])).alerts.isEmpty)
        var off = AlertSettings.defaults
        off.rules[.outOfTheOrdinary]?.isEnabled = false
        #expect(evaluate(SystemAlertInputs(unusual: unusual), settings: off).alerts.isEmpty)
    }

    @Test("Turned off, muted, or in quiet hours: nothing")
    func gating() {
        var off = AlertSettings.defaults
        off.rules[.accessoryBatteryLow]?.isEnabled = false
        #expect(evaluate(SystemAlertInputs(devices: [airPods]), settings: off).alerts.isEmpty)
        var muted = AlertSettings.defaults
        muted.mutedAppIDs = ["device:aa"]
        #expect(evaluate(SystemAlertInputs(devices: [airPods]), settings: muted).alerts.isEmpty)
        var quiet = AlertSettings.defaults
        quiet.quietHours = QuietHours(startMinute: 0, endMinute: 23 * 60 + 59)
        #expect(evaluate(SystemAlertInputs(devices: [airPods]), settings: quiet).alerts.isEmpty)
    }

    @Test("The snapshot engine keeps only the per-app rules' windows")
    func appRulesOnly() {
        #expect(AlertRule.appRules + AlertRule.systemRules == AlertRule.allCases)
        #expect(AlertRule.allCases.filter(\.isPerApp) == AlertRule.appRules)
    }

    private func session(_ pid: Int32, hours: Double, memory: UInt64) -> AgentSession {
        AgentSession(
            pid: pid, agent: "Claude Code", project: "mactivity", directory: "/Users/a/Developer/mactivity", host: "Terminal",
            startedAt: now - hours * 3600, processCount: 4, cpuPercent: 3, memoryBytes: memory, busiestChildren: ["node", "swift-frontend"],
            stopTargets: []
        )
    }

    @Test("Agent memory past the limit alerts once per session; a long session only once it's turned on (D-227)")
    func agentLimits() {
        let gb: UInt64 = 1_073_741_824
        let heavy = session(500, hours: 5, memory: 9 * gb)
        let first = evaluate(SystemAlertInputs(agentSessions: [heavy]))
        // Long sessions are off by default; memory is on at 8 GB.
        #expect(first.alerts.map(\.rule) == [.agentMemory])
        #expect(first.alerts.first?.title.contains("Claude Code") == true)
        #expect(first.alerts.first?.body.contains("mactivity") == true)
        // The same session doesn't alert again, a minute or a day later.
        #expect(evaluate(SystemAlertInputs(agentSessions: [heavy]), state: first.state, at: now + 86400).alerts.isEmpty)
        // Another session does.
        #expect(evaluate(SystemAlertInputs(agentSessions: [session(501, hours: 1, memory: 9 * gb)]), state: first.state).alerts.count == 1)
        #expect(evaluate(SystemAlertInputs(agentSessions: [session(502, hours: 1, memory: 2 * gb)])).alerts.isEmpty)

        var settings = AlertSettings.defaults
        settings.rules[.agentLongSession] = RuleSettings(isEnabled: true, threshold: 4, window: .zero)
        let long = evaluate(SystemAlertInputs(agentSessions: [session(503, hours: 4.5, memory: gb)]), settings: settings)
        #expect(long.alerts.map(\.rule) == [.agentLongSession])
        #expect(long.alerts.first?.title.contains("4h 30m") == true)
        #expect(evaluate(SystemAlertInputs(agentSessions: [session(504, hours: 3, memory: gb)]), settings: settings).alerts.isEmpty)
    }

    @Test("A new startup item alerts once, naming the app and what it added (D-231)")
    func newStartupItem() {
        let addition = StartupAddition(label: "com.google.keystone.agent", name: "Google Chrome", what: "an agent that runs at login")
        let first = evaluate(SystemAlertInputs(startupAdditions: [addition]))
        #expect(first.alerts.map(\.rule) == [.newStartupItem])
        #expect(first.alerts.first?.title.contains("Google Chrome") == true)
        #expect(first.alerts.first?.body.contains("com.google.keystone.agent") == true)
        #expect(evaluate(SystemAlertInputs(startupAdditions: [addition]), state: first.state, at: now + 3600).alerts.isEmpty)
    }

    @Test("Software needing security updates alerts once per package and version (D-252)")
    func vulnerableSoftware() {
        let openssl = InstalledSoftware(
            name: "openssl@3", version: "3.5.1", origin: .homebrew,
            vulnerabilities: [Vulnerability(id: "CVE-2026-54873", severity: .high, summary: "")]
        )
        let php = InstalledSoftware(name: "php@8.1", version: "8.1.34", origin: .homebrew, runtime: Runtime(kind: .php, cycle: "8.1"))
        var inputs = SystemAlertInputs()
        inputs.urgentSoftware = [(openssl, .vulnerable(.high)), (php, .unsupported(since: now - 86400))]
        let first = evaluate(inputs)
        #expect(first.alerts.map(\.rule) == [.vulnerableSoftware, .vulnerableSoftware])
        #expect(first.alerts.first?.title.contains("openssl@3") == true)
        #expect(first.alerts.first?.body.contains("CVE-2026-54873") == true)
        #expect(first.alerts.last?.title.contains("PHP 8.1") == true)
        #expect(evaluate(inputs, state: first.state, at: now + 86400).alerts.isEmpty)
        // A newer version, still vulnerable, is news.
        let newer = InstalledSoftware(
            name: "openssl@3", version: "3.5.2", origin: .homebrew,
            vulnerabilities: [Vulnerability(id: "CVE-2026-99999", severity: .critical, summary: "")]
        )
        inputs.urgentSoftware = [(newer, .vulnerable(.critical))]
        #expect(evaluate(inputs, state: first.state, at: now + 86400).alerts.count == 1)
    }

    @Test("The data budget warns at its share, once a period, and again when it's used (D-235)")
    func dataBudget() {
        let budget = DataBudget(allowance: 100e9, resetDay: 1)
        let period = DateInterval(start: now - 10 * 86400, duration: 30 * 86400)
        let under = DataBudgetStatus(budget: budget, period: period, used: 50e9, now: now)
        #expect(evaluate(SystemAlertInputs(dataBudget: under)).alerts.isEmpty)
        let near = DataBudgetStatus(budget: budget, period: period, used: 82e9, now: now)
        let warned = evaluate(SystemAlertInputs(dataBudget: near))
        #expect(warned.alerts.map(\.rule) == [.dataBudget])
        #expect(warned.alerts.first?.title.contains("82") == true)
        #expect(evaluate(SystemAlertInputs(dataBudget: near), state: warned.state, at: now + 3600).alerts.isEmpty)
        let over = DataBudgetStatus(budget: budget, period: period, used: 101e9, now: now + 7200)
        let used = evaluate(SystemAlertInputs(dataBudget: over), state: warned.state, at: now + 7200)
        #expect(used.alerts.first?.title.contains("used your data budget") == true)
    }
}
