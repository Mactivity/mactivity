import Foundation

/// Everything `StartupScanner` needs from the machine, as values and closures, so tests can
/// replace the file system, Login Items, and the process list with fixtures.
public struct StartupEnvironment: Sendable {
    public var home: String
    public var apps: [InstalledApp]
    public var exists: @Sendable (String) -> Bool
    /// Reads an app that isn't in `apps`.
    public var appAt: @Sendable (String) -> InstalledApp?
    /// `SMAppService.statusForLegacyPlist(at:)`, or nil where it doesn't apply.
    public var loginItemsStatus: @Sendable (String) -> LoginItemsStatus?
    /// Executable paths of the processes running now, symlinks resolved.
    public var runningExecutables: Set<String>
    public var resolveSymlinks: @Sendable (String) -> String

    public init(
        home: String,
        apps: [InstalledApp],
        exists: @escaping @Sendable (String) -> Bool,
        appAt: @escaping @Sendable (String) -> InstalledApp? = { _ in nil },
        loginItemsStatus: @escaping @Sendable (String) -> LoginItemsStatus? = { _ in nil },
        runningExecutables: Set<String> = [],
        resolveSymlinks: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.home = home
        self.apps = apps
        self.exists = exists
        self.appAt = appAt
        self.loginItemsStatus = loginItemsStatus
        self.runningExecutables = runningExecutables
        self.resolveSymlinks = resolveSymlinks
    }
}

/// Builds `StartupItem`s from plists and helper apps. Pure given its environment.
public enum StartupScanner {
    /// One launchd plist.
    ///
    /// - Parameters:
    ///   - data: the file's contents; nil or unparsable makes a broken item.
    ///   - containingAppPath: the app whose `Contents/Library` holds the plist, for app helpers.
    public static func item(
        plistPath: String,
        data: Data?,
        location: StartupLocation,
        containingAppPath: String? = nil,
        environment env: StartupEnvironment
    ) -> StartupItem {
        let fileLabel = ((plistPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let kind = kind(for: location, plistPath: plistPath)
        guard let data, let plist = try? LaunchdPlist.parse(data) else {
            return StartupItem(
                id: plistPath, label: fileLabel, name: fileLabel, kind: kind, location: location, plistPath: plistPath,
                executablePath: nil, arguments: [], schedule: .onDemand, plist: nil,
                owner: StartupResolution.owner(
                    plist: nil, label: fileLabel, executablePath: nil, containingAppPath: containingAppPath,
                    apps: env.apps, appAt: env.appAt
                ),
                state: StartupResolution.state(plist: nil, location: location, loginItemsStatus: nil),
                loginItemsStatus: nil, isRunning: nil,
                flags: [StartupFlag(
                    .broken,
                    String(localized: "Its plist can't be read, so launchd can't load it.", bundle: .strings, comment: "Startup flag")
                )]
            )
        }
        let label = plist.label ?? fileLabel
        let associatedApp = plist.associatedBundleIdentifiers.lazy.compactMap { id in
            env.apps.first { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }
        }.first
        let (declared, executable) = StartupResolution.executable(
            for: plist,
            bundlePath: containingAppPath ?? associatedApp?.path,
            exists: env.exists
        )
        let script = StartupResolution.scriptPath(executable: executable, arguments: plist.extraArguments)
        let status = location == .disabledByMactivity ? nil : env.loginItemsStatus(plistPath)
        let owner = StartupResolution.owner(
            plist: plist, label: label, executablePath: executable, containingAppPath: containingAppPath,
            apps: env.apps, appAt: env.appAt
        )
        let isEmpty = plist == LaunchdPlist()
        let flags = isEmpty ? [emptyFlag()] : StartupResolution.flags(
            declared: declared, executablePath: executable, scriptPath: script, home: env.home, exists: env.exists
        )
        return StartupItem(
            id: plistPath,
            label: label,
            name: label,
            kind: kind,
            location: location,
            plistPath: plistPath,
            executablePath: executable,
            arguments: plist.extraArguments,
            schedule: plist.schedule,
            plist: plist,
            owner: owner,
            // An empty plist switches the item off as surely as `Disabled` does (D-132).
            state: isEmpty && location != .disabledByMactivity
                ? .disabledInPlist : StartupResolution.state(plist: plist, location: location, loginItemsStatus: status),
            loginItemsStatus: status,
            isRunning: running(executable, script: script, env: env),
            flags: flags
        )
    }

    /// An empty plist: launchd ignores it, and some updaters empty theirs to switch off (D-132).
    private static func emptyFlag() -> StartupFlag {
        StartupFlag(.empty, String(
            localized: "Its plist is empty, so launchd ignores it. Some updaters empty theirs to switch off.",
            bundle: .strings,
            comment: "Startup flag reason"
        ))
    }

    /// A helper app in some app's `Contents/Library/LoginItems`. Whether it's registered is only
    /// in the Background Task Management database, so its state is unknown; running is known.
    public static func loginItemHelper(
        bundlePath: String,
        bundleID: String?,
        name: String,
        executableName: String?,
        containingAppPath: String,
        environment env: StartupEnvironment
    ) -> StartupItem {
        let executable = executableName.map { "\(bundlePath)/Contents/MacOS/\($0)" }
        let owner = StartupResolution.owner(
            plist: nil, label: bundleID ?? name, executablePath: nil, containingAppPath: containingAppPath,
            apps: env.apps, appAt: env.appAt
        )
        let flags = StartupResolution.flags(
            declared: executableName, executablePath: executable, scriptPath: nil, home: env.home, exists: env.exists
        )
        return StartupItem(
            id: bundlePath, label: bundleID ?? name, name: name, kind: .loginItem, location: .appBundle, plistPath: nil,
            executablePath: executable, arguments: [], schedule: .atLoad, plist: nil, owner: owner,
            state: .unknown, loginItemsStatus: nil, isRunning: running(executable, script: nil, env: env), flags: flags
        )
    }

    /// An app registered with `SMAppService.mainApp` (this app, when "Open at Login" is on).
    public static func mainAppLoginItem(
        app: InstalledApp,
        executablePath: String?,
        status: LoginItemsStatus,
        environment env: StartupEnvironment
    )
        -> StartupItem {
        StartupItem(
            id: app.path, label: app.bundleID, name: app.name, kind: .loginItem, location: .serviceManagement, plistPath: nil,
            executablePath: executablePath, arguments: [], schedule: .atLoad, plist: nil,
            owner: StartupOwner(name: app.name, bundleID: app.bundleID, bundlePath: app.path, evidence: .containingApp),
            state: status == .requiresApproval ? .turnedOffInSettings : .on, loginItemsStatus: status,
            isRunning: running(executablePath, script: nil, env: env), flags: []
        )
    }

    static func kind(for location: StartupLocation, plistPath: String) -> StartupKind {
        switch location {
        case .userLaunchAgents, .disabledByMactivity, .launchAgents: .agent
        case .launchDaemons: .daemon
        case .appBundle: plistPath.contains("/LoginItems/") ? .loginItem : .appHelper
        case .serviceManagement: .loginItem
        }
    }

    private static func running(_ executable: String?, script: String?, env: StartupEnvironment) -> Bool? {
        guard let executable, !StartupResolution.isShared(executable, scriptPath: script) else {
            return nil
        }
        return env.runningExecutables.contains(env.resolveSymlinks(executable))
            || env.runningExecutables.contains(executable)
    }
}
