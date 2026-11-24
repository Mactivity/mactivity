import Darwin
import Foundation
@testable import PrivateAPIs
import Testing

struct LedgerFixture: Decodable {
    struct Step: Decodable {
        let op: String
        let source: UInt?
        let pid: Int32?
        let uniquePID: UInt64?
        let rx: UInt64?
        let tx: UInt64?
        let loopback: Bool?
        let description: Bool?
        /// For expectNeedsDescriptions.
        let value: Bool?
        /// PID → [rx, tx].
        let totals: [String: [UInt64]]?
        let dead: [Int32]?
    }

    let steps: [Step]
}

@Suite("NetworkStatistics")
struct NetworkStatisticsTests {
    @Test("Missing symbols: the monitor is unavailable and reports nil, so rates stay nil")
    func fallback() async {
        let monitor = NetworkStatisticsMonitor(functions: nil)
        #expect(!monitor.isAvailable)
        #expect(monitor.cumulativeBytesByPID() == nil)
        #expect(await monitor.cumulativeBytes() == nil)
    }

    @Test("Ledger: closed sockets keep their bytes; loopback, reused PIDs and undescribed sources as the fixture says")
    func ledger() throws {
        let fixture = try Fixtures.load("network-per-pid-ledger.json", as: LedgerFixture.self)
        var ledger = NetworkStatisticsLedger()
        for (index, step) in fixture.steps.enumerated() {
            switch step.op {
            case "update":
                let source = try #require(step.source)
                ledger.update(source: source, with: .init(
                    pid: step.pid, uniquePID: step.uniquePID, rx: step.rx, tx: step.tx, loopback: step.loopback,
                    isDescription: step.description ?? false
                ))
            case "remove":
                try ledger.remove(source: #require(step.source))
            case "prune":
                let dead = Set(step.dead ?? [])
                ledger.pruneClosed { pid, _ in !dead.contains(pid) }
            case "expectNeedsDescriptions":
                #expect(ledger.needsDescriptions == step.value, "step \(index)")
            case "expect":
                let expected = try #require(step.totals)
                let totals = ledger.totals()
                #expect(Set(totals.keys.map(String.init)) == Set(expected.keys), "step \(index)")
                for (pid, bytes) in expected {
                    let actual = try #require(Int32(pid).flatMap { totals[$0] }, "step \(index), pid \(pid)")
                    #expect([actual.rx, actual.tx] == bytes, "step \(index), pid \(pid)")
                }
            default:
                Issue.record("Unknown step \(step.op)")
            }
        }
    }

    @Test("A PID reused by a new process isn't the one that closed the sockets (D-221)")
    func reusedPID() {
        // This test process started before now, and after the epoch.
        #expect(NetworkStatisticsMonitor.isAlive(getpid(), closedAt: Date()))
        #expect(!NetworkStatisticsMonitor.isAlive(getpid(), closedAt: Date(timeIntervalSince1970: 0)))
        var ledger = NetworkStatisticsLedger()
        ledger.update(source: 1, with: .init(pid: 42, uniquePID: 9, rx: 10, tx: 20, loopback: false))
        ledger.remove(source: 1, at: Date(timeIntervalSince1970: 100))
        ledger.pruneClosed { _, closedAt in closedAt > Date(timeIntervalSince1970: 200) }
        #expect(ledger.totals()[42] == nil)
    }

    @Test("A process that is still alive keeps its closed bytes through a prune")
    func pruneKeepsLiveProcesses() {
        var ledger = NetworkStatisticsLedger()
        ledger.update(source: 1, with: .init(pid: 42, uniquePID: 9, rx: 10, tx: 20, loopback: false))
        ledger.remove(source: 1)
        ledger.pruneClosed { _, _ in true }
        #expect(ledger.totals()[42].map { [$0.rx, $0.tx] } == [10, 20])
    }

    @Test(
        "Live: after a curl download, curl's PID shows the bytes, though its socket closed before the query",
        .enabled(
            if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil,
            "needs network access and macOS's NetworkStatistics: make test-live"
        )
    )
    func live() async throws {
        let monitor = NetworkStatisticsMonitor()
        try #require(monitor.isAvailable)
        _ = await monitor.cumulativeBytes()
        let pid = try spawnCurl()
        // Wait for curl to exit but don't reap it yet: the monitor drops the closed bytes of
        // processes that no longer exist, and an unreaped zombie still does.
        var info = siginfo_t()
        waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
        defer {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        try #require(info.si_status == 0, "curl failed; is the network up?")
        var seen: (rx: UInt64, tx: UInt64)?
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            seen = await monitor.cumulativeBytes()?[pid]
            if let seen, seen.rx > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect((seen?.rx ?? 0) > 0)
        #expect((seen?.tx ?? 0) > 0)
        // The blocking variant sees the same ledger.
        #expect((monitor.cumulativeBytesByPID()?[pid]?.rx ?? 0) > 0)
    }

    /// `/usr/bin/curl -s https://www.apple.com -o /dev/null`. The traffic comes from a child
    /// process: Mactivity opens no connections itself (rule 3).
    private func spawnCurl() throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let arguments = ["/usr/bin/curl", "-s", "https://www.apple.com", "-o", "/dev/null"]
        var cArguments = arguments.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/usr/bin/curl", &actions, nil, &cArguments, environ)
        try #require(status == 0)
        return pid
    }
}
