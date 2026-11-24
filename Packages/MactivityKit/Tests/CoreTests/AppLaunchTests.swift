@testable import Core
import Foundation
import Testing

/// App launch times (D-215).
struct AppLaunchTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func launch(_ app: String, daysAgo: Double, seconds: Double) -> AppLaunch {
        AppLaunch(at: now - daysAgo * 86400, appID: app.lowercased(), name: app, seconds: seconds)
    }

    @Test("The last two weeks' median beside the three weeks before; slower at half again and a second more")
    func trend() {
        let launches = [3, 5, 9].map { launch("Xcode", daysAgo: $0, seconds: 4.2) } + [20, 25, 30].map { launch(
            "Xcode",
            daysAgo: $0,
            seconds: 2.1
        ) }
            + [1, 2, 3].map { launch("Notes", daysAgo: $0, seconds: 0.6) } + [20, 22, 24].map { launch("Notes", daysAgo: $0, seconds: 0.3) }
        let apps = AppLaunchTimes.byApp(launches, now: now)
        #expect(apps.map(\.name) == ["Xcode", "Notes"], "slowest first")
        #expect(apps.first?.recent == 4.2 && apps.first?.earlier == 2.1)
        #expect(apps.first?.isSlower == true)
        #expect(apps.last?.isSlower == false, "twice as long, but under a second more")
    }

    @Test("Not right after the Mac starts, and not a launch held up for minutes")
    func keeping() {
        #expect(AppLaunch.isWorthKeeping(seconds: 1.2, uptime: 3600))
        #expect(!AppLaunch.isWorthKeeping(seconds: 1.2, uptime: 120))
        #expect(!AppLaunch.isWorthKeeping(seconds: 300, uptime: 3600))
        #expect(Formatters.seconds(1.24).contains("1.2"))
    }
}
