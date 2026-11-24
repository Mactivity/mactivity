import Core
import Darwin
import Foundation
import Projects
import Simulated
import Testing
@testable import UI

@MainActor
@Suite("Projects")
struct ProjectsUITests {
    @Test("Summary wording", arguments: [
        ([Int](), "No dev servers running"),
        ([0], "1 dev server · working"),
        ([42], "1 dev server · all idle · stop them to get back 1.0 GB and port 3000."),
        ([0, 42, 20], "3 dev servers · 2 idle · stop the idle ones to get back 2.0 GB and ports 3001 and 3002."),
    ] as [([Int], String)])
    func summary(idleMinutes: [Int], expected: String) {
        let servers = idleMinutes.enumerated().map { index, minutes in
            DevServer(
                pid: Int32(index + 10),
                name: "node",
                command: "node",
                runtime: .node,
                ports: [UInt16(3000 + index)],
                memoryBytes: 1_073_741_824,
                startedAt: Date(),
                cpuTime: .zero,
                activity: minutes == 0 ? .working : .idle(minutes: minutes),
                stopTarget: .processGroup(Int32(index + 10))
            )
        }
        let projects = servers.isEmpty ? [] : [Project(rootPath: "/p", name: "p", servers: servers)]
        let text = ProjectText.summary(projects)
        #expect(text == expected)
    }

    @Test("Port lists", arguments: [
        ([UInt16](), "no ports"),
        ([80], "port 80"),
        ([80, 443], "ports 80 and 443"),
        ([80, 443, 8080], "ports 80, 443, and 8080")
    ])
    func ports(ports: [UInt16], expected: String) {
        #expect(ProjectText.ports(ports) == expected)
    }

    @Test("Stopping goes through the confirmation, and nothing happens without it")
    func confirmation() async throws {
        let servers = SimulatedDevServers()
        let model = ProjectsModel(source: servers)
        let action = ConfirmedAction(terminator: servers)
        await model.refresh()
        let before = model.projects.flatMap(\.servers).count
        let storefront = try #require(model.projects.first { $0.name == "storefront-web" })
        model.stop(storefront.servers, label: storefront.name, through: action)
        #expect(action.pending != nil)
        action.cancel()
        await model.refresh()
        #expect(model.projects.flatMap(\.servers).count == before)

        model.stop(storefront.servers, label: storefront.name, through: action)
        await action.confirm()
        for _ in 0 ..< 100 where model.toast == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.projects.contains { $0.name == "storefront-web" })
        #expect(model.toast?.hasPrefix("Storefront-web stopped.") == true)
        #expect(model.toast?.contains("ports 4322 and 6006 are free") == true)
    }

    /// M6 done-when: stopping a real dev server frees its port, verified by re-scan.
    @Test("The dialog's order of events still stops: accept on click, then the dismissal's cancel, then perform")
    func dialogOrder() async throws {
        // SwiftUI runs the button's action, then dismisses the dialog, whose binding calls
        // cancel(), and only then runs the async work. Before accept(), that cancel cleared the
        // request first and Quit/Stop silently did nothing (2026-09-28).
        let servers = SimulatedDevServers()
        let model = ProjectsModel(source: servers)
        let action = ConfirmedAction(terminator: servers)
        await model.refresh()
        let storefront = try #require(model.projects.first { $0.name == "storefront-web" })
        model.stop(storefront.servers, label: storefront.name, through: action)
        let accepted = try #require(action.accept())
        action.cancel()
        await action.perform(accepted)
        for _ in 0 ..< 100 where model.toast == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.refresh()
        #expect(!model.projects.contains { $0.name == "storefront-web" })
        // Nothing to accept once it's taken: a second click can't run it twice.
        #expect(action.accept() == nil)
    }

    @Test("A real listening process in a project folder is found, stopped, and its port is free")
    func endToEnd() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mactivity-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("package.json"))
        let port = try freePort()
        let pid = try spawnInOwnGroup("/usr/bin/nc", ["nc", "-l", String(port)], directory: folder.path)
        defer { kill(pid, SIGKILL) }

        let monitor = ProjectMonitor()
        await monitor.observe(snapshot(with: pid))
        var found: Project?
        for _ in 0 ..< 50 {
            found = try await monitor.projects().first { $0.ports.contains(port) }
            if found != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let project = try #require(found)
        #expect(project.rootPath.hasSuffix(folder.lastPathComponent))
        #expect(project.servers.first?.stopTarget == .processGroup(pid))

        let model = ProjectsModel(source: monitor)
        let action = ConfirmedAction(terminator: SignalTerminator())
        model.stop(project.servers, label: project.name, through: action)
        await action.confirm()
        for _ in 0 ..< 200 where model.toast == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        // nc is our child, so reap it; the terminator already treats a zombie as stopped.
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == pid)
        #expect(try await monitor.projects().allSatisfy { !$0.ports.contains(port) })
        #expect(model.toast?.contains("port \(port) is free") == true)
    }

    private func services(terminator: any ProcessTerminator) -> AppServices {
        AppServices(
            metrics: LiveMetrics(source: SimulatedSnapshotSource(), isSimulated: true), history: SimulatedHistoryStore(),
            alertLog: SimulatedAlertStateStore(), alertSettings: .defaults, projects: SimulatedDevServers(), terminator: terminator
        )
    }

    private func waitForToast(_ services: AppServices) async throws {
        for _ in 0 ..< 300 where services.toast == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Quit on a process row asks first, then stops just that process")
    func quitProcess() async throws {
        let pid = try spawnInOwnGroup("/bin/sleep", ["sleep", "60"], directory: "/tmp")
        defer { kill(pid, SIGKILL) }
        let services = services(terminator: SignalTerminator())
        let process = ProcessSample(
            pid: pid,
            app: "other:sleep",
            name: "sleep",
            cpuPercent: 0,
            footprintBytes: 0,
            diskReadBPS: 0,
            diskWriteBPS: 0,
            energyMW: nil,
            netInBPS: nil,
            netOutBPS: nil,
            gpuPercent: nil
        )
        services.requestQuit(process, mode: .quit)
        #expect(services.confirmedAction.pending?.title == "Quit “sleep” (PID \(pid))?")
        #expect(kill(pid, 0) == 0)
        await services.confirmedAction.confirm()
        try await waitForToast(services)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == pid)
        #expect(services.toast == "“sleep” quit.")
    }

    @Test("Force Quit on an app row with no GUI app signals its processes")
    func forceQuitOtherApp() async throws {
        let first = try spawnInOwnGroup("/bin/sleep", ["sleep", "60"], directory: "/tmp")
        let second = try spawnInOwnGroup("/bin/sleep", ["sleep", "61"], directory: "/tmp")
        defer {
            kill(first, SIGKILL)
            kill(second, SIGKILL)
        }
        let services = services(terminator: SignalTerminator())
        let app = AppAggregate(
            app: .other(executableName: "sleep"),
            processCount: 2,
            cpuPercent: 0,
            memoryBytes: 0,
            energyMW: nil,
            diskReadBPS: 0,
            diskWriteBPS: 0,
            netInBPS: nil,
            netOutBPS: nil,
            gpuPercent: nil
        )
        services.requestQuit(app, pids: [first, second], mode: .forceQuit)
        #expect(services.confirmedAction.pending?.title == "Force Quit sleep?")
        await services.confirmedAction.confirm()
        try await waitForToast(services)
        var status: Int32 = 0
        #expect(waitpid(first, &status, WNOHANG) == first)
        #expect(waitpid(second, &status, WNOHANG) == second)
        #expect(services.toast == "sleep was force quit.")
    }

    @Test("The macOS row can't be quit without the helper")
    func systemRow() {
        let services = services(terminator: SimulatedProcessTerminator())
        #expect(!services.canTerminate(.system))
        let row = AppAggregate(
            app: .system,
            processCount: 900,
            cpuPercent: 3,
            memoryBytes: 0,
            energyMW: nil,
            diskReadBPS: 0,
            diskWriteBPS: 0,
            netInBPS: nil,
            netOutBPS: nil,
            gpuPercent: nil
        )
        services.requestQuit(row, pids: [100], mode: .forceQuit)
        #expect(services.confirmedAction.pending == nil)
    }

    @Test("The terminator refuses launchd, Mactivity, and Mactivity's process group")
    func refusals() async {
        let terminator = SignalTerminator()
        for target in [TerminationTarget.process(1), .process(getpid()), .processGroup(getpgrp()), .processGroup(1)] {
            await #expect(throws: TerminationError.refused) {
                try await terminator.terminate(ConfirmedTermination(target: target, mode: .quit, confirmedAt: Date()))
            }
        }
    }

    private func freePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.bind(socket, pointer, length) == 0 && getsockname(socket, pointer, &length) == 0
            }
        }
        try #require(bound)
        return UInt16(bigEndian: address.sin_port)
    }

    /// posix_spawn with its own process group, so stopping the group can't touch the test runner.
    private func spawnInOwnGroup(_ path: String, _ arguments: [String], directory: String) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var cArguments = arguments.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, &cArguments, environ)
        try #require(status == 0)
        return pid
    }

    private func snapshot(with pid: pid_t) -> Snapshot {
        let system = SystemSample(
            cpu: CPUStats(totalPercent: 0, userPercent: 0, systemPercent: 0, perCorePercent: [0], clusters: [], loadAverage: .zero),
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
            pid: pid,
            app: "other:nc",
            name: "nc",
            cpuPercent: 0,
            footprintBytes: 0,
            diskReadBPS: 0,
            diskWriteBPS: 0,
            energyMW: nil,
            netInBPS: nil,
            netOutBPS: nil,
            gpuPercent: nil
        )
        return Snapshot(at: Date(), interval: .seconds(5), system: system, apps: [], processes: [process])
    }

    @Test("The menu bar's status keeps one unit: Idle 3h 10m reads Idle 3h")
    func shortIdle() {
        #expect(ProjectActivity.idle(minutes: 190).shortTitle == ProjectActivity.idle(minutes: 180).title)
        #expect(ProjectActivity.idle(minutes: 3000).shortTitle == ProjectActivity.idle(minutes: 2880).title)
        #expect(ProjectActivity.idle(minutes: 18).shortTitle == ProjectActivity.idle(minutes: 18).title)
        #expect(ProjectActivity.working.shortTitle == ProjectActivity.working.title)
    }
}
