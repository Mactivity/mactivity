import Core
import Darwin
import Foundation

/// Finds Photos libraries and sizes their folders (D-283). Read-only: file names and allocated
/// sizes, never a file's contents, and never `database/Photos.sqlite` itself beyond its size.
public struct LivePhotosLibrary: PhotosLibrarySource {
    private let home: String
    private let spotlight: @Sendable () -> [String]

    public init(home: String = NSHomeDirectory(), spotlight: (@Sendable () -> [String])? = nil) {
        self.home = home
        self.spotlight = spotlight ?? { Self.spotlightLibraries() }
    }

    public func libraries() async -> [PhotosLibraryReport] {
        let home = home
        let spotlight = spotlight
        return await Task.detached(priority: .utility) {
            Self.locations(home: home, spotlight: spotlight()).map { path in
                Self.isOnStartupDrive(path, home: home) ? Self.measured(path) : PhotosLibraryReport(path: path, state: .notMeasured)
            }
        }.value
    }

    public func measure(path: String) async -> PhotosLibraryReport {
        await Task.detached(priority: .utility) { Self.measured(path) }.value
    }

    // MARK: Finding

    /// Pure: libraries among what Spotlight knows and the top of ~/Pictures. Never one in a
    /// Library folder (`Syndication.photoslibrary` is Shared with You's, and each simulator has
    /// its own), the Trash, or a Time Machine backup.
    static func locations(home: String, spotlight: [String], pictures: [String]? = nil) -> [String] {
        let folder = (home as NSString).appendingPathComponent("Pictures")
        let names = pictures ?? (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let inPictures = names.filter { $0.hasSuffix(".photoslibrary") }.map { (folder as NSString).appendingPathComponent($0) }
        let found = (inPictures + spotlight).filter { path in
            path.hasSuffix(".photoslibrary") && !path.contains("/Library/") && !path.contains("/.Trash/")
                && !path.contains("/.Trashes/") && !path.contains("Backups.backupdb") && !path.contains("/.timemachine/")
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }.sorted()
    }

    /// Under the home folder: reading it asks nothing of another drive.
    static func isOnStartupDrive(_ path: String, home: String) -> Bool {
        path.hasPrefix(home + "/")
    }

    /// Libraries Spotlight has indexed, which is where a moved one shows up.
    static func spotlightLibraries() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemContentType == 'com.apple.photos.library'"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else {
            return []
        }
        let killer = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return (String(bytes: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: Sizing

    static func measured(_ path: String) -> PhotosLibraryReport {
        // A drive unplugged since the library was found.
        guard FileManager.default.fileExists(atPath: path) else {
            return PhotosLibraryReport(path: path, state: .notMeasured)
        }
        return PhotosLibraryReport(path: path, state: measure(package: URL(fileURLWithPath: path)).map { .measured($0) } ?? .noAccess)
    }

    /// Nil when macOS won't let Mactivity look inside. A subfolder it can't read counts as empty,
    /// the way Finder's sizes do.
    static func measure(package: URL) -> PhotosLibraryParts? {
        guard (try? FileManager.default.contentsOfDirectory(atPath: package.path)) != nil else {
            return nil
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        let keySet = Set(keys)
        var parts = PhotosLibraryParts()
        let root = package.resolvingSymlinksInPath().path
        let walk = FileManager.default.enumerator(at: package, includingPropertiesForKeys: keys, options: []) { _, _ in true }
        while let file = walk?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: keySet), values.isRegularFile == true else {
                continue
            }
            let full = file.resolvingSymlinksInPath().path
            let relative = full.hasPrefix(root) ? String(full.dropFirst(root.count)) : file.lastPathComponent
            parts.add(UInt64(values.totalFileAllocatedSize ?? 0), to: PhotosLibraryParts.part(of: relative))
        }
        return parts
    }
}
