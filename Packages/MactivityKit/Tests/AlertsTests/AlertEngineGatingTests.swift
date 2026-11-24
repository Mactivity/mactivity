@testable import Alerts
import Core
import Foundation
import Testing

/// A CPU hog at `now`: 10 minutes at 100%.
private func hog(_ app: AppIdentity = Fixture.app, now: Date = Fixture.now) -> AppActivityHistory {
    AppActivityHistory(app: app, points: Fixture.points(minutes: 10, now: now) { _, _ in .init(cpu: 100) })
}

private func fired(
    _ settings: AlertSettings = Fixture.only(.highCPU),
    _ activity: [AppActivityHistory] = [hog()],
    state: AlertState = AlertState(),
    context: AlertContext = Fixture.context()
) -> AlertEvaluation {
    AlertEngine.evaluate(settings: settings, activity: activity, state: state, context: context)
}

/// `Fixture.now`'s day at hour:minute UTC.
private func at(_ hour: Int, _ minute: Int) -> Date {
    Fixture.now.addingTimeInterval(TimeInterval((hour - 12) * 3600 + minute * 60))
}

@Suite("Alert engine: cooldown and state")
struct CooldownTests {
    let key = AlertKey(appID: Fixture.app.id, rule: .highCPU)

    @Test("Firing records now as the last fire time")
    func recordsLastFired() {
        let result = fired()
        #expect(result.state.lastFired == [key: Fixture.now])
    }

    @Test("Nothing fires inside the cooldown, and the state is unchanged")
    func insideCooldown() {
        let state = AlertState(lastFired: [key: Fixture.now.addingTimeInterval(-59 * 60)])
        let result = fired(state: state)
        #expect(result.alerts.isEmpty)
        #expect(result.state == state)
    }

    @Test("Fires again once the cooldown has passed")
    func afterCooldown() {
        let state = AlertState(lastFired: [key: Fixture.now.addingTimeInterval(-60 * 60)])
        let result = fired(state: state)
        #expect(result.alerts.count == 1)
        #expect(result.state.lastFired[key] == Fixture.now)
    }

    @Test("The cooldown length comes from the settings")
    func customCooldown() {
        var settings = Fixture.only(.highCPU)
        settings.cooldown = .seconds(5 * 60)
        let state = AlertState(lastFired: [key: Fixture.now.addingTimeInterval(-6 * 60)])
        #expect(fired(settings, state: state).alerts.count == 1)
    }

    @Test("Cooldowns are per app and per rule")
    func perKey() {
        let state = AlertState(lastFired: [
            AlertKey(appID: Fixture.app.id, rule: .heavyDisk): Fixture.now,
            AlertKey(appID: Fixture.other.id, rule: .highCPU): Fixture.now,
        ])
        let result = fired(state: state)
        #expect(result.alerts.count == 1)
        #expect(result.state.lastFired.count == 3)
    }
}

@Suite("Alert engine: who gets watched")
struct EligibilityTests {
    @Test("Muted apps are skipped; others still fire")
    func muted() {
        var settings = Fixture.only(.highCPU)
        settings.mutedAppIDs = [Fixture.app.id]
        let result = fired(settings, [hog(), hog(Fixture.other)])
        #expect(result.alerts.map(\.app) == [Fixture.other])
    }

    @Test("The frontmost app is exempt when the setting is on")
    func frontmostExempt() {
        let result = fired(context: Fixture.context(frontmost: Fixture.app.id))
        #expect(result.alerts.isEmpty)
        #expect(result.state.lastFired.isEmpty)
    }

    @Test("The frontmost app fires when the setting is off")
    func frontmostNotExempt() {
        let settings = Fixture.only(.highCPU, exemptsFrontmostApp: false)
        #expect(fired(settings, context: Fixture.context(frontmost: Fixture.app.id)).alerts.count == 1)
    }

    @Test("The exemption covers only the frontmost app")
    func otherAppFrontmost() {
        #expect(fired(context: Fixture.context(frontmost: Fixture.other.id)).alerts.count == 1)
    }

    @Test("The macOS row never alerts")
    func systemSkipped() {
        #expect(fired(Fixture.only(.highCPU), [hog(.system)]).alerts.isEmpty)
    }

    @Test("Terminals and unresolved processes do alert", arguments: [AppIdentity.Kind.terminal, .other])
    func otherKinds(kind: AppIdentity.Kind) {
        let app = AppIdentity(id: "x", name: "X", bundleID: nil, iconKey: "x", kind: kind)
        #expect(fired(Fixture.only(.highCPU), [hog(app)]).alerts.count == 1)
    }

    @Test("Disabled rules don't fire")
    func disabled() {
        var settings = AlertSettings.defaults
        settings.rules[.highCPU]?.isEnabled = false
        #expect(fired(settings).alerts.isEmpty)
    }

    @Test("Several rules can fire for one app, in rule order")
    func severalRules() {
        let points = Fixture.points(minutes: 10) { _, _ in .init(cpu: 100, disk: 100_000_000, netIn: 50_000_000) }
        let result = fired(.defaults, Fixture.history(points))
        #expect(result.alerts.map(\.rule) == [.highCPU, .heavyDisk, .heavyNetwork])
    }

    @Test("Same inputs, same outputs apart from alert IDs")
    func deterministic() {
        let activity = [hog(), hog(Fixture.other)]
        let first = fired(.defaults, activity)
        let second = fired(.defaults, activity)
        #expect(first.state == second.state)
        #expect(first.alerts.map(\.app) == [Fixture.app, Fixture.other])
        #expect(first.alerts.map(\.app) == second.alerts.map(\.app))
        #expect(first.alerts.map(\.title) == second.alerts.map(\.title))
        #expect(first.alerts.map(\.body) == second.alerts.map(\.body))
        #expect(first.alerts.map(\.firedAt) == second.alerts.map(\.firedAt))
    }
}

@Suite("Alert engine: quiet hours")
struct QuietHoursTests {
    let key = AlertKey(appID: Fixture.app.id, rule: .highCPU)

    func run(quiet: QuietHours, at now: Date, state: AlertState = AlertState()) -> AlertEvaluation {
        var settings = Fixture.only(.highCPU)
        settings.quietHours = quiet
        return fired(settings, [hog(now: now)], state: state, context: Fixture.context(now: now))
    }

    @Test("22:00–07:00 wraps midnight", arguments: [
        (22, 0, true), (23, 30, true), (0, 0, true), (6, 59, true), (7, 0, false), (12, 0, false), (21, 59, false),
    ])
    func wrapping(hour: Int, minute: Int, quiet: Bool) {
        let now = at(hour, minute)
        let result = run(quiet: QuietHours(startMinute: 22 * 60, endMinute: 7 * 60), at: now)
        #expect(result.alerts.isEmpty == quiet)
    }

    @Test("13:00–14:00 within one day", arguments: [(12, 59, false), (13, 0, true), (13, 30, true), (14, 0, false)])
    func sameDay(hour: Int, minute: Int, quiet: Bool) {
        let result = run(quiet: QuietHours(startMinute: 13 * 60, endMinute: 14 * 60), at: at(hour, minute))
        #expect(result.alerts.isEmpty == quiet)
    }

    @Test("During quiet hours the state is left alone")
    func stateUntouched() {
        let now = at(23, 30)
        let state = AlertState(lastFired: [key: now.addingTimeInterval(-2 * 3600)])
        let result = run(quiet: QuietHours(startMinute: 22 * 60, endMinute: 7 * 60), at: now, state: state)
        #expect(result.alerts.isEmpty)
        #expect(result.state == state)
    }

    @Test("Equal start and end means no quiet hours")
    func empty() {
        #expect(run(quiet: QuietHours(startMinute: 600, endMinute: 600), at: at(10, 0)).alerts.count == 1)
    }
}

@Suite("Alert text")
struct AlertTextTests {
    @Test("Window phrases", arguments: [
        (Duration.seconds(3600), "an hour"),
        (.seconds(60), "1 minute"),
        (.seconds(30), "1 minute"),
        (.seconds(300), "5 minutes"),
        (.seconds(600), "10 minutes"),
        (.seconds(7200), "120 minutes"),
    ])
    func phrases(window: Duration, expected: String) {
        #expect(AlertText.phrase(for: window) == expected)
    }

    @Test("A 60-minute CPU window reads \"for an hour\"")
    func hourCPU() {
        let text = AlertText.make(for: .highCPU(average: 84), app: Fixture.app, window: .seconds(3600))
        #expect(text.body == "Averaged \(Formatters.percent(84)) for an hour.")
    }

    @Test("Titles name the app")
    func titles() {
        let window = Duration.seconds(300)
        let findings: [(Finding, String)] = [
            (.highCPU(average: 90), "Hog is using a lot of CPU"),
            (.growingMemory(growth: 1e9, current: 2_000_000_000), "Hog's memory keeps climbing"),
            (.heavyDisk(average: 1e8), "Hog is writing a lot to disk"),
            (.heavyNetwork(direction: .download, average: 1e8), "Hog is using a lot of network"),
        ]
        for (finding, title) in findings {
            #expect(AlertText.make(for: finding, app: Fixture.app, window: window).title == title)
        }
    }
}
