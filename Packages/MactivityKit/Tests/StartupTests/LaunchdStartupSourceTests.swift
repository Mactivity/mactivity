import Core
import Foundation
@testable import Startup
import Testing

@Suite("Real startup source")
struct LaunchdStartupSourceTests {
    /// A fake Mac on disk: agents, daemons, an app with a login item helper and an embedded agent.
    @Test("Reads every folder and the helpers inside installed apps")
    func temporaryMac() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let root = library.root.deletingLastPathComponent()
        let manager = FileManager.default
        let launchAgents = root.appendingPathComponent("LibraryAgents")
        let launchDaemons = root.appendingPathComponent("LibraryDaemons")
        let systemAgents = root.appendingPathComponent("SystemAgents")
        let applications = root.appendingPathComponent("Applications")
        let app = applications.appendingPathComponent("Tool.app")
        let helper = app.appendingPathComponent("Contents/Library/LoginItems/ToolHelper.app")
        for folder in [
            launchAgents,
            launchDaemons,
            systemAgents,
            app.appendingPathComponent("Contents/Library/LaunchAgents"),
            helper.appendingPathComponent("Contents/MacOS"),
        ] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try writeInfo(["CFBundleIdentifier": "com.example.tool"], to: app)
        try writeInfo(["CFBundleIdentifier": "com.example.tool.helper", "CFBundleExecutable": "ToolHelper"], to: helper)
        try Data().write(to: helper.appendingPathComponent("Contents/MacOS/ToolHelper"))

        _ = try library.write("keepalive-true", as: "homebrew.mxcl.postgresql@17.plist")
        _ = try library.write("empty", as: "com.google.keystone.agent.plist")
        try manager.createSymbolicLink(at: library.agents.appendingPathComponent("README"), withDestinationURL: root)
        _ = try library.write("disabled", as: "com.microsoft.update.agent.plist", in: launchAgents)
        _ = try library.write("program", as: "com.docker.vmnetd.plist", in: launchDaemons)
        _ = try library.write("program", as: "com.apple.one.plist", in: systemAgents)
        _ = try library.write("program", as: "com.apple.two.plist", in: systemAgents)
        let embedded = try library.write(
            "bundle-program", as: "com.example.tool.agent.plist", in: app.appendingPathComponent("Contents/Library/LaunchAgents")
        )

        let helperExecutable = helper.appendingPathComponent("Contents/MacOS/ToolHelper").resolvingSymlinksInPath().path
        let source = LaunchdStartupSource(
            folders: LaunchdStartupSource.Folders(
                home: root, userLaunchAgents: library.agents, launchAgents: launchAgents, launchDaemons: launchDaemons,
                systemLaunchAgents: systemAgents, systemLaunchDaemons: root.appendingPathComponent("missing"),
                applicationFolders: [applications]
            ),
            runningExecutables: { [helperExecutable] },
            includesMainApp: false
        )
        let items = try await source.items()
        #expect(items.map(\.label).sorted() == [
            "com.docker.vmnetd", "com.example.tool.helper", "com.google.keystone.agent", "com.microsoft.update.agent",
            "com.ollama.ollama", "homebrew.mxcl.postgresql@17",
        ])
        #expect(try await source.macOSItemCount() == 2)

        let loginItem = try #require(items.first { $0.kind == .loginItem })
        #expect(loginItem.owner.name == "Tool")
        #expect(loginItem.isRunning == true)
        #expect(loginItem.startsWithMac)

        let appHelper = try #require(items.first { $0.id == embedded.path })
        #expect(appHelper.kind == .appHelper)
        #expect(appHelper.owner.bundleID == "com.example.tool")
        #expect(appHelper.isBroken, "Squirrel isn't in the fake app")

        // Empty: switched off, not broken (D-132).
        #expect(items.first { $0.label == "com.google.keystone.agent" }?.flags.map(\.kind) == [.empty])
        #expect(items.first { $0.label == "com.google.keystone.agent" }?.state == .disabledInPlist)
        #expect(items.first { $0.label == "com.microsoft.update.agent" }?.state == .disabledInPlist)
    }

    @Test("Running executables from a snapshot's readings")
    func fromReadings() {
        let reading = ProcessReading(
            pid: 42, parentPID: 1, uid: 501, name: "postgres", executablePath: "/opt/homebrew/opt/postgresql@17/bin/postgres",
            startTime: Date(), cpuTime: .zero, footprintBytes: 0, diskReadBytes: 0, diskWriteBytes: 0, energyNJ: 0, isComplete: true
        )
        #expect(RunningExecutables.paths(from: [reading]) == ["/opt/homebrew/opt/postgresql@17/bin/postgres"])
    }

    @Test("proc_pidpath sees this test process")
    func currentProcesses() throws {
        let paths = RunningExecutables.current()
        let me = try #require(Bundle.main.executableURL?.resolvingSymlinksInPath().path)
        #expect(paths.contains(me))
    }

    /// Reads this Mac's real folders. Skipped on CI, where the folders are the runner's.
    @Test(
        "The live audit returns without throwing",
        .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil, "reads this Mac: make test-live")
    )
    func live() async throws {
        let clock = ContinuousClock()
        let source = LaunchdStartupSource()
        var items: [StartupItem] = []
        var count = 0
        let elapsed = try await clock.measure {
            items = try await source.items()
            count = try await source.macOSItemCount()
        }
        #expect(count > 0, "macOS ships hundreds of launchd plists")
        #expect(Set(items.map(\.id)).count == items.count, "IDs are unique")
        #expect(elapsed < .seconds(5))
        // Counts only, never paths, for the milestone notes: MACTIVITY_STARTUP_REPORT=/some/file.txt
        if let report = ProcessInfo.processInfo.environment["MACTIVITY_STARTUP_REPORT"] {
            let summary = StartupSummary(items: items, macOSCount: count)
            let kinds = StartupKind.allCases.map { kind in "\(kind.title): \(items.count { $0.kind == kind })" }
            let states = Dictionary(grouping: items, by: \.state).map { "\($0.key.title): \($0.value.count)" }.sorted()
            let lines = [
                summary.line, summary.footnote, "Listed: \(items.count)", kinds.joined(separator: ", "),
                states.joined(separator: ", "), "Running: \(items.count { $0.isRunning == true })",
                "Unknown owner: \(items.count { !$0.owner.isKnown })", "Took: \(elapsed)",
            ]
            try lines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
        }
    }

    private func writeInfo(_ info: [String: String], to bundle: URL) throws {
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
