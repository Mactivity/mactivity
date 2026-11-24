import Core
import Foundation
@testable import Storage

/// A home folder and app folders in a temporary place, with old files by default.
final class OldAppsFixture {
    let root: URL
    let home: URL
    let applications: URL
    let now = Date()
    var launchServices: [String: [URL]] = [:]
    var inUse: [String] = []
    var recorded: [RecordedApp] = []
    private let files = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("oldapps-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        applications = root.appendingPathComponent("Applications")
        for folder in [home.appendingPathComponent("Library"), applications] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var library: URL {
        home.appendingPathComponent("Library")
    }

    var old: Date {
        now.addingTimeInterval(-400 * 86400)
    }

    var env: OldAppsEnvironment {
        let services = launchServices
        let using = inUse
        return OldAppsEnvironment(
            home: home,
            installedFolders: [applications, home.appendingPathComponent("Applications")],
            copyFolders: [applications, home.appendingPathComponent("Applications")],
            looseCopyFolders: [home.appendingPathComponent("Downloads"), home.appendingPathComponent("Desktop")],
            backgroundFolders: [library.appendingPathComponent("LaunchAgents")],
            launchServicesCopies: { services[$0] ?? [] },
            inUsePaths: { using },
            recordedApps: recorded,
            now: now
        )
    }

    @discardableResult
    func app(
        _ name: String, id: String, version: String? = "1.0", bundleName: String? = nil, executable: String? = nil,
        in folder: URL? = nil
    ) throws -> URL {
        let url = (folder ?? applications).appendingPathComponent("\(name).app")
        let contents = url.appendingPathComponent("Contents")
        try files.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleName": bundleName ?? name, "CFBundleExecutable": executable ?? name,
        ]
        if let version {
            info["CFBundleShortVersionString"] = version
        }
        try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }

    /// A support folder with a file in it, everything last changed `date` (old by default).
    @discardableResult
    func folder(_ path: String, date: Date? = nil) throws -> URL {
        let url = library.appendingPathComponent(path)
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent("data.bin")
        try Data(repeating: 1, count: 9000).write(to: file)
        try age(file, date ?? old)
        try age(url, date ?? old)
        return url
    }

    @discardableResult
    func file(_ path: String, contents: [String: Any] = ["a": 1]) throws -> URL {
        let url = library.appendingPathComponent(path)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (contents as NSDictionary).write(to: url)
        try age(url, old)
        return url
    }

    func age(_ url: URL, _ date: Date) throws {
        try files.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
    }

    /// macOS kept this ID's window state: it was an app with windows.
    func hadWindows(_ id: String) throws {
        try folder("Saved Application State/\(id).savedState")
    }

    func leftoverNames() -> [String] {
        OldApps.leftovers(env).map { ($0.path as NSString).lastPathComponent }.sorted()
    }
}
