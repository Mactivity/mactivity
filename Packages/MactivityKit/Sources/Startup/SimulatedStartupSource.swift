import Foundation

/// A plausible Mac's startup items for previews, tests, and "Simulated data" mode. Built with
/// the real `StartupScanner` over a fake file system, so the rules are the same.
///
/// Disable and Enable work on its in-memory copy: `disable(_:)` / `enable(_:)` flip an item's
/// location the way `UserLaunchAgentToggle` would move its file.
public actor SimulatedStartupSource: StartupSource, StartupItemToggling {
    public static let home = "/Users/demo"

    private var disabled: Set<String> = []

    public init() {}

    public func items() async throws -> [StartupItem] {
        let env = Self.environment
        return Self.plists.map { entry in
            let isDisabled = disabled.contains(entry.name)
            let folder: String = switch entry.location {
            case .userLaunchAgents, .disabledByMactivity:
                isDisabled ? "\(Self.home)/Library/\(UserLaunchAgentToggle.disabledFolderName)" : "\(Self.home)/Library/LaunchAgents"
            case .launchAgents: "/Library/LaunchAgents"
            case .launchDaemons: "/Library/LaunchDaemons"
            case .appBundle, .serviceManagement: "\(entry.app ?? "")/Contents/Library/LaunchAgents"
            }
            let data = try? PropertyListSerialization.data(fromPropertyList: entry.keys, format: .xml, options: 0)
            return StartupScanner.item(
                plistPath: "\(folder)/\(entry.name).plist",
                data: data,
                location: isDisabled ? .disabledByMactivity : entry.location,
                containingAppPath: entry.location == .appBundle ? entry.app : nil,
                environment: env
            )
        } + [
            StartupScanner.loginItemHelper(
                bundlePath: "/Applications/Dropbox.app/Contents/Library/LoginItems/DropboxLoginHelper.app",
                bundleID: "com.getdropbox.dropbox.loginhelper", name: "DropboxLoginHelper", executableName: "DropboxLoginHelper",
                containingAppPath: "/Applications/Dropbox.app", environment: env
            ),
            StartupScanner.loginItemHelper(
                bundlePath: "/Applications/Rectangle.app/Contents/Library/LoginItems/RectangleLauncher.app",
                bundleID: "com.knollsoft.RectangleLauncher", name: "RectangleLauncher", executableName: "RectangleLauncher",
                containingAppPath: "/Applications/Rectangle.app", environment: env
            ),
            StartupScanner.mainAppLoginItem(
                app: InstalledApp(name: "Mactivity", bundleID: "app.mactivity.Mactivity", path: "/Applications/Mactivity.app"),
                executablePath: "/Applications/Mactivity.app/Contents/MacOS/Mactivity", status: .enabled, environment: env
            ),
        ]
    }

    public func macOSItemCount() async throws -> Int {
        911
    }

    /// Stands in for moving the plist to the disabled folder.
    public func disable(_ item: StartupItem) async throws {
        guard item.canDisable else {
            throw UserLaunchAgentToggle.ToggleError.notInFolder(item.name)
        }
        disabled.insert(Self.fileName(item))
    }

    public func enable(_ item: StartupItem) async throws {
        guard item.canEnable else {
            throw UserLaunchAgentToggle.ToggleError.notInFolder(item.name)
        }
        disabled.remove(Self.fileName(item))
    }

    private static func fileName(_ item: StartupItem) -> String {
        (((item.plistPath ?? item.id) as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: Fixture data

    private struct Entry {
        let name: String
        let location: StartupLocation
        var app: String?
        let keys: [String: Any]
    }

    static let apps: [InstalledApp] = [
        InstalledApp(name: "Google Chrome", bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app"),
        InstalledApp(name: "Dropbox", bundleID: "com.getdropbox.dropbox", path: "/Applications/Dropbox.app"),
        InstalledApp(name: "Docker", bundleID: "com.docker.docker", path: "/Applications/Docker.app"),
        InstalledApp(
            name: "Adobe Creative Cloud",
            bundleID: "com.adobe.acc.AdobeCreativeCloud",
            path: "/Applications/Adobe Creative Cloud.app"
        ),
        InstalledApp(name: "zoom.us", bundleID: "us.zoom.xos", path: "/Applications/zoom.us.app"),
        InstalledApp(name: "Ollama", bundleID: "com.electron.ollama", path: "/Applications/Ollama.app"),
        InstalledApp(name: "Rectangle", bundleID: "com.knollsoft.Rectangle", path: "/Applications/Rectangle.app"),
        InstalledApp(name: "Microsoft Word", bundleID: "com.microsoft.Word", path: "/Applications/Microsoft Word.app"),
        InstalledApp(name: "Mactivity", bundleID: "app.mactivity.Mactivity", path: "/Applications/Mactivity.app"),
    ]

    private static let googleUpdater = "\(home)/Library/Application Support/Google/GoogleUpdater/Current/"
        + "GoogleUpdater.app/Contents/MacOS/GoogleUpdater"
    private static let adobeService = "/Library/Application Support/Adobe/Adobe Desktop Common/ADS/"
        + "Adobe Desktop Service.app/Contents/MacOS/Adobe Desktop Service"

    private static let existing: Set<String> = [
        "/Applications/Google Chrome.app/Contents/Frameworks/GoogleUpdater",
        googleUpdater,
        "/Library/PrivilegedHelperTools/com.docker.vmnetd",
        "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
        adobeService,
        "/Library/PrivilegedHelperTools/us.zoom.ZoomDaemon",
        "/Applications/Ollama.app/Contents/Frameworks/Squirrel.framework/Versions/A/Squirrel",
        "/opt/homebrew/opt/postgresql@17/bin/postgres",
        "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/Microsoft Update Assistant",
        "/Applications/Dropbox.app/Contents/Library/LoginItems/DropboxLoginHelper.app/Contents/MacOS/DropboxLoginHelper",
        "/Applications/Rectangle.app/Contents/Library/LoginItems/RectangleLauncher.app/Contents/MacOS/RectangleLauncher",
        "\(home)/.local/share/sync-daemon/syncd",
        "/bin/sh",
        "/usr/bin/python3",
        "\(home)/Scripts/backup_notes.py",
        "/Library/Application Support/zoom.us/ZoomUpdater",
        "/Applications/Mactivity.app/Contents/MacOS/Mactivity",
    ]

    private static let running: Set<String> = [
        "/Library/PrivilegedHelperTools/com.docker.vmnetd",
        "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
        adobeService,
        "/opt/homebrew/opt/postgresql@17/bin/postgres",
        "/Applications/Ollama.app/Contents/Frameworks/Squirrel.framework/Versions/A/Squirrel",
        "/Applications/Dropbox.app/Contents/Library/LoginItems/DropboxLoginHelper.app/Contents/MacOS/DropboxLoginHelper",
        "\(home)/.local/share/sync-daemon/syncd",
        "/Applications/Mactivity.app/Contents/MacOS/Mactivity",
    ]

    static var environment: StartupEnvironment {
        StartupEnvironment(
            home: home,
            apps: apps,
            exists: { existing.contains($0) },
            appAt: { path in
                path.hasSuffix("GoogleUpdater.app")
                    ? InstalledApp(name: "GoogleUpdater", bundleID: "com.google.GoogleUpdater", path: path)
                    : path.hasSuffix("Microsoft AutoUpdate.app")
                    ? InstalledApp(name: "Microsoft AutoUpdate", bundleID: "com.microsoft.autoupdate2", path: path)
                    : nil
            },
            loginItemsStatus: { $0.hasSuffix("us.zoom.updater.plist") ? .requiresApproval : .enabled },
            runningExecutables: running
        )
    }

    private static var plists: [Entry] {
        [
            Entry(name: "com.google.GoogleUpdater.wake", location: .userLaunchAgents, keys: [
                "Label": "com.google.GoogleUpdater.wake",
                "AssociatedBundleIdentifiers": ["com.google.Chrome"],
                "ProgramArguments": [
                    googleUpdater,
                    "--wake-all",
                ],
                "StartInterval": 3600,
            ]),
            Entry(name: "com.google.keystone.agent", location: .userLaunchAgents, keys: [:]),
            Entry(name: "homebrew.mxcl.postgresql@17", location: .userLaunchAgents, keys: [
                "Label": "homebrew.mxcl.postgresql@17",
                "ProgramArguments": ["/opt/homebrew/opt/postgresql@17/bin/postgres", "-D", "/opt/homebrew/var/postgresql@17"],
                "RunAtLoad": true,
                "KeepAlive": true,
            ]),
            Entry(name: "local.sync-daemon", location: .userLaunchAgents, keys: [
                "Label": "local.sync-daemon",
                "Program": "\(home)/.local/share/sync-daemon/syncd",
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
            ]),
            Entry(name: "com.example.backup-notes", location: .userLaunchAgents, keys: [
                "Label": "com.example.backup-notes",
                "ProgramArguments": ["/usr/bin/python3", "\(home)/Scripts/backup_notes.py"],
                "StartCalendarInterval": ["Hour": 3, "Minute": 15],
            ]),
            Entry(name: "com.adobe.AdobeCreativeCloud", location: .launchAgents, keys: [
                "Label": "com.adobe.AdobeCreativeCloud",
                "AssociatedBundleIdentifiers": ["com.adobe.acc.AdobeCreativeCloud"],
                "ProgramArguments": [
                    adobeService,
                    "--onOSstartup=1",
                ],
                "RunAtLoad": true,
            ]),
            Entry(name: "com.microsoft.update.agent", location: .launchAgents, keys: [
                "Label": "com.microsoft.update.agent",
                "ProgramArguments": [
                    "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/Microsoft Update Assistant",
                    "--launchByAgent",
                ],
                "StartInterval": 7200,
            ]),
            Entry(name: "us.zoom.updater", location: .launchAgents, keys: [
                "Label": "us.zoom.updater",
                "ProgramArguments": ["/Library/Application Support/zoom.us/ZoomUpdater"],
                "StartCalendarInterval": ["Weekday": 1, "Hour": 9, "Minute": 0],
            ]),
            Entry(name: "com.docker.vmnetd", location: .launchDaemons, keys: [
                "Label": "com.docker.vmnetd",
                "Program": "/Library/PrivilegedHelperTools/com.docker.vmnetd",
                "ProgramArguments": ["/Library/PrivilegedHelperTools/com.docker.vmnetd"],
                "KeepAlive": true,
                "Sockets": ["Listener": ["SockPathName": "/var/run/com.docker.vmnetd.sock"]],
            ]),
            Entry(name: "us.zoom.ZoomDaemon", location: .launchDaemons, keys: [
                "Label": "us.zoom.ZoomDaemon",
                "Program": "/Library/PrivilegedHelperTools/us.zoom.ZoomDaemon",
                "MachServices": ["us.zoom.ZoomDaemon": true],
            ]),
            Entry(name: "com.oldvpn.helper", location: .launchDaemons, keys: [
                "Label": "com.oldvpn.helper",
                "Program": "/Library/PrivilegedHelperTools/com.oldvpn.helper",
                "RunAtLoad": true,
                "KeepAlive": true,
            ]),
            Entry(name: "com.ollama.ollama", location: .appBundle, app: "/Applications/Ollama.app", keys: [
                "Label": "com.ollama.ollama",
                "BundleProgram": "Contents/Frameworks/Squirrel.framework/Versions/A/Squirrel",
                "ProgramArguments": ["Contents/Frameworks/Squirrel.framework/Versions/A/Squirrel", "background"],
                "RunAtLoad": true,
            ]),
            Entry(name: "com.docker.backend", location: .appBundle, app: "/Applications/Docker.app", keys: [
                "Label": "com.docker.backend",
                "BundleProgram": "Contents/MacOS/com.docker.backend",
                "KeepAlive": ["SuccessfulExit": false],
                "RunAtLoad": true,
            ]),
        ]
    }
}
