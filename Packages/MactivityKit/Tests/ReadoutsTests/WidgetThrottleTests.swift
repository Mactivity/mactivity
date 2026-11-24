import Core
import Foundation
@testable import Readouts
import Testing

@Suite("Widget throttle")
struct WidgetThrottleTests {
    private let start = Date(timeIntervalSince1970: 1_790_330_400)

    private func widget(cpu: Double = 23.4, memoryUsed: UInt64? = nil, battery: BatteryStats?? = nil, apps: [AppAggregate]? = nil) throws
        -> WidgetSnapshot {
        let snapshot = try Fixtures.variant(of: Fixtures.snapshot(), cpu: cpu, memoryUsed: memoryUsed, battery: battery, apps: apps)
        return WidgetSnapshot(snapshot: snapshot, cpuHistory: [])
    }

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test("The first snapshot writes and reloads")
    func first() throws {
        var throttle = WidgetThrottle()
        #expect(try throttle.decide(widget(), now: start) == .writeAndReload)
    }

    @Test("Nothing within a minute of the last write, however big the change")
    func minuteFloor() throws {
        var throttle = WidgetThrottle()
        _ = try throttle.decide(widget(), now: start)
        #expect(!throttle.isDue(now: at(59)))
        #expect(try throttle.decide(widget(cpu: 95), now: at(59)) == .skip)
        #expect(throttle.isDue(now: at(60)))
    }

    @Test("Small moves don't count: under 5 CPU points, 2 memory points, 1 battery point")
    func smallMoves() throws {
        var throttle = WidgetThrottle()
        _ = try throttle.decide(widget(), now: start)
        #expect(try throttle.decide(widget(cpu: 27), now: at(60)) == .skip)
        // 18 GiB of 48 GiB is 37.5%; 18.5 GiB is 38.5%.
        #expect(try throttle.decide(widget(memoryUsed: 19_864_223_744), now: at(120)) == .skip)
        let battery = BatteryStats(
            percent: 87.4, isCharging: true, source: .ac, timeRemaining: nil, cycleCount: nil, maxCapacityPercent: nil, powerDrawWatts: nil
        )
        #expect(try throttle.decide(widget(battery: .some(battery)), now: at(180)) == .skip)
    }

    @Test("A meaningful change writes; the reload waits for 15 minutes since the last one")
    func reloadInterval() throws {
        var throttle = WidgetThrottle()
        _ = try throttle.decide(widget(), now: start)
        #expect(try throttle.decide(widget(cpu: 40), now: at(60)) == .write)
        #expect(try throttle.decide(widget(cpu: 10), now: at(120)) == .write)
        #expect(try throttle.decide(widget(cpu: 60), now: at(15 * 60)) == .writeAndReload)
    }

    @Test("A change written inside the cooldown is reloaded once it ends, without another change (D-145)")
    func owedReload() throws {
        var throttle = WidgetThrottle()
        _ = try throttle.decide(widget(), now: start)
        #expect(try throttle.decide(widget(cpu: 90), now: at(60)) == .write)
        // CPU stays at 90: nothing new, but the 90 hasn't reached the widget yet.
        #expect(try throttle.decide(widget(cpu: 90), now: at(10 * 60)) == .skip)
        #expect(try throttle.decide(widget(cpu: 90), now: at(15 * 60)) == .writeAndReload)
        // Reloaded: nothing owed any more.
        #expect(try throttle.decide(widget(cpu: 90), now: at(16 * 60)) == .skip)
    }

    @Test("Each kind of meaningful change", arguments: ["cpu", "memory", "pressure", "charging", "unplugged", "battery", "apps"])
    func changes(kind: String) throws {
        let base = try widget()
        var changed = base
        switch kind {
        case "cpu": changed.cpuPercent += 5
        case "memory": changed.memoryUsedBytes += changed.memoryTotalBytes / 40
        case "pressure": changed.memoryPressure = .warning
        case "charging": changed.battery?.isCharging = false
        case "unplugged": changed.battery = nil
        case "battery": changed.battery?.percent -= 1
        default: changed.topApps.swapAt(0, 1)
        }
        #expect(WidgetPublishPolicy.standard.changedMeaningfully(from: base, to: changed))
    }

    @Test("The sparkline history alone is not a change")
    func historyIsNotAChange() throws {
        let base = try widget()
        var changed = base
        changed.cpuHistory = [1, 2, 3]
        changed.updatedAt = base.updatedAt.addingTimeInterval(600)
        #expect(!WidgetPublishPolicy.standard.changedMeaningfully(from: base, to: changed))
    }

    @Test("Unchanged for 30 minutes: a heartbeat write and reload keeps the widget from going stale")
    func heartbeat() throws {
        var throttle = WidgetThrottle()
        _ = try throttle.decide(widget(), now: start)
        #expect(try throttle.decide(widget(), now: at(29 * 60)) == .skip)
        #expect(try throttle.decide(widget(), now: at(30 * 60)) == .writeAndReload)
    }
}

@Suite("Minute means")
struct MinuteMeansTests {
    @Test("One point per finished minute, the minute in progress on top")
    func means() {
        var means = MinuteMeans(capacity: 3)
        let base = Date(timeIntervalSince1970: 60000)
        means.add(10, at: base)
        means.add(20, at: base.addingTimeInterval(5))
        #expect(means.points.isEmpty)
        #expect(means.withCurrent == [15])
        means.add(40, at: base.addingTimeInterval(60))
        #expect(means.points == [15])
        #expect(means.withCurrent == [15, 40])
    }

    @Test("Keeps only the newest points")
    func capacity() {
        var means = MinuteMeans(capacity: 3)
        let base = Date(timeIntervalSince1970: 60000)
        for minute in 0 ..< 6 {
            means.add(Double(minute), at: base.addingTimeInterval(Double(minute) * 60))
        }
        #expect(means.points == [2, 3, 4])
        #expect(means.withCurrent == [3, 4, 5])
    }
}

@MainActor
@Suite("Widget feed")
struct WidgetFeedTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetFeedTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Library/Application Support/widget-snapshot.json")
    }

    @Test("Writes the file (creating folders), reloads once, and the file decodes")
    func writes() throws {
        let url = temporaryFile()
        defer {
            try? FileManager.default
                .removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        }
        var reloads = 0
        let feed = WidgetFeed(fileURL: url) { reloads += 1 }
        let base = try Fixtures.snapshot()
        #expect(feed.consider(base) == .writeAndReload)
        #expect(reloads == 1)
        let written = try #require(WidgetSnapshot.load(from: url))
        #expect(written.topApps.map(\.name) == ["Xcode", "node", "Safari"])
        #expect(written.cpuHistory == [23.4])

        // Five-second idle ticks for the next minute: nothing is written.
        for tick in 1 ..< 12 {
            #expect(feed.consider(Fixtures.variant(of: base, at: base.at.addingTimeInterval(Double(tick) * 5), cpu: 80)) == .skip)
        }
        #expect(feed.consider(Fixtures.variant(of: base, at: base.at.addingTimeInterval(60), cpu: 80)) == .write)
        #expect(reloads == 1)
        #expect(WidgetSnapshot.load(from: url)?.cpuPercent == 80)
    }

    @Test("An unwritable location logs and never reloads")
    func unwritable() throws {
        var reloads = 0
        let feed = WidgetFeed(fileURL: URL(fileURLWithPath: "/dev/null/widget-snapshot.json")) { reloads += 1 }
        _ = try feed.consider(Fixtures.snapshot())
        #expect(reloads == 0)
    }

    /// The idle budget (CLAUDE.md rule 5): a day of 5-second ticks with CPU swinging every minute,
    /// so a write lands every minute, the worst case. Set `MACTIVITY_DUMP` to record the figures.
    @Test("A day of idle ticks costs well under the idle budget")
    func cost() throws {
        let url = temporaryFile()
        defer {
            try? FileManager.default
                .removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        }
        let feed = WidgetFeed(fileURL: url) {}
        let base = try Fixtures.snapshot()
        let ticks = 24 * 3600 / 5
        let snapshots = (0 ..< ticks).map { tick in
            Fixtures.variant(of: base, at: base.at.addingTimeInterval(Double(tick) * 5), cpu: (tick / 12).isMultiple(of: 2) ? 10 : 60)
        }
        var writes = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for snapshot in snapshots where feed.consider(snapshot) != .skip {
                writes += 1
            }
        }
        let perTick = elapsed / ticks
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        // Share of one core over a day of wall time.
        let coreShare = seconds / (24 * 3600) * 100
        #expect(writes == 24 * 60)
        #expect(perTick < .microseconds(200))
        // The budget is 0.1% of a core; 10× under it, so tests running in parallel on a busy Mac
        // don't fail it (it read 0.00102% once, under the full suite during make release).
        #expect(coreShare < 0.01)
        if let path = ProcessInfo.processInfo.environment["MACTIVITY_DUMP"] {
            let report = "ticks \(ticks), writes \(writes), total \(elapsed), per tick \(perTick), core share \(coreShare)%\n"
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
