import Core
import Darwin
import Foundation
import os
import ServiceManagement

/// The real startup audit, read from the folders launchd loads and from installed apps.
///
/// **What it sees:** plists in `~/Library/LaunchAgents`, `/Library/LaunchAgents`, and
/// `/Library/LaunchDaemons`; agent and daemon plists and `LoginItems` helper apps inside apps in
/// `/Applications` and `~/Applications`; this app's own `SMAppService.mainApp` registration; and,
/// per plist, what `SMAppService.statusForLegacyPlist(at:)` says about it in Login Items.
///
/// **What it doesn't:** the complete Background Task Management list (`sfltool dumpbtm`, root,
/// or the private BTM framework), which is the only place that knows which "Open at Login"
/// apps the user added in System Settings and whether an app's `LoginItems` helper is
/// registered. Those show as "Only System Settings knows", with a button that opens it.
/// It never runs `launchctl` and never writes anything.
public struct LaunchdStartupSource: StartupSource {
    private static let log = Logger(subsystem: "app.mactivity.startup", category: "source")

    /// The folders to read. Tests point these at temporary directories.
    public struct Folders: Sendable {
        public var home: URL
        public var userLaunchAgents: URL
        public var launchAgents: URL
        public var launchDaemons: URL
        public var systemLaunchAgents: URL
        public var systemLaunchDaemons: URL
        public var applicationFolders: [URL]

        public init(
            home: URL,
            userLaunchAgents: URL,
            launchAgents: URL,
            launchDaemons: URL,
            systemLaunchAgents: URL,
            systemLaunchDaemons: URL,
            applicationFolders: [URL]
        ) {
            self.home = home
            self.userLaunchAgents = userLaunchAgents
            self.launchAgents = launchAgents
            self.launchDaemons = launchDaemons
            self.systemLaunchAgents = systemLaunchAgents
            self.systemLaunchDaemons = systemLaunchDaemons
            self.applicationFolders = applicationFolders
        }

        public static var standard: Folders {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Folders(
                home: home,
                userLaunchAgents: home.appendingPathComponent("Library/LaunchAgents"),
                launchAgents: URL(fileURLWithPath: "/Library/LaunchAgents"),
                launchDaemons: URL(fileURLWithPath: "/Library/LaunchDaemons"),
                systemLaunchAgents: URL(fileURLWithPath: "/System/Library/LaunchAgents"),
                systemLaunchDaemons: URL(fileURLWithPath: "/System/Library/LaunchDaemons"),
                applicationFolders: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
            )
        }
    }

    private let folders: Folders
    private let runningExecutables: @Sendable () async -> Set<String>
    private let includesMainApp: Bool

    /// - Parameters:
    ///   - runningExecutables: the running processes' executable paths. Defaults to
    ///     `proc_listallpids` + `proc_pidpath`; pass `RunningExecutables.paths(from:)` over a
    ///   snapshot's readings to reuse them.
    ///   - includesMainApp: list this app when it's registered to open at login.
    public init(
        folders: Folders = .standard,
        runningExecutables: @escaping @Sendable () async -> Set<String> = { RunningExecutables.current() },
        includesMainApp: Bool = true
    ) {
        self.folders = folders
        self.runningExecutables = runningExecutables
        self.includesMainApp = includesMainApp
    }

    public func items() async throws -> [StartupItem] {
        let apps = InstalledApps.scan(folders.applicationFolders)
        let env = await StartupEnvironment(
            home: folders.home.path,
            apps: apps,
            exists: { FileManager.default.fileExists(atPath: $0) },
            appAt: { InstalledApps.read(URL(fileURLWithPath: $0)) },
            loginItemsStatus: { Self.loginItemsStatus(plistPath: $0) },
            runningExecutables: runningExecutables(),
            resolveSymlinks: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        )
        var items: [StartupItem] = []
        let scans: [(URL, StartupLocation)] = [
            (folders.userLaunchAgents, .userLaunchAgents),
            (UserLaunchAgentToggle(agentsDirectory: folders.userLaunchAgents).disabledDirectory, .disabledByMactivity),
            (folders.launchAgents, .launchAgents),
            (folders.launchDaemons, .launchDaemons),
        ]
        for (folder, location) in scans {
            for plist in Self.plists(in: folder) {
                items.append(StartupScanner.item(
                    plistPath: plist.path, data: try? Data(contentsOf: plist), location: location, environment: env
                ))
            }
        }
        for app in apps {
            items += Self.helpers(inside: app, environment: env)
        }
        if includesMainApp, let main = mainAppItem(environment: env) {
            items.append(main)
        }
        return items
    }

    public func macOSItemCount() async throws -> Int {
        Self.plists(in: folders.systemLaunchAgents).count + Self.plists(in: folders.systemLaunchDaemons).count
    }

    /// Plist files directly inside a folder, sorted. A missing or unreadable folder is empty.
    static func plists(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".plist") }.sorted().map { folder.appendingPathComponent($0) }
    }

    /// `Contents/Library/LoginItems/*.app` and `Contents/Library/LaunchAgents|LaunchDaemons/*.plist`.
    static func helpers(inside app: InstalledApp, environment env: StartupEnvironment) -> [StartupItem] {
        let library = URL(fileURLWithPath: app.path).appendingPathComponent("Contents/Library")
        var items: [StartupItem] = []
        let loginItems = library.appendingPathComponent("LoginItems")
        let bundles = ((try? FileManager.default.contentsOfDirectory(atPath: loginItems.path)) ?? [])
            .filter { $0.hasSuffix(".app") }
            .sorted()
        for name in bundles {
            let url = loginItems.appendingPathComponent(name)
            let info = InstalledApps.infoDictionary(url)
            items.append(StartupScanner.loginItemHelper(
                bundlePath: url.path,
                bundleID: info?["CFBundleIdentifier"] as? String,
                name: (name as NSString).deletingPathExtension,
                executableName: info?["CFBundleExecutable"] as? String,
                containingAppPath: app.path,
                environment: env
            ))
        }
        for folder in ["LaunchAgents", "LaunchDaemons"] {
            for plist in plists(in: library.appendingPathComponent(folder)) {
                items.append(StartupScanner.item(
                    plistPath: plist.path, data: try? Data(contentsOf: plist), location: .appBundle,
                    containingAppPath: app.path, environment: env
                ))
            }
        }
        return items
    }

    private func mainAppItem(environment env: StartupEnvironment) -> StartupItem? {
        let bundle = Bundle.main
        guard bundle.bundlePath.hasSuffix(".app"), let app = InstalledApps.read(bundle.bundleURL) else {
            return nil
        }
        let status: LoginItemsStatus
        switch SMAppService.mainApp.status {
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notRegistered, .notFound: return nil
        @unknown default: return nil
        }
        return StartupScanner.mainAppLoginItem(
            app: app, executablePath: bundle.executableURL?.path, status: status, environment: env
        )
    }

    /// Public, read-only, and fast (under 2 ms per plist on an M-series Mac).
    static func loginItemsStatus(plistPath: String) -> LoginItemsStatus? {
        switch SMAppService.statusForLegacyPlist(at: URL(fileURLWithPath: plistPath)) {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: nil
        }
    }
}

/// Installed apps in the Applications folders, one level of subfolders deep (`Utilities`, vendor folders).
public enum InstalledApps {
    public static func scan(_ folders: [URL]) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for folder in folders {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() {
                let url = folder.appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    if let app = read(url) {
                        apps.append(app)
                    }
                } else if !name.hasPrefix("."), isDirectory(url) {
                    let inner = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
                    apps += inner.filter { $0.hasSuffix(".app") }.compactMap { read(url.appendingPathComponent($0)) }
                }
            }
        }
        return apps
    }

    /// The app at a bundle path, named as Finder shows it.
    public static func read(_ url: URL) -> InstalledApp? {
        guard let id = infoDictionary(url)?["CFBundleIdentifier"] as? String else {
            return nil
        }
        return InstalledApp(name: url.deletingPathExtension().lastPathComponent, bundleID: id, path: url.standardizedFileURL.path)
    }

    static func infoDictionary(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}

/// Which executables are running now, for the "Running" column.
public enum RunningExecutables {
    /// From a sampler's readings, when the caller already has them.
    public static func paths(from readings: [ProcessReading]) -> Set<String> {
        Set(readings.compactMap(\.executablePath))
    }

    /// `proc_listallpids` + `proc_pidpath` (public libproc).
    public static func current() -> Set<String> {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else {
            return []
        }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else {
            return []
        }
        var paths = Set<String>()
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            if length > 0, let path = String(bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8) {
                paths.insert(path)
            }
        }
        return paths
    }
}
