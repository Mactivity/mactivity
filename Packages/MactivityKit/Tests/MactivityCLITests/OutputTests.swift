import Core
import Foundation
@testable import MactivityCLI
import Readouts
import Testing

@Suite("CLI text output")
struct TextOutputTests {
    @Test("top: aligned columns, sorted by CPU, dashes for missing figures")
    func top() throws {
        let output = try TextOutput.top(Fixtures.snapshot(), options: .init(), locale: Fixtures.english)
        #expect(output == """
        APP       PROCS  CPU  MEMORY  ENERGY      DISK  NETWORK
        Xcode        14  13%  6.2 GB   4.1 W  1.2 MB/s        –
        node          3   8%  458 MB       –   10 kB/s        –
        macOS       812   4%  9.0 GB  0.80 W  150 kB/s        –
        Safari       31   3%  3.1 GB  0.95 W   20 kB/s        –
        Slack         6  <1%  812 MB  0.12 W     0 B/s        –
        Terminal      4   0%   96 MB     0 W     0 B/s        –
        """)
    }

    @Test("top --memory --limit 2")
    func topMemory() throws {
        let options = Command.TopOptions(ranking: .memory, limit: 2, json: false)
        let output = try TextOutput.top(Fixtures.snapshot(), options: options, locale: Fixtures.english)
        #expect(output == """
        APP    PROCS  CPU  MEMORY  ENERGY      DISK  NETWORK
        macOS    812   4%  9.0 GB  0.80 W  150 kB/s        –
        Xcode     14  13%  6.2 GB   4.1 W  1.2 MB/s        –
        """)
    }

    @Test("system: clusters by level, one line per figure")
    func system() throws {
        let output = try TextOutput.system(Fixtures.snapshot().system, locale: Fixtures.english)
        #expect(output == """
        CPU            23% (user 15%, system 8%)
          Performance  25% (2 cores)
          Efficiency   22% (2 cores)
          Load         2.31  2.10  1.98
        Memory         18 GB of 48 GB used (pressure normal, swap 0 B)
        Disk           Macintosh HD: 717 GB free of 995 GB
                       read 1.2 MB/s, write 400 kB/s
        Network        in 12 kB/s, out 3.1 kB/s (en0)
        GPU            Apple M5 Pro: 4%
        Battery        87%, charging, 1h 5m to full, 42 cycles
        Thermal        nominal
        Uptime         3d 4h
        """)
    }

    @Test("projects: one row per server, home abbreviated")
    func projects() {
        let output = TextOutput.projects(Fixtures.projects(), now: Fixtures.now, home: "/Users/demo", locale: Fixtures.english)
        #expect(output == """
        PROJECT          PID  SERVER   PORTS      RUNTIME  MEMORY     UP  ACTIVITY    PATH
        storefront-web  4312  node     4321       Node     458 MB  2h 5m  Working     ~/Developer/storefront-web
        api             5120  python3  8080,8081  Python    92 MB     3h  Idle 2h 5m  ~/Developer/api
        """)
        #expect(TextOutput.projects([], now: Fixtures.now, home: "/Users/demo") == "No dev servers are running.")
    }

    @Test("No trailing spaces on any line")
    func noTrailingSpaces() throws {
        let snapshot = try Fixtures.snapshot()
        let outputs = [
            TextOutput.top(snapshot, options: .init(), locale: Fixtures.english),
            TextOutput.system(snapshot.system, locale: Fixtures.english),
            TextOutput.projects(Fixtures.projects(), now: Fixtures.now, home: "/Users/demo", locale: Fixtures.english),
        ]
        for line in outputs.flatMap({ $0.split(separator: "\n") }) {
            #expect(line.last != " ")
        }
    }

    @Test("Long names are cut with an ellipsis")
    func truncate() {
        #expect(TextTable.truncate("com.apple.CoreSimulator.CoreSimulatorService", to: 12) == "com.apple.C…")
        #expect(TextTable.truncate("Safari", to: 12) == "Safari")
    }
}

@Suite("CLI tables")
struct TextTableTests {
    @Test("Wide characters take two columns, so Japanese names line up (D-221)")
    func wide() {
        var table = TextTable([.init(title: "APP", alignment: .left), .init(title: "CPU", alignment: .right)])
        table.add(["カレンダー", "1"])
        table.add(["Safari", "12"])
        let lines = table.render().split(separator: "\n").map(String.init)
        #expect(TextTable.columns("カレンダー") == 10)
        #expect(Set(lines.map(TextTable.columns)).count == 1)
    }
}

@Suite("CLI JSON output")
struct JSONOutputTests {
    @Test("Dates: the Mac's clock time with its offset, the same instant in any zone")
    func localDates() throws {
        let date = Date(timeIntervalSince1970: 1_790_330_400) // 2026-09-25 10:00 UTC
        #expect(try JSONOutput.date(date, timeZone: #require(TimeZone(identifier: "Asia/Kolkata"))) == "2026-09-25T15:30:00+05:30")
        #expect(try JSONOutput.date(date, timeZone: #require(TimeZone(identifier: "America/Los_Angeles"))) == "2026-09-25T03:00:00-07:00")
        #expect(JSONOutput.date(date, timeZone: .gmt) == "2026-09-25T10:00:00Z")
        let text = try JSONOutput.encode(["at": date], timeZone: #require(TimeZone(identifier: "Asia/Kathmandu")))
        #expect(text.contains("2026-09-25T15:45:00+05:45"))
        #expect(try ISO8601DateFormatter()
            .date(from: JSONOutput.date(date, timeZone: #require(TimeZone(identifier: "Asia/Kolkata")))) == date)
    }

    @Test("top: schema keys, raw numbers, explicit nulls")
    func top() throws {
        let options = Command.TopOptions(ranking: .memory, limit: 2, json: true)
        let object = try Fixtures.object(JSONOutput.encode(TopJSON(Fixtures.snapshot(), options: options)))
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["command"] as? String == "top")
        #expect(object["sortedBy"] as? String == "memory")
        #expect(object["sampledAt"] as? String == JSONOutput.date(Date(timeIntervalSince1970: 1_790_330_400)))
        #expect(object["intervalSeconds"] as? Double == 1)
        let apps = try #require(object["apps"] as? [[String: Any]])
        #expect(apps.map { $0["name"] as? String } == ["macOS", "Xcode"])
        let macOS = apps[0]
        #expect(Set(macOS.keys) == [
            "id", "name", "kind", "bundleID", "processCount", "cpuPercent", "memoryBytes", "energyMilliwatts",
            "diskReadBytesPerSecond", "diskWriteBytesPerSecond", "networkInBytesPerSecond", "networkOutBytesPerSecond", "gpuPercent",
        ])
        #expect(macOS["kind"] as? String == "system")
        #expect(macOS["bundleID"] is NSNull)
        #expect(macOS["networkInBytesPerSecond"] is NSNull)
        #expect(macOS["gpuPercent"] is NSNull)
        #expect(apps[1]["memoryBytes"] as? UInt64 == 6_657_199_308)
        #expect(apps[1]["energyMilliwatts"] as? Double == 4100)
        #expect(apps[1]["gpuPercent"] as? Double == 1.5)
    }

    @Test("system: every section present")
    func system() throws {
        let object = try Fixtures.object(JSONOutput.encode(SystemJSON(Fixtures.snapshot())))
        #expect(object["command"] as? String == "system")
        #expect(object["thermal"] as? String == "nominal")
        #expect(object["uptimeSeconds"] as? Double == 273_600)
        let cpu = try #require(object["cpu"] as? [String: Any])
        #expect(cpu["totalPercent"] as? Double == 23.4)
        #expect(cpu["coreCount"] as? Int == 4)
        #expect(cpu["loadAverage"] as? [Double] == [2.31, 2.1, 1.98])
        let clusters = try #require(cpu["clusters"] as? [[String: Any]])
        #expect(clusters.map { $0["name"] as? String } == ["Performance", "Efficiency"])
        let memory = try #require(object["memory"] as? [String: Any])
        #expect(memory["pressure"] as? String == "normal")
        #expect(memory["usedBytes"] as? UInt64 == 19_327_352_832)
        let battery = try #require(object["battery"] as? [String: Any])
        #expect(battery["timeRemainingSeconds"] as? Double == 3900)
        #expect(battery["powerSource"] as? String == "ac")
        #expect(battery["powerDrawWatts"] is NSNull)
        let gpu = try #require(object["gpu"] as? [String: Any])
        #expect(gpu["memoryInUseBytes"] is NSNull)
        let network = try #require(object["network"] as? [String: Any])
        #expect(network["interface"] as? String == "en0")
    }

    @Test("system: a desktop's battery is null, not missing")
    func desktop() throws {
        let base = try Fixtures.snapshot()
        let system = base.system
        let desktop = Snapshot(
            at: base.at, interval: base.interval,
            system: SystemSample(
                cpu: system.cpu, memory: system.memory, disk: system.disk, network: system.network, gpu: nil,
                battery: nil, sensors: nil, thermal: .serious, uptime: system.uptime
            ),
            apps: base.apps, processes: []
        )
        let object = try Fixtures.object(JSONOutput.encode(SystemJSON(desktop)))
        #expect(object["battery"] is NSNull)
        #expect(object["gpu"] is NSNull)
        #expect(object["thermal"] as? String == "serious")
    }

    @Test("projects: activity names and idle minutes")
    func projects() throws {
        let json = try JSONOutput.encode(ProjectsJSON(Fixtures.projects(), scannedAt: Fixtures.now, activityWindow: .seconds(1)))
        let object = try Fixtures.object(json)
        #expect(object["activityWindowSeconds"] as? Double == 1)
        let projects = try #require(object["projects"] as? [[String: Any]])
        #expect(projects.map { $0["name"] as? String } == ["storefront-web", "api"])
        #expect(projects[0]["activity"] as? String == "working")
        #expect(projects[0]["idleMinutes"] is NSNull)
        #expect(projects[1]["activity"] as? String == "idle")
        #expect(projects[1]["idleMinutes"] as? Int == 125)
        let server = try #require((projects[1]["servers"] as? [[String: Any]])?.first)
        #expect(server["pid"] as? Int == 5120)
        #expect(server["ports"] as? [Int] == [8080, 8081])
        #expect(server["cpuSeconds"] as? Double == 70.5)
        #expect(server["startedAt"] as? String == JSONOutput.date(Date(timeIntervalSince1970: 1_790_319_600)))
        #expect(server["runtime"] as? String == "python")
        #expect(json.contains("\"path\" : \"/Users/demo/Developer/api\""))
    }

    @Test("Rounding to two decimals; non-finite becomes 0")
    func rounding() {
        #expect(JSONOutput.round(12.345_678) == 12.35)
        #expect(JSONOutput.round(Double.nan) == 0)
        #expect(JSONOutput.round(Double?.none) == nil)
        #expect(JSONOutput.seconds(.milliseconds(1250)) == 1.25)
    }
}
