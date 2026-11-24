import Foundation
@testable import Startup

/// Loads plist fixtures from `Tests/Fixtures/startup/`.
enum StartupFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/startup")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("\(name).plist"))
    }

    static func plist(_ name: String) throws -> LaunchdPlist {
        try LaunchdPlist.parse(data(name))
    }

    static let home = "/Users/demo"

    /// An updater that lives in Application Support, the typical unusual location.
    static let googleUpdater = "\(home)/Library/Application Support/Google/GoogleUpdater/Current/"
        + "GoogleUpdater.app/Contents/MacOS/GoogleUpdater"

    static let apps: [InstalledApp] = [
        InstalledApp(name: "Google Chrome", bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app"),
        InstalledApp(name: "Docker", bundleID: "com.docker.docker", path: "/Applications/Docker.app"),
        InstalledApp(name: "Ollama", bundleID: "com.electron.ollama", path: "/Applications/Ollama.app"),
        InstalledApp(name: "zoom.us", bundleID: "us.zoom.xos", path: "/Applications/zoom.us.app"),
        InstalledApp(name: "GitHub Desktop", bundleID: "com.github.GitHubClient", path: "/Applications/GitHub Desktop.app"),
        InstalledApp(name: "Microsoft Word", bundleID: "com.microsoft.Word", path: "/Applications/Microsoft Word.app"),
        InstalledApp(name: "Microsoft Excel", bundleID: "com.microsoft.Excel", path: "/Applications/Microsoft Excel.app"),
    ]

    /// A fake file system and process list.
    static func environment(
        existing: Set<String>,
        running: Set<String> = [],
        status: @escaping @Sendable (String) -> LoginItemsStatus? = { _ in nil }
    ) -> StartupEnvironment {
        StartupEnvironment(
            home: home,
            apps: apps,
            exists: { existing.contains($0) },
            appAt: { path in
                path.hasSuffix("/GoogleUpdater.app")
                    ? InstalledApp(name: "GoogleUpdater", bundleID: "com.google.GoogleUpdater", path: path)
                    : nil
            },
            loginItemsStatus: status,
            runningExecutables: running
        )
    }
}
