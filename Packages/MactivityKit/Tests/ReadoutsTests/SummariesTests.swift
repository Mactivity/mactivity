import Core
import Foundation
@testable import Readouts
import Testing

/// The spoken results of the Shortcuts intents.
@Suite("Summaries")
struct SummariesTests {
    private let now = Date(timeIntervalSince1970: 1_790_330_400)

    @Test("System stats in one breath")
    func system() throws {
        let snapshot = try Fixtures.snapshot()
        #expect(
            Summaries.system(snapshot.system, locale: Fixtures.english)
                == "CPU is at 23%. 18 GB of 48 GB memory used. Battery at 87%, charging."
        )
    }

    @Test("Battery wording: on battery with time left, on power, still estimating")
    func battery() {
        func stats(charging: Bool, source: BatteryStats.PowerSource, remaining: Duration?) -> BatteryStats {
            BatteryStats(
                percent: 40, isCharging: charging, source: source, timeRemaining: remaining,
                cycleCount: nil, maxCapacityPercent: nil, powerDrawWatts: nil
            )
        }
        func sentence(_ source: BatteryStats.PowerSource, _ remaining: Duration?) -> String {
            Summaries.batterySentence(stats(charging: false, source: source, remaining: remaining), locale: Fixtures.english)
        }
        #expect(sentence(.battery, .seconds(7500)) == "Battery at 40%, 2h 5m left.")
        #expect(sentence(.ac, nil) == "Battery at 40%, on power.")
        #expect(sentence(.battery, nil) == "Battery at 40%.")
    }

    @Test("Desktops have no battery sentence")
    func noBattery() throws {
        let snapshot = try Fixtures.variant(of: Fixtures.snapshot(), battery: .some(nil))
        #expect(Summaries.system(snapshot.system, locale: Fixtures.english) == "CPU is at 23%. 18 GB of 48 GB memory used.")
    }

    @Test("Top apps, as a spoken list")
    func topApps() throws {
        let apps = try AppRanking.memory.rank(Fixtures.snapshot().apps, limit: 3, includingSystem: false)
        #expect(
            Summaries.topApps(apps, by: .memory, locale: Fixtures.english)
                == "Top apps by memory: Xcode 6.2 GB, Safari 3.1 GB, and Slack 812 MB."
        )
        #expect(Summaries.topApps([], by: .cpu, locale: Fixtures.english) == "No apps to rank right now.")
    }

    @Test("Dev servers by project, with ports and activity")
    func devServers() {
        #expect(
            Summaries.devServers(Fixtures.projects(now: now), locale: Fixtures.english)
                == "2 dev servers in 2 projects. storefront-web: port 4321, working. api: ports 8080 and 8081, idle 2h 5m."
        )
        #expect(Summaries.devServers([], locale: Fixtures.english) == "No dev servers are running.")
    }

    @Test("Idle servers only")
    func idle() {
        let all = Summaries.idleServers(Fixtures.projects(now: now), locale: Fixtures.english)
        #expect(all == "1 idle dev server: api (ports 8080 and 8081).")
        let working = Array(Fixtures.projects(now: now).prefix(1))
        #expect(Summaries.idleServers(working, locale: Fixtures.english) == "No dev servers are idle.")
    }

    @Test("Ports", arguments: [
        ([UInt16](), "no ports"),
        ([3000], "port 3000"),
        ([8080, 8081], "ports 8080 and 8081"),
        ([1, 2, 3], "ports 1, 2, and 3"),
    ])
    func ports(ports: [UInt16], expected: String) {
        #expect(Summaries.ports(ports, locale: Fixtures.english) == expected)
    }
}
