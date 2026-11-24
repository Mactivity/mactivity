import Foundation
@testable import Startup
import Testing

/// A temporary `Library` with a `LaunchAgents` folder, removed afterwards.
struct TemporaryLibrary {
    let root: URL
    let agents: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactivity-startup-\(UUID().uuidString)")
            .appendingPathComponent("Library")
        agents = root.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    }

    func write(_ fixture: String, as name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? agents).appendingPathComponent(name)
        try StartupFixtures.data(fixture).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

@Suite("Disable and enable user agents")
struct UserLaunchAgentToggleTests {
    @Test("Disable moves the plist aside, Enable moves it back, byte for byte")
    func roundTrip() throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let original = try library.write("keepalive-true", as: "homebrew.mxcl.postgresql@17.plist")
        let bytes = try Data(contentsOf: original)
        let toggle = UserLaunchAgentToggle(agentsDirectory: library.agents)

        let moved = try toggle.disable(plistAt: original)
        #expect(moved.deletingLastPathComponent().lastPathComponent == "LaunchAgents (Disabled by Mactivity)")
        #expect(moved.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == library.root.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: moved) == bytes)

        let back = try toggle.enable(plistAt: moved)
        #expect(back.standardizedFileURL == original.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        #expect(try Data(contentsOf: back) == bytes)
    }

    @Test("The item-level API round-trips through the real source's view of the folders")
    func itemRoundTrip() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        _ = try library.write("keepalive-true", as: "homebrew.mxcl.postgresql@17.plist")
        let folders = LaunchdStartupSource.Folders(
            home: library.root.deletingLastPathComponent(),
            userLaunchAgents: library.agents,
            launchAgents: library.root.appendingPathComponent("none-1"),
            launchDaemons: library.root.appendingPathComponent("none-2"),
            systemLaunchAgents: library.root.appendingPathComponent("none-3"),
            systemLaunchDaemons: library.root.appendingPathComponent("none-4"),
            applicationFolders: []
        )
        let source = LaunchdStartupSource(folders: folders, runningExecutables: { [] }, includesMainApp: false)
        let toggle = UserLaunchAgentToggle(agentsDirectory: library.agents)

        let before = try #require(try await source.items().first)
        #expect(before.location == .userLaunchAgents)
        try await toggle.disable(before)

        let disabled = try #require(try await source.items().first)
        #expect(disabled.location == .disabledByMactivity)
        #expect(disabled.state == .disabledByMactivity)
        #expect(disabled.label == before.label)
        await #expect(throws: UserLaunchAgentToggle.ToggleError.self) { try await toggle.disable(disabled) }

        try await toggle.enable(disabled)
        let after = try #require(try await source.items().first)
        #expect(after.id == before.id)
        #expect(after.location == .userLaunchAgents)
    }

    @Test("Refuses files outside the agents folder, and never overwrites")
    func refuses() throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let toggle = UserLaunchAgentToggle(agentsDirectory: library.agents)
        let outside = try library.write("program", as: "com.docker.vmnetd.plist", in: library.root)
        #expect(throws: UserLaunchAgentToggle.ToggleError.notInFolder("com.docker.vmnetd.plist")) {
            try toggle.disable(plistAt: outside)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))

        let nested = library.agents.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let deeper = try library.write("program", as: "deep.plist", in: nested)
        #expect(throws: UserLaunchAgentToggle.ToggleError.notInFolder("deep.plist")) { try toggle.disable(plistAt: deeper) }

        let sneaky = library.agents.appendingPathComponent("../com.docker.vmnetd.plist")
        #expect(throws: UserLaunchAgentToggle.ToggleError.notInFolder("com.docker.vmnetd.plist")) { try toggle.disable(plistAt: sneaky) }

        let agent = try library.write("program", as: "a.plist")
        let moved = try toggle.disable(plistAt: agent)
        _ = try library.write("program-arguments", as: "a.plist")
        #expect(throws: UserLaunchAgentToggle.ToggleError.alreadyExists("a.plist")) { try toggle.enable(plistAt: moved) }
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(FileManager.default.fileExists(atPath: agent.path))
    }

    @Test("Items outside ~/Library/LaunchAgents can't be disabled")
    func onlyUserAgents() async throws {
        let library = try TemporaryLibrary()
        defer { library.remove() }
        let toggle = UserLaunchAgentToggle(agentsDirectory: library.agents)
        let daemon = StartupItem(
            id: "/Library/LaunchDaemons/x.plist", label: "x", name: "x", kind: .daemon, location: .launchDaemons,
            plistPath: "/Library/LaunchDaemons/x.plist", executablePath: nil, arguments: [], schedule: .onDemand, plist: nil,
            owner: .unknown, state: .on, loginItemsStatus: nil, isRunning: nil, flags: []
        )
        #expect(!daemon.canDisable)
        await #expect(throws: UserLaunchAgentToggle.ToggleError.notInFolder("x")) { try await toggle.disable(daemon) }
    }

    @Test("The simulated source disables and enables in memory")
    func simulated() async throws {
        let source = SimulatedStartupSource()
        let agent = try #require(try await source.items().first { $0.canDisable })
        try await source.disable(agent)
        let disabled = try #require(try await source.items().first { $0.label == agent.label })
        #expect(disabled.state == .disabledByMactivity)
        try await source.enable(disabled)
        #expect(try await source.items().first { $0.label == agent.label }?.state == agent.state)
    }
}
