@testable import Core
import Foundation
import Testing

/// What macOS flagged (D-212), from reports' text as macOS writes it.
struct MacReportsTests {
    private let chromeWrites = """
    Date/Time:        2026-10-11 17:37:37.289 -0700
    End time:         2026-10-11 20:47:47.205 -0700
    Command:          Google Chrome Helper
    Identifier:       com.google.Chrome.helper
    Resource Coalition: "com.anthropic.claudefordesktop"(992)
    Event:            disk writes
    Action taken:     none
    Writes:           137.44 GB of file backed memory dirtied over 11410 seconds (12.05 MB per second average), exceeding limit
    Writes caused:    137.44 GB
    Writes duration:  11410s
    Resource Coalition: 1 sample "com.something.else"(1)
    """

    @Test("A disk-writes report: the process, the app it belongs to, and the amount; routine ones aren't notable")
    func diskWrites() throws {
        let report = try #require(MacReportParser.resource(chromeWrites, path: "/x.diag"))
        #expect(report.process == "Google Chrome Helper")
        #expect(report.ownerBundleID == "com.anthropic.claudefordesktop")
        #expect(report.kind == .diskWrites(bytes: 137.44e9, seconds: 11410))
        #expect(report.isNotable)
        let routine = chromeWrites.replacingOccurrences(of: "137.44 GB", with: "2147.52 MB").replacingOccurrences(
            of: "11410s",
            with: "80308s"
        )
        #expect(try #require(MacReportParser.resource(routine, path: "/y.diag")).isNotable == false)
    }

    @Test("macOS's own processes say what they do")
    func who() {
        let spotlight = MacReport(
            id: "s",
            at: Date(),
            kind: .diskWrites(bytes: 8.6e9, seconds: 55000),
            process: "mds_stores",
            ownerBundleID: nil,
            path: ""
        )
        #expect(MacReportText.who(spotlight, owner: nil) == "mds_stores (Spotlight indexing)")
        let helper = MacReport(id: "h", at: Date(), kind: .memoryKill, process: "Google Chrome Helper", ownerBundleID: nil, path: "")
        #expect(MacReportText.who(helper, owner: "Claude") == "Google Chrome Helper, in Claude")
    }

    @Test("CPU and wake-up reports read their figures")
    func cpuAndWakeups() throws {
        let cpu = """
        Date/Time:        2026-10-12 09:01:02.000 -0700
        Command:          mds_stores
        Event:            cpu usage
        CPU:              900 seconds cpu time over 1100 seconds (82% cpu average), exceeding limit of 50% cpu over 180 seconds
        """
        #expect(try #require(MacReportParser.resource(cpu, path: "/c.diag")).kind == .cpu(seconds: 900, over: 1100))
        let wakeups = """
        Date/Time:        2026-10-12 09:01:02.000 -0700
        Command:          Dropbox
        Event:            wakeups
        Wakeups:          45001 wakeups over the last 199 seconds (226 wakeups per second average), exceeding limit
        """
        #expect(try #require(MacReportParser.resource(wakeups, path: "/w.diag")).kind == .wakeups(count: 45001, over: 199))
    }

    @Test("A JetsamEvent counts apps closed for lack of memory, not processes over their own limit")
    func memoryKills() {
        let header: [String: Any] = ["bug_type": "298", "timestamp": "2026-10-14 17:51:26.00 -0700"]
        let body: [String: Any] = ["processes": [
            ["name": "Safari", "reason": "vm-pageshortage", "priority": 100, "pid": 410],
            ["name": "com.apple.WebKit.WebContent", "reason": "vm-pageshortage", "priority": 40, "pid": 411],
            ["name": "com.apple.WebKit.WebContent", "reason": "vm-pageshortage", "priority": 40, "pid": 412],
            ["name": "photoanalysisd", "reason": "vm-pageshortage", "priority": 0, "pid": 90],
            ["name": "stickersd", "reason": "per-process-limit", "priority": 40], ["name": "Mail"],
        ]]
        let kills = MacReportParser.memoryKills(header: header, body: body, path: "/j.ips")
        #expect(kills.map(\.process) == ["Safari", "com.apple.WebKit.WebContent", "com.apple.WebKit.WebContent"], "idle ones are routine")
        #expect(Set(kills.map(\.id)).count == 3, "each its own ID")
        #expect(kills.first?.kind == .memoryKill)
    }

    @Test("A panic keeps its explanation line; it's a restart")
    func panic() throws {
        let report = try #require(MacReportParser.panic(
            header: ["bug_type": "210", "timestamp": "2026-10-09 16:01:45.00 -0700"],
            body: "{\n  \"panicString\" : \"panic(cpu 3 caller 0xfffffe): watchdog timeout: no checkins\\nDebugger message\"\n}",
            path: "/p.ips"
        ))
        #expect(report.isRestart)
        if case let .panic(summary) = report.kind {
            #expect(summary.hasPrefix("panic(cpu 3"))
        } else {
            Issue.record("not a panic")
        }
        #expect(MacReportParser
            .panic(header: ["bug_type": "309", "timestamp": "2026-10-09 16:01:45.00 -0700"], body: "", path: "/c.ips") == nil)
    }

    @Test("A shutdown stall isn't a restart; repeated processor reports fold into one, notable at three; a panic written twice counts once")
    func collapsing() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let stall = MacReport(id: "s", at: now, kind: .shutdownStall, process: nil, ownerBundleID: nil, path: "")
        #expect(!stall.isRestart)
        let cpu = (0 ..< 4).map {
            MacReport(
                id: "c\($0)",
                at: now - Double($0) * 3600,
                kind: .cpu(seconds: 90, over: 100),
                process: "spotlightknowledged",
                ownerBundleID: nil,
                path: ""
            )
        }
        let one = MacReport(id: "d", at: now, kind: .cpu(seconds: 90, over: 100), process: "suggestd", ownerBundleID: nil, path: "")
        let panics = [
            MacReport(id: "p1", at: now, kind: .panic(summary: "a"), process: nil, ownerBundleID: nil, path: "/panic-full"),
            MacReport(id: "p2", at: now + 2, kind: .panic(summary: "a"), process: nil, ownerBundleID: nil, path: "/panic-base"),
        ]
        let collapsed = MacReport.collapsed(cpu + [one, stall] + panics)
        #expect(collapsed.count == 4)
        #expect(collapsed.first { $0.process == "spotlightknowledged" }?.repeats == 4)
        #expect(collapsed.first { $0.process == "spotlightknowledged" }?.isNotable == true)
        #expect(collapsed.first { $0.process == "suggestd" }?.isNotable == false)
    }

    @Test("An app hanging much more this week than before is worse; a steady one isn't")
    func hangTrend() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func hang(_ app: String, daysAgo: Double) -> CrashReport {
            CrashReport(id: "\(app)\(daysAgo)", at: now - daysAgo * 86400, appName: app, bundleID: nil, kind: .hang, path: "")
        }
        // With no report older than two weeks, there's nothing to compare against.
        #expect(HangTrend.worse((0 ..< 5).map { hang("Safari", daysAgo: Double($0)) }, now: now).isEmpty)
        let reports = (0 ..< 5).map { hang("Safari", daysAgo: Double($0)) } + [hang("Safari", daysAgo: 10)]
            + (0 ..< 4).map { hang("Xcode", daysAgo: Double($0)) } + (8 ..< 20).map { hang("Xcode", daysAgo: Double($0)) }
        let worse = HangTrend.worse(reports, now: now)
        #expect(worse.map(\.appName) == ["Safari"])
        #expect(worse.first?.thisWeek == 5)
    }
}
