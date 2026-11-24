import Core
import Foundation
@testable import Projects
import Testing

@Suite("Project detection")
struct ProjectDetectionTests {
    /// A fake file system: the set of paths that exist.
    let files: Set<String> = [
        "/Users/demo/Developer/storefront-web/package.json",
        "/Users/demo/Developer/storefront-web/.git",
        "/Users/demo/Developer/api/pyproject.toml",
        "/Users/demo/Developer/ledger/go.mod",
        "/Users/demo/.git",
    ]

    func root(_ directory: String) -> (root: String, markers: Set<String>)? {
        ProjectDetection.projectRoot(from: directory, home: "/Users/demo", exists: { files.contains($0) })
    }

    @Test("Walks up to the nearest marker")
    func walksUp() {
        let found = root("/Users/demo/Developer/storefront-web/apps/web/src")
        #expect(found?.root == "/Users/demo/Developer/storefront-web")
        #expect(found?.markers == ["package.json", ".git"])
    }

    @Test("The home folder is never a project, even with a .git")
    func notHome() {
        #expect(root("/Users/demo/Downloads") == nil)
        #expect(root("/Users/demo") == nil)
    }

    @Test("No marker, no project; / is never one")
    func none() {
        #expect(root("/tmp/scratch") == nil)
        #expect(root("/") == nil)
    }

    @Test("Trailing slashes don't matter")
    func trailingSlash() {
        #expect(root("/Users/demo/Developer/api/")?.root == "/Users/demo/Developer/api")
    }

    struct RuntimeCase: Sendable, CustomTestStringConvertible {
        let path: String
        let markers: Set<String>
        let expected: DevRuntime

        var testDescription: String {
            path
        }

        init(_ path: String, _ expected: DevRuntime) {
            self.init(path, [], expected)
        }

        init(_ path: String, _ markers: Set<String>, _ expected: DevRuntime) {
            self.path = path
            self.markers = markers
            self.expected = expected
        }
    }

    @Test("Runtime detection", arguments: [
        RuntimeCase("/opt/homebrew/bin/node", .node),
        RuntimeCase("/Users/demo/.bun/bin/bun", .bun),
        RuntimeCase("/opt/homebrew/bin/deno", .deno),
        RuntimeCase("/opt/homebrew/opt/python@3.13/bin/python3.13", .python),
        RuntimeCase("/usr/bin/ruby", .ruby),
        RuntimeCase("/usr/bin/java", .java),
        RuntimeCase("/p/target/debug/server", ["Cargo.toml"], .rust),
        RuntimeCase("/private/var/folders/x/go-build123/b001/exe/main", ["go.mod"], .go),
        RuntimeCase("/p/bin/ledger", ["go.mod"], .go),
        RuntimeCase("/opt/homebrew/bin/nginx", .other),
    ])
    func runtime(_ testCase: RuntimeCase) {
        let name = testCase.path.split(separator: "/").last.map(String.init) ?? ""
        let detected = ProjectDetection.runtime(
            executablePath: testCase.path, name: name, arguments: [], root: "/p", markers: testCase.markers
        )
        #expect(detected == testCase.expected)
    }

    @Test("Activity: working, idle N min, barely used")
    func activity() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ProjectDetection.activity(
            lastActiveAt: now.addingTimeInterval(-60),
            startedAt: now.addingTimeInterval(-3600),
            cpuTime: .seconds(300),
            now: now
        ) == .working)
        #expect(ProjectDetection.activity(
            lastActiveAt: now.addingTimeInterval(-42 * 60),
            startedAt: now.addingTimeInterval(-3600),
            cpuTime: .seconds(300),
            now: now
        ) == .idle(minutes: 42))
        #expect(ProjectDetection.activity(
            lastActiveAt: now,
            startedAt: now.addingTimeInterval(-25 * 3600),
            cpuTime: .seconds(59),
            now: now
        ) == .barelyUsed)
        // Up a day but busy is not barely used.
        #expect(ProjectDetection.activity(
            lastActiveAt: now,
            startedAt: now.addingTimeInterval(-25 * 3600),
            cpuTime: .seconds(61),
            now: now
        ) == .working)
    }

    @Test("Process groups: stop the job, never a shell's, an app's, an editor's, or ours (D-145)")
    func stoppable() {
        func stop(_ chain: [(String, String?)], group: Int32 = 500) -> Bool {
            ProjectDetection.groupIsStoppable(processGroupID: group, ownProcessGroupID: 99, chain: chain.map { (name: $0.0, path: $0.1) })
        }
        // npm → sh -c → node: the job.
        #expect(stop([("npm", "/opt/homebrew/bin/npm"), ("sh", "/bin/sh"), ("node", "/opt/homebrew/bin/node")]))
        // The server leads its own group.
        #expect(stop([("node", "/opt/homebrew/bin/node")]))
        // uvicorn's reloader: python → python.
        #expect(stop([("python3.12", nil), ("python3.12", nil)]))
        // A shell, an app, an editor, PowerShell or a REPL that started the server: only the server.
        #expect(!stop([("zsh", "/bin/zsh"), ("node", nil)]))
        #expect(!stop([("-zsh", "/bin/zsh"), ("node", nil)]))
        #expect(!stop([("Code Helper", "/Applications/Visual Studio Code.app/Contents/MacOS/Code"), ("node", nil)]))
        #expect(!stop([("nvim", "/opt/homebrew/bin/nvim"), ("node", nil)]))
        #expect(!stop([("pwsh", "/usr/local/bin/pwsh"), ("node", nil)]))
        #expect(!stop([("sh", "/bin/sh"), ("node", nil)]))
        #expect(!stop([("zsh", "/bin/zsh")]))
        // Ours, launchd's, or nothing known.
        #expect(!stop([("npm", nil), ("node", nil)], group: 99))
        #expect(!stop([("launchd", nil)], group: 1))
        #expect(!stop([]))
    }

    @Test("Homebrew services aren't a project (D-145)")
    func homebrew() {
        let exists: (String) -> Bool = { $0 == "/opt/homebrew/.git" || $0 == "/Users/me/shop/package.json" }
        #expect(ProjectDetection.projectRoot(from: "/opt/homebrew/var/postgresql@16", home: "/Users/me", exists: exists) == nil)
        #expect(ProjectDetection.projectRoot(from: "/opt/homebrew", home: "/Users/me", exists: exists) == nil)
        #expect(ProjectDetection.projectRoot(from: "/Users/me/shop/src", home: "/Users/me", exists: exists)?.root == "/Users/me/shop")
    }

    @Test("KERN_PROCARGS2 parsing")
    func procArgs() throws {
        var bytes = withUnsafeBytes(of: Int32(3).littleEndian, Array.init)
        bytes += Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0, 0]
        for argument in ["node", "node_modules/.bin/vite", "--port=4321"] {
            bytes += Array(argument.utf8) + [0]
        }
        bytes += Array("PATH=/usr/bin".utf8) + [0]
        let parsed = try #require(ProjectDetection.parseProcArgs(bytes))
        #expect(parsed.executable == "/opt/homebrew/bin/node")
        #expect(parsed.arguments == ["node", "node_modules/.bin/vite", "--port=4321"])
        #expect(ProjectDetection.parseProcArgs([1, 0]) == nil)
    }

    @Test("Command lines abbreviate home and drop the executable's folder")
    func commandLine() {
        let line = ProjectDetection.commandLine(["/opt/homebrew/bin/node", "/Users/demo/dev/app/server.js"], home: "/Users/demo")
        #expect(line == "node ~/dev/app/server.js")
    }

    @Test("Projects group by root, working first, then by memory")
    func grouping() {
        func server(_ pid: Int32, port: UInt16, megabytes: UInt64, activity: ProjectActivity) -> DevServer {
            DevServer(
                pid: pid,
                name: "node",
                command: "node",
                runtime: .node,
                ports: [port],
                memoryBytes: megabytes << 20,
                startedAt: Date(timeIntervalSince1970: Double(pid)),
                cpuTime: .zero,
                activity: activity,
                stopTarget: .processGroup(pid)
            )
        }
        let projects = ProjectDetection.projects([
            (server(1, port: 3000, megabytes: 100, activity: .idle(minutes: 30)), "/a/big-idle"),
            (server(2, port: 3001, megabytes: 900, activity: .idle(minutes: 20)), "/a/bigger-idle"),
            (server(3, port: 4000, megabytes: 10, activity: .working), "/a/small-working"),
            (server(4, port: 4001, megabytes: 10, activity: .barelyUsed), "/a/small-working"),
        ])
        #expect(projects.map(\.name) == ["small-working", "bigger-idle", "big-idle"])
        #expect(projects[0].ports == [4000, 4001])
        #expect(projects[0].activity == .working)
        #expect(projects[1].activity == .idle(minutes: 20))
    }
}

@Suite("Activity tracker")
struct ActivityTrackerTests {
    func snapshot(at seconds: Double, cpu: Double) -> Snapshot {
        let system = SystemSample(
            cpu: CPUStats(
                totalPercent: cpu,
                userPercent: cpu,
                systemPercent: 0,
                perCorePercent: Array(repeating: cpu, count: 10),
                clusters: [],
                loadAverage: .zero
            ),
            memory: MemoryStats(
                totalBytes: 1,
                usedBytes: 0,
                appBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0,
                cachedFilesBytes: 0,
                swapUsedBytes: 0,
                pressure: .normal,
                availableLevel: 100
            ),
            disk: DiskStats(volumes: [], readBPS: 0, writeBPS: 0), network: NetworkStats(inBPS: 0, outBPS: 0, primaryInterface: nil),
            gpu: nil, battery: nil, sensors: nil, thermal: .nominal, uptime: .zero
        )
        let process = ProcessSample(
            pid: 42,
            app: "other:node",
            name: "node",
            cpuPercent: cpu,
            footprintBytes: 0,
            diskReadBPS: 0,
            diskWriteBPS: 0,
            energyMW: nil,
            netInBPS: nil,
            netOutBPS: nil,
            gpuPercent: nil
        )
        return Snapshot(at: Date(timeIntervalSince1970: seconds), interval: .seconds(5), system: system, apps: [], processes: [process])
    }

    @Test("Remembers the last tick with CPU above the threshold")
    func lastActive() {
        var tracker = ActivityTracker()
        tracker.observe(snapshot(at: 0, cpu: 1))
        tracker.observe(snapshot(at: 100, cpu: 0.5))
        // 0.01% of the machine on 10 cores is 0.1% of one core: below the threshold.
        tracker.observe(snapshot(at: 200, cpu: 0.01))
        #expect(tracker.lastActive(among: [42]) == Date(timeIntervalSince1970: 100))
        #expect(tracker.lastActive(among: [7]) == nil)
    }
}
