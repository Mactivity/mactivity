import Core
import Darwin
import Foundation
@testable import Projects
import Testing

/// The reading side of Databases and test run times (D-277, D-278), on real files and processes.
struct DeveloperSourcesTests {
    private func temporaryFolder() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("DevSources-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return (path as NSString).resolvingSymlinksInPath
    }

    private func write(_ path: String, bytes: Int = 8192, modified: Date) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    }

    @Test("A data folder's size counts everything; its last write leaves out what the database rewrites by itself")
    func dataFolder() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = Date(timeIntervalSince1970: 1_790_000_000)
        try write(folder + "/PG_VERSION", modified: old)
        try write(folder + "/base/16384/2619", modified: old)
        try write(folder + "/postmaster.pid", modified: recent)
        try write(folder + "/pg_stat_tmp/global.stat", modified: recent)
        let use = try #require(DataFolderWalk.measure(folder) { LocalDatabaseRules.isBackgroundFile(.postgres, $0) })
        #expect(use.lastWrite == old)
        #expect(use.bytes >= 4 * 8192 && use.bytes < 4 * 8192 + 4 * 64 * 1024)
        // Nothing left out: the newest file.
        #expect(DataFolderWalk.measure(folder) { _ in false }?.lastWrite == recent)
    }

    @Test("Redis's folder counts only Redis's files, and a link isn't followed out of it")
    func redisFolder() throws {
        let folder = try temporaryFolder()
        let elsewhere = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(atPath: folder)
            try? FileManager.default.removeItem(atPath: elsewhere)
        }
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        try write(folder + "/dump.rdb", modified: date)
        try write(folder + "/my-holiday-video.mov", bytes: 4 << 20, modified: Date(timeIntervalSince1970: 1_790_000_000))
        try write(elsewhere + "/big", bytes: 4 << 20, modified: Date(timeIntervalSince1970: 1_790_000_000))
        try FileManager.default.createSymbolicLink(atPath: folder + "/appendonlydir", withDestinationPath: elsewhere)
        let files = LocalDatabaseRules.dataFiles(engine: .redis, arguments: ["redis-server *:6379"])
        let use = try #require(DataFolderWalk.measure(folder, only: files) { _ in false })
        #expect(use.lastWrite == date)
        #expect(use.bytes < 1 << 20)
    }

    @Test("A folder that isn't there, or isn't a folder, gives no figure")
    func noFolder() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try write(folder + "/file", modified: Date())
        #expect(DataFolderWalk.measure(folder + "/missing") { _ in false } == nil)
        #expect(DataFolderWalk.measure(folder + "/file") { _ in false } == nil)
        let empty = try #require(try DataFolderWalk.measure(temporaryFolder()) { _ in false })
        #expect(empty.bytes == 0 && empty.lastWrite == nil)
    }

    private func awaitExit(_ watcher: ProcessExitWatcher, _ pid: Int32) async throws -> ProcessExit? {
        for _ in 0 ..< 100 {
            if let exit = watcher.drain()[pid] {
                return exit
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Starts a shell command and returns its pid; `readLater` reaps it.
    private func spawn(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        return process
    }

    @Test("The exit watcher reports a process's exit status, at its exit")
    func exitStatus() async throws {
        let watcher = ProcessExitWatcher()
        let process = try spawn("sleep 0.3; exit 3")
        watcher.watch(process.processIdentifier)
        // Twice is once.
        watcher.watch(process.processIdentifier)
        let exit = try #require(try await awaitExit(watcher, process.processIdentifier))
        #expect(exit.waitStatus.map(TestOutcome.init(waitStatus:)) == .failed)
        #expect(exit.waitStatus.map { ($0 >> 8) & 0xFF } == 3)
        #expect(watcher.drain().isEmpty)
    }

    @Test("A process already gone is no trouble: the snapshots end its run")
    func alreadyGone() async throws {
        let process = try spawn("exit 0")
        process.waitUntilExit()
        let watcher = ProcessExitWatcher()
        watcher.watch(process.processIdentifier)
        try await Task.sleep(for: .milliseconds(100))
        #expect(watcher.drain().isEmpty)
    }
}

/// On this Mac's real tools (`make test-live`): what the app's recorder does, against a real
/// process table, with nothing visible and everything in a temporary folder.
@Suite(
    "Developer sources, live",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil, "runs real tools: make test-live")
)
struct DeveloperSourcesLiveTests {
    private func temporaryFolder() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("DevLive-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return (path as NSString).resolvingSymlinksInPath
    }

    private func compile(_ source: String, named name: String, in folder: String) throws -> String {
        let file = folder + "/" + name + ".c"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = [file, "-o", folder + "/" + name]
        try compiler.run()
        compiler.waitUntilExit()
        return folder + "/" + name
    }

    /// A process table in the shape the sampler's snapshot has, for the names and PIDs.
    private func snapshot() -> Snapshot {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: max(capacity, 64))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let processes = pids.prefix(Int(max(0, count))).compactMap { pid -> ProcessSample? in
            ProcessInspector.identity(pid).map { identity in
                ProcessSample(
                    pid: pid, app: "test", name: identity.name, cpuPercent: 0, footprintBytes: 0, diskReadBPS: 0, diskWriteBPS: 0,
                    energyMW: nil,
                    netInBPS: nil, netOutBPS: nil, gpuPercent: nil
                )
            }
        }
        let system = SystemSample(
            cpu: CPUStats(totalPercent: 0, userPercent: 0, systemPercent: 0, perCorePercent: [], clusters: [], loadAverage: .zero),
            memory: MemoryStats(
                totalBytes: 1, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0, cachedFilesBytes: 0, swapUsedBytes: 0,
                pressure: .normal,
                availableLevel: 100
            ),
            disk: DiskStats(volumes: [], readBPS: 0, writeBPS: 0), network: NetworkStats(inBPS: 0, outBPS: 0, primaryInterface: nil),
            gpu: nil, battery: nil, sensors: nil, thermal: .nominal, uptime: .zero
        )
        return Snapshot(at: Date(), interval: .seconds(1), system: system, apps: [], processes: processes)
    }

    /// Runs what the recorder runs, once a second, until `command` has ended and been recorded.
    private func record(_ command: String, in folder: String, tool: String, interrupt: Duration? = nil) async throws -> [BuildRun] {
        var locator = TestRunLocator()
        var tracker = TestRunTracker()
        let exits = ProcessExitWatcher()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var runs: [BuildRun] = []
        let started = Date()
        var interrupted = false
        for _ in 0 ..< 300 {
            let now = Date()
            let found = locator.processes(in: snapshot()).filter { $0.tool == tool && $0.project == (folder as NSString).lastPathComponent }
            for test in found {
                exits.watch(test.pid)
            }
            if let interrupt, !interrupted, !found.isEmpty, now.timeIntervalSince(started) >= Double(interrupt.components.seconds) {
                for test in found {
                    kill(test.pid, SIGINT)
                }
                interrupted = true
            }
            runs += tracker.observe(found, exits: exits.drain(), at: now, interval: 1)
            if !process.isRunning, found.isEmpty, !runs.isEmpty {
                break
            }
            if !process.isRunning, found.isEmpty, Date().timeIntervalSince(started) > 5 {
                break
            }
            try await Task.sleep(for: .seconds(1))
        }
        process.waitUntilExit()
        return runs
    }

    @Test("Real swift test: passed, failed and cancelled told apart, on a process this isn't the parent of")
    func swiftTest() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder + "/Sources/Lib", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: folder + "/Tests/LibTests", withIntermediateDirectories: true)
        try """
        // swift-tools-version:6.0
        import PackageDescription
        let package = Package(name: "demo", targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])])
        """.write(toFile: folder + "/Package.swift", atomically: true, encoding: .utf8)
        try "public let value = 1\n".write(toFile: folder + "/Sources/Lib/a.swift", atomically: true, encoding: .utf8)
        func tests(_ expected: Int) throws {
            try """
            import Testing
            @testable import Lib
            @Test func slow() async throws { try await Task.sleep(for: .seconds(4)); #expect(value == \(expected)) }
            """.write(toFile: folder + "/Tests/LibTests/t.swift", atomically: true, encoding: .utf8)
        }
        try tests(1)
        let passed = try await record("swift test", in: folder, tool: "swift test")
        #expect(passed.count == 1)
        #expect(passed.first?.outcome == .passed)
        #expect((passed.first?.duration ?? 0) >= 4)
        #expect(passed.first?.isPartial == false)

        let filtered = try await record("swift test --filter slow", in: folder, tool: "swift test")
        #expect(filtered.first?.outcome == .passed)
        #expect(filtered.first?.isPartial == true)

        try tests(2)
        let failed = try await record("swift test", in: folder, tool: "swift test")
        #expect(failed.first?.outcome == .failed)
        #expect(failed.first?.isTimed == false)

        try tests(1)
        let cancelled = try await record("swift test", in: folder, tool: "swift test", interrupt: .seconds(2))
        #expect(cancelled.first?.outcome == .cancelled)
        #expect(cancelled.first?.isTimed == false)
    }

    @Test("Real npm test: one run, with what it starts part of it; a failure seen as one")
    func npmTest() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/npm") else {
            return
        }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try #"{"name":"demo","scripts":{"test":"node t.js"}}"#.write(toFile: folder + "/package.json", atomically: true, encoding: .utf8)
        try "setTimeout(() => process.exit(0), 3000)\n".write(toFile: folder + "/t.js", atomically: true, encoding: .utf8)
        let passed = try await record("/opt/homebrew/bin/npm test", in: folder, tool: "npm test")
        #expect(passed.count == 1)
        #expect(passed.first?.outcome == .passed)
        #expect((passed.first?.duration ?? 0) >= 3)
        try "setTimeout(() => process.exit(1), 3000)\n".write(toFile: folder + "/t.js", atomically: true, encoding: .utf8)
        let failed = try await record("/opt/homebrew/bin/npm test", in: folder, tool: "npm test")
        #expect(failed.first?.outcome == .failed)
    }

    @Test("A stand-in for mysqld with a real folder: the whole read, without a database")
    func databaseStandIn() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let data = folder + "/data"
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        try "16\n".write(toFile: data + "/ibdata1", atomically: true, encoding: .utf8)
        // A small program under the name: what the process table shows for a real one. (macOS kills
        // copies of its own binaries.)
        let binary = try compile("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n", named: "mysqld", in: folder)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.currentDirectoryURL = URL(fileURLWithPath: data)
        try process.run()
        defer { process.terminate() }
        try await Task.sleep(for: .milliseconds(400))
        let found = await LiveLocalDatabases().databases().first { $0.pid == process.processIdentifier }
        let database = try #require(found)
        #expect(database.engine == .mysql && database.isReadable && database.memoryBytes > 0)
        #expect(database.dataDirectory == data && database.dataSource == .workingDirectory)
        #expect(database.connections == 0 && database.startedAt != nil)
        let use = await LiveLocalDatabases().diskUse(of: database)
        #expect((use?.bytes ?? 0) > 0)
        #expect(use?.lastWrite != nil)
    }

    @Test("A stand-in for ssh: the arguments and a listening port, with no connection made")
    func sshStandIn() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        // A small listener under ssh's name: its arguments are ssh's to parse, and nothing connects.
        let binary = try compile("""
        #include <arpa/inet.h>
        #include <sys/socket.h>
        #include <unistd.h>
        int main(void) {
            int s = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in a = {0};
            a.sin_family = AF_INET;
            a.sin_port = htons(54721);
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            bind(s, (struct sockaddr *)&a, sizeof a);
            listen(s, 1);
            sleep(30);
            return 0;
        }
        """, named: "ssh", in: folder)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-N", "-L", "54722:db.internal:5432", "-o", "ProxyCommand=SECRET", "robin@example.com", "SECRETCOMMAND"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }
        try await Task.sleep(for: .milliseconds(400))
        let sessions = await LiveRemoteSessions().sessions()
        let session = try #require(sessions.first { $0.pid == process.processIdentifier })
        #expect(session.startedAt != nil)
        #expect(session.host == "example.com")
        #expect(!String(describing: session).contains("SECRET"))
        // Named but not listening, and listening but not named.
        #expect(session.forwards.first { $0.listenPort == 54722 }?.isListening == false)
        let forward = try #require(session.forwards.first { $0.listenPort == 54721 })
        #expect(forward.isFromSocketOnly && forward.isListening == true)
    }
}
