import Foundation
@testable import Startup
import Testing

@Suite("Owner resolution")
struct OwnerResolutionTests {
    let apps = StartupFixtures.apps

    @Test("AssociatedBundleIdentifiers comes first, case-insensitively")
    func associated() {
        let plist = LaunchdPlist(associatedBundleIdentifiers: ["com.nothing.installed", "COM.DOCKER.DOCKER"])
        let owner = StartupResolution.owner(
            plist: plist, label: "us.zoom.whatever", executablePath: "/Applications/zoom.us.app/Contents/MacOS/zoom",
            containingAppPath: nil, apps: apps
        )
        #expect(owner.name == "Docker")
        #expect(owner.evidence == .associatedBundleIdentifier)
        #expect(owner.bundlePath == "/Applications/Docker.app")
    }

    @Test("Then the executable's outermost .app, even outside /Applications")
    func executablePath() {
        let nested = StartupResolution.owner(
            plist: LaunchdPlist(), label: "x.y",
            executablePath: "/Applications/Ollama.app/Contents/Helpers/Inner.app/Contents/MacOS/Inner",
            containingAppPath: nil, apps: apps
        )
        #expect(nested.name == "Ollama")
        #expect(nested.evidence == .executablePath)

        // Not in the installed list, but readable on disk.
        let updater = StartupResolution.owner(
            plist: LaunchdPlist(associatedBundleIdentifiers: ["com.google.GoogleUpdater"]),
            label: "com.google.GoogleUpdater.wake",
            executablePath: StartupFixtures.googleUpdater,
            containingAppPath: nil, apps: apps,
            appAt: { $0.hasSuffix("GoogleUpdater.app") ? InstalledApp(
                name: "GoogleUpdater",
                bundleID: "com.google.GoogleUpdater",
                path: $0
            ) : nil }
        )
        #expect(updater.name == "GoogleUpdater")
        #expect(updater.evidence == .executablePath)
    }

    @Test("Then the app the plist ships in")
    func containingApp() {
        let owner = StartupResolution.owner(
            plist: LaunchdPlist(), label: "com.unrelated.helper",
            executablePath: "/Library/PrivilegedHelperTools/com.unrelated.helper",
            containingAppPath: "/Applications/Docker.app", apps: apps
        )
        #expect(owner.name == "Docker")
        #expect(owner.evidence == .containingApp)
    }

    @Test("A leftover whose app is gone is grouped under that app's name, not guessed from its label")
    func missingApp() {
        let owner = StartupResolution.owner(
            plist: LaunchdPlist(), label: "com.microsoft.SyncReporter",
            executablePath: "/Applications/OneDrive.app/Contents/SyncReporter.app/Contents/MacOS/SyncReporter",
            containingAppPath: nil, apps: apps
        )
        #expect(owner.name == "OneDrive")
        #expect(owner.evidence == .missingApp)
        #expect(owner.isKnown)
        #expect(!owner.isInstalled)
        #expect(owner.id == "missing:OneDrive")
    }

    @Test("Then the longest matching label prefix")
    func labelPrefix() {
        let docker = StartupResolution.owner(
            plist: LaunchdPlist(), label: "com.docker.vmnetd", executablePath: "/Library/PrivilegedHelperTools/com.docker.vmnetd",
            containingAppPath: nil, apps: apps
        )
        #expect(docker.name == "Docker")
        #expect(docker.evidence == .labelPrefix)

        let zoom = StartupResolution.owner(
            plist: nil, label: "us.zoom.ZoomDaemon", executablePath: nil, containingAppPath: nil, apps: apps
        )
        #expect(zoom.name == "zoom.us")

        // Two Microsoft apps share com.microsoft: the pick is stable (shortest ID, then name).
        let microsoft = StartupResolution.owner(
            plist: nil, label: "com.microsoft.update.agent", executablePath: nil, containingAppPath: nil, apps: apps
        )
        #expect(microsoft.name == "Microsoft Word")

        #expect(StartupResolution.appMatching(label: "com.google.keystone.agent", in: apps)?.name == "Google Chrome")
    }

    @Test("Shared hosting prefixes and one-part labels never guess")
    func noGuess() {
        #expect(StartupResolution.appMatching(label: "com.github.someone.tool", in: apps) == nil)
        #expect(StartupResolution.appMatching(label: "postgres", in: apps) == nil)
        let owner = StartupResolution.owner(
            plist: LaunchdPlist(), label: "homebrew.mxcl.postgresql@17",
            executablePath: "/opt/homebrew/opt/postgresql@17/bin/postgres", containingAppPath: nil, apps: apps
        )
        #expect(owner == .unknown)
        #expect(!owner.isKnown)
    }

    @Test("Outermost .app in a path")
    func outermost() {
        #expect(StartupResolution.outermostApp(in: "/Applications/A.app/Contents/B.app/Contents/MacOS/b") == "/Applications/A.app")
        #expect(StartupResolution.outermostApp(in: "/usr/local/bin/tool") == nil)
    }
}

@Suite("Broken and unusual")
struct StartupFlagTests {
    let home = StartupFixtures.home

    @Test("A missing executable is broken")
    func missing() {
        let flags = StartupResolution.flags(
            declared: "/Library/PrivilegedHelperTools/com.oldvpn.helper",
            executablePath: "/Library/PrivilegedHelperTools/com.oldvpn.helper",
            scriptPath: nil, home: home, exists: { _ in false }
        )
        #expect(flags.map(\.kind) == [.broken])
    }

    @Test("No program at all is broken; so is a bare command that isn't on launchd's path")
    func noProgram() {
        #expect(StartupResolution.flags(declared: nil, executablePath: nil, scriptPath: nil, home: home, exists: { _ in true })
            .map(\.kind) == [.broken])
        let (declared, path) = StartupResolution.executable(
            for: LaunchdPlist(programArguments: ["nosuchtool"]), bundlePath: nil, exists: { _ in false }
        )
        #expect(declared == "nosuchtool")
        #expect(path == nil)
        #expect(StartupResolution.flags(declared: declared, executablePath: path, scriptPath: nil, home: home, exists: { _ in false })
            .map(\.kind) == [.broken])
    }

    @Test("Bare command names resolve through /usr/bin:/bin:/usr/sbin:/sbin")
    func standardPath() {
        let (_, path) = StartupResolution.executable(
            for: LaunchdPlist(programArguments: ["sh", "-c", "true"]), bundlePath: nil, exists: { $0 == "/bin/sh" }
        )
        #expect(path == "/bin/sh")
    }

    @Test(
        "Usual locations aren't flagged",
        arguments: [
            "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
            "/Library/PrivilegedHelperTools/com.docker.vmnetd",
            "/usr/local/bin/tailscaled",
            "/opt/homebrew/opt/postgresql@17/bin/postgres",
            "/Users/demo/Applications/Tool.app/Contents/MacOS/Tool",
            "/usr/bin/python3",
        ]
    )
    func usual(_ path: String) {
        #expect(StartupResolution.flags(declared: path, executablePath: path, scriptPath: nil, home: home, exists: { _ in true }).isEmpty)
    }

    @Test(
        "Anywhere else is an unusual location",
        arguments: [
            "/Users/demo/.local/share/sync-daemon/syncd",
            StartupFixtures.googleUpdater,
            "/tmp/x",
            "/private/var/tmp/.hidden/agent",
        ]
    )
    func unusual(_ path: String) {
        let flags = StartupResolution.flags(declared: path, executablePath: path, scriptPath: nil, home: home, exists: { _ in true })
        #expect(flags.map(\.kind) == [.unusualLocation])
    }

    @Test("An interpreter's script is checked too")
    func script() {
        let script = StartupResolution.scriptPath(executable: "/usr/bin/python3", arguments: ["-u", "/Users/demo/Scripts/backup.py"])
        #expect(script == "/Users/demo/Scripts/backup.py")
        let flags = StartupResolution.flags(
            declared: "/usr/bin/python3", executablePath: "/usr/bin/python3", scriptPath: script, home: home,
            exists: { $0 == "/usr/bin/python3" }
        )
        #expect(flags.map(\.kind) == [.broken, .unusualLocation])
        #expect(StartupResolution.scriptPath(executable: "/bin/sh", arguments: ["-c", "/Users/demo/x.sh"]) == nil)
        #expect(StartupResolution.scriptPath(executable: "/usr/local/bin/tool", arguments: ["/Users/demo/x"]) == nil)
    }

    @Test("Home paths are abbreviated in the reason")
    func abbreviate() {
        #expect(StartupResolution.folder(of: "/Users/demo/Library/Application Support/Google/Updater/x", home: home)
            == "~/Library/Application Support")
        #expect(StartupResolution.folder(of: "/Users/demo/.local/syncd", home: home) == "~/.local")
        #expect(StartupResolution.folder(of: "/tmp/x", home: home) == "/tmp")
    }
}

@Suite("Items from fixtures")
struct StartupScannerTests {
    @Test("A user agent: executable, owner, schedule, unusual location, running")
    func userAgent() throws {
        let executable = StartupFixtures.googleUpdater
        let env = StartupFixtures.environment(existing: [executable], running: [executable], status: { _ in .enabled })
        let item = try StartupScanner.item(
            plistPath: "/Users/demo/Library/LaunchAgents/com.google.GoogleUpdater.wake.plist",
            data: StartupFixtures.data("program-arguments"), location: .userLaunchAgents, environment: env
        )
        #expect(item.kind == .agent)
        #expect(item.label == "com.google.GoogleUpdater.wake")
        #expect(item.executablePath == executable)
        #expect(item.owner.name == "GoogleUpdater")
        #expect(item.schedule == .interval(seconds: 3600, atLoad: false))
        #expect(item.state == .on)
        #expect(item.isRunning == true)
        #expect(item.isUnusual)
        #expect(!item.isBroken)
        #expect(item.canDisable)
        #expect(!item.canEnable)
        #expect(item.startsWithMac)
    }

    @Test("An app helper resolves BundleProgram inside its app and needs registering")
    func appHelper() throws {
        let squirrel = "/Applications/Ollama.app/Contents/Frameworks/Squirrel.framework/Versions/A/Squirrel"
        let data = try StartupFixtures.data("bundle-program")
        let plistPath = "/Applications/Ollama.app/Contents/Library/LaunchAgents/com.ollama.ollama.plist"
        let registered = StartupScanner.item(
            plistPath: plistPath, data: data, location: .appBundle, containingAppPath: "/Applications/Ollama.app",
            environment: StartupFixtures.environment(existing: [squirrel], running: [squirrel], status: { _ in .enabled })
        )
        #expect(registered.kind == .appHelper)
        #expect(registered.executablePath == squirrel)
        #expect(registered.owner.name == "Ollama")
        #expect(registered.state == .on)
        #expect(registered.isRunning == true)
        #expect(registered.flags.isEmpty)
        #expect(!registered.canDisable)

        let unregistered = StartupScanner.item(
            plistPath: plistPath, data: data, location: .appBundle, containingAppPath: "/Applications/Ollama.app",
            environment: StartupFixtures.environment(existing: [squirrel], status: { _ in .notRegistered })
        )
        #expect(unregistered.state == .notRegistered)
        #expect(!unregistered.startsWithMac)
    }

    @Test("Login Items says it's turned off; the plist says Disabled")
    func states() throws {
        let program = "/Library/Application Support/zoom.us/ZoomUpdater"
        let off = try StartupScanner.item(
            plistPath: "/Library/LaunchAgents/com.zoom.updater.plist", data: StartupFixtures.data("calendar-array"),
            location: .launchAgents, environment: StartupFixtures.environment(existing: [program], status: { _ in .requiresApproval })
        )
        #expect(off.state == .turnedOffInSettings)
        #expect(off.owner == .unknown, "com.zoom isn't us.zoom")
        #expect(!off.startsWithMac)
        #expect(!off.canDisable)

        let disabled = try StartupScanner.item(
            plistPath: "/Library/LaunchAgents/com.microsoft.update.agent.plist", data: StartupFixtures.data("disabled"),
            location: .launchAgents, environment: StartupFixtures.environment(existing: [], status: { _ in .enabled })
        )
        #expect(disabled.state == .disabledInPlist)
        #expect(disabled.isBroken)
    }

    @Test("A daemon that isn't listed in Login Items still loads")
    func unlistedDaemon() throws {
        let item = try StartupScanner.item(
            plistPath: "/Library/LaunchDaemons/com.docker.vmnetd.plist", data: StartupFixtures.data("program"),
            location: .launchDaemons,
            environment: StartupFixtures.environment(
                existing: ["/Library/PrivilegedHelperTools/com.docker.vmnetd"],
                status: { _ in .notFound }
            )
        )
        #expect(item.kind == .daemon)
        #expect(item.state == .on)
        #expect(item.isRunning == false)
        #expect(StartupText.schedule(item.schedule, kind: item.kind) == "At startup")
    }

    @Test("Shared executables can't say whether they're running")
    func shared() throws {
        let env = StartupFixtures.environment(
            existing: ["/usr/bin/python3", "/Users/demo/Scripts/backup_notes.py"], running: ["/usr/bin/python3"]
        )
        let item = try StartupScanner.item(
            plistPath: "/Users/demo/Library/LaunchAgents/com.example.backup-notes.plist", data: StartupFixtures.data("calendar-dict"),
            location: .userLaunchAgents, environment: env
        )
        #expect(item.isRunning == nil)
        #expect(item.isUnusual)
        #expect(item.owner == .unknown)
    }

    @Test("An empty plist is switched off, not broken; an unreadable one is broken; both named after their file (D-132)")
    func broken() throws {
        let env = StartupFixtures.environment(existing: [])
        let empty = try StartupScanner.item(
            plistPath: "/Users/demo/Library/LaunchAgents/com.google.keystone.agent.plist", data: StartupFixtures.data("empty"),
            location: .userLaunchAgents, environment: env
        )
        #expect(empty.label == "com.google.keystone.agent")
        #expect(!empty.isBroken)
        #expect(empty.flags.map(\.kind) == [.empty])
        #expect(empty.state == .disabledInPlist)
        #expect(!empty.startsWithMac)
        #expect(StartupSummary(items: [empty], macOSCount: 0).broken == 0)
        #expect(empty.owner.name == "Google Chrome")
        #expect(empty.owner.evidence == .labelPrefix)

        let garbage = try StartupScanner.item(
            plistPath: "/Library/LaunchDaemons/com.gone.helper.plist", data: StartupFixtures.data("not-a-plist"),
            location: .launchDaemons, environment: env
        )
        #expect(garbage.plist == nil)
        #expect(garbage.isBroken)
        #expect(garbage.kind == .daemon)
    }

    @Test("A login item helper's state is unknown; it counts only while running")
    func loginItemHelper() {
        let bundle = "/Applications/Docker.app/Contents/Library/LoginItems/DockerHelper.app"
        let executable = "\(bundle)/Contents/MacOS/DockerHelper"
        let idle = StartupScanner.loginItemHelper(
            bundlePath: bundle, bundleID: "com.docker.helper", name: "DockerHelper", executableName: "DockerHelper",
            containingAppPath: "/Applications/Docker.app", environment: StartupFixtures.environment(existing: [executable])
        )
        #expect(idle.kind == .loginItem)
        #expect(idle.state == .unknown)
        #expect(idle.owner.name == "Docker")
        #expect(idle.isRunning == false)
        #expect(!idle.startsWithMac)
        #expect(idle.flags.isEmpty)

        let running = StartupScanner.loginItemHelper(
            bundlePath: bundle, bundleID: "com.docker.helper", name: "DockerHelper", executableName: "DockerHelper",
            containingAppPath: "/Applications/Docker.app",
            environment: StartupFixtures.environment(existing: [executable], running: [executable])
        )
        #expect(running.startsWithMac)
    }

    @Test("Disabled by Mactivity: never asks Login Items, can be enabled")
    func disabledByMactivity() throws {
        let env = StartupFixtures.environment(existing: ["/opt/homebrew/opt/postgresql@17/bin/postgres"], status: { _ in
            Issue.record("Login Items shouldn't be asked about a moved plist")
            return .enabled
        })
        let item = try StartupScanner.item(
            plistPath: "/Users/demo/Library/LaunchAgents (Disabled by Mactivity)/homebrew.mxcl.postgresql@17.plist",
            data: StartupFixtures.data("keepalive-true"), location: .disabledByMactivity, environment: env
        )
        #expect(item.state == .disabledByMactivity)
        #expect(item.loginItemsStatus == nil)
        #expect(item.canEnable)
        #expect(!item.canDisable)
        #expect(!item.startsWithMac)
    }
}

@Suite("Summary and grouping")
struct StartupSummaryTests {
    @Test("The simulated Mac's summary line")
    func simulated() async throws {
        let source = SimulatedStartupSource()
        let items = try await source.items()
        let summary = try await StartupSummary(items: items, macOSCount: source.macOSItemCount())
        #expect(summary.line == "13 things start with your Mac · 9 from apps you have · 1 broken · 3 unusual")
        #expect(summary.footnote == "Plus 911 from macOS, not listed. 3 more are off or start only when their app turns them on.")
    }

    @Test("Groups: apps alphabetically, Unknown last; items by kind")
    func grouping() async throws {
        let groups = try await StartupGroup.grouped(SimulatedStartupSource().items())
        let names = groups.map(\.owner.name)
        #expect(names.last == "Unknown")
        #expect(Array(names.dropLast()) == names.dropLast().sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        let docker = try #require(groups.first { $0.owner.name == "Docker" })
        #expect(docker.items.map(\.kind) == [.daemon, .appHelper])
    }

    @Test("Zero broken and unusual are left out of the line")
    func zeros() {
        let summary = StartupSummary(items: [], macOSCount: 0)
        #expect(summary.line == "0 things start with your Mac · 0 from apps you have")
    }
}
