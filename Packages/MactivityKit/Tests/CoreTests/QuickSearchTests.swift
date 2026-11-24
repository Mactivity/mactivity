import Core
import Foundation
import Testing

@Suite("Quick Search (D-137)")
struct QuickSearchTests {
    private func app(_ name: String, cpu: Double = 0, kind: AppIdentity.Kind = .app) -> AppAggregate {
        AppAggregate(
            app: AppIdentity(id: "id." + name, name: name, bundleID: nil, iconKey: "", kind: kind),
            processCount: 1, cpuPercent: cpu, memoryBytes: 0, energyMW: nil, diskReadBPS: 0, diskWriteBPS: 0,
            netInBPS: nil, netOutBPS: nil, gpuPercent: nil
        )
    }

    private func process(_ pid: Int32, _ name: String, app: String, cpu: Double = 0) -> ProcessSample {
        ProcessSample(
            pid: pid, app: app, name: name, cpuPercent: cpu, footprintBytes: 0, diskReadBPS: 0, diskWriteBPS: 0,
            energyMW: nil, netInBPS: nil, netOutBPS: nil, gpuPercent: nil
        )
    }

    private var snapshot: Snapshot {
        let apps = [app("Safari", cpu: 3), app("Slack", cpu: 9), app("Xcode", cpu: 20), app("Messages"), app("macOS", kind: .system)]
        let processes = [
            process(501, "Safari", app: "id.Safari"), process(777, "node", app: "id.Terminal", cpu: 4),
            process(778, "node", app: "id.Terminal", cpu: 9), process(900, "WindowServer", app: "system"),
        ]
        return Snapshot(
            at: Date(timeIntervalSince1970: 1_800_000_000), interval: .seconds(1),
            system: SystemSample(
                cpu: CPUStats(totalPercent: 0, userPercent: 0, systemPercent: 0, perCorePercent: [], clusters: [], loadAverage: .zero),
                memory: MemoryStats(
                    totalBytes: 1, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0, cachedFilesBytes: 0,
                    swapUsedBytes: 0, pressure: .normal, availableLevel: 100
                ),
                disk: DiskStats(volumes: [], readBPS: 0, writeBPS: 0),
                network: NetworkStats(inBPS: 0, outBPS: 0, primaryInterface: nil),
                gpu: nil, battery: nil, sensors: nil, thermal: .nominal, uptime: .seconds(1)
            ),
            apps: apps, processes: processes
        )
    }

    private var projects: [Project] {
        let server = DevServer(
            pid: 777, name: "node", command: "next dev", runtime: .node, ports: [3000, 9229], memoryBytes: 0,
            startedAt: Date(timeIntervalSince1970: 0), cpuTime: .zero, activity: .working, stopTarget: .processGroup(777)
        )
        return [Project(rootPath: "/Users/me/Developer/shop", name: "shop", servers: [server])]
    }

    private func ids(_ query: String) -> [String] {
        QuickSearch.results(query, snapshot: snapshot, projects: projects).map(\.id)
    }

    @Test("Empty: the diagnosis, then the busiest apps, never macOS")
    func empty() {
        #expect(ids("") == ["diagnose", "app:id.Xcode", "app:id.Slack", "app:id.Safari", "app:id.Messages"])
    }

    @Test("Names that start with the query before names that contain it, busiest first")
    func names() {
        #expect(ids("s") == ["app:id.Slack", "app:id.Safari", "app:id.Messages", "pid:900"])
        #expect(ids("SAF") == ["app:id.Safari"])
    }

    @Test("Processes by name and PID; a matched app's own processes stay under its row")
    func processes() {
        #expect(ids("node") == ["pid:778", "pid:777"])
        #expect(ids("501") == ["pid:501"])
    }

    @Test("Ports, with or without the colon")
    func ports() {
        #expect(ids(":3000") == ["port:3000:777"])
        #expect(ids("92") == ["port:9229:777"])
    }

    @Test("Asking why it's slow offers the diagnosis")
    func diagnose() {
        #expect(ids("slow").first == "diagnose")
        #expect(ids("why").first == "diagnose")
    }

    @Test("Shopping for a Mac offers Your next Mac")
    func nextMac() {
        #expect(ids("upgrade") == ["nextMac"])
        #expect(ids("next mac").contains("nextMac"))
        #expect(ids("Laptop") == ["nextMac"])
        #expect(!ids("sa").contains("nextMac"))
    }

    @Test("A page by its name, from two letters, after the actions and before apps")
    func pages() {
        let pages = ["Overview", "Storage", "Startup", "Sound", "Battery", "CPU"].map { QuickSearchPage(id: $0.lowercased(), title: $0) }
        func ids(_ query: String) -> [String] {
            QuickSearch.results(query, snapshot: snapshot, projects: projects, pages: pages).map(\.id)
        }
        #expect(ids("stor").first == "page:storage")
        #expect(ids("st").prefix(2) == ["page:storage", "page:startup"])
        #expect(ids("cpu").first == "page:cpu")
        #expect(!ids("s").contains { $0.hasPrefix("page:") })
        #expect(ids("bat") == ["page:battery"])
    }

    @Test("today and yesterday open Your day")
    func days() {
        #expect(ids("yest").first == "day:1")
        #expect(ids("tod").first == "day:0")
        #expect(ids("timeline").first == "day:0")
    }

    @Test("Accents, case and full-width letters don't matter (D-221)")
    func folded() {
        let results = QuickSearch.results("resume", snapshot: snapshot, projects: [], pages: [QuickSearchPage(id: "x", title: "Résumé")])
        #expect(results.first?.id == "page:x")
        let wide = QuickSearch.results("ｓａｆａｒｉ", snapshot: snapshot, projects: [])
        #expect(wide.first?.id == "app:id.Safari")
        let german = QuickSearch.results(
            "uber",
            snapshot: snapshot,
            projects: [],
            pages: [QuickSearchPage(id: "overview", title: "Übersicht")]
        )
        #expect(german.first?.id == "page:overview")
    }

    @Test("Actions are found by their names in the Mac's language (D-221)")
    func localizedActions() {
        let german: [QuickSearchResult: String] = [
            .diagnose: "Warum ist mein Mac langsam?", .record: "Aktivität aufzeichnen…", .cleanKeyboard: "Tastatur reinigen",
            .compare: "Tage vergleichen…", .day(daysBack: 0): "Dein Tag: Heute",
        ]
        func ids(_ query: String, _ titles: [QuickSearchResult: String]) -> [String] {
            QuickSearch.results(query, snapshot: snapshot, projects: [], actionTitles: titles).map(\.id)
        }
        #expect(ids("langsam", german).first == "diagnose")
        #expect(ids("aufzeich", german).first == "record")
        #expect(ids("heute", german).first == "day:0")
        // Short common words name nothing; the keyboard lock needs its second word.
        #expect(!ids("mein", german).contains("diagnose"))
        #expect(!ids("ist", german).contains("diagnose"))
        #expect(!ids("tastatur", german).contains("cleanKeyboard"))
        #expect(ids("tastatur r", german).first == "cleanKeyboard")
        #expect(ids("tage ve", german).first == "compare")
        let japanese: [QuickSearchResult: String] = [.diagnose: "Macが遅いのはなぜ？"]
        #expect(ids("遅い", japanese).first == "diagnose")
    }
}
