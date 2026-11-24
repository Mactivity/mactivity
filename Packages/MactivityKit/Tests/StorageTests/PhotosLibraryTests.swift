import Core
import Foundation
@testable import Storage
import Testing

/// Sizes by folder (D-283). The layout is the one seen in a real library's package on this Mac's
/// simulators (originals, resources/derivatives, scopes/cloudsharing, database, …); this Mac's own
/// library is closed to anything without Full Disk Access.
@Suite("Photos library, sized (D-283)")
struct PhotosLibraryTests {
    private func makeLibrary(_ files: [String: Int]) throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-\(UUID().uuidString)/Photos Library.photoslibrary")
        for (path, size) in files {
            let url = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: size).write(to: url)
        }
        return package
    }

    @Test("Each folder counts as its part")
    func parts() {
        #expect(PhotosLibraryParts.part(of: "originals/A/photo.heic") == .originals)
        #expect(PhotosLibraryParts.part(of: "/Masters/2019/photo.jpg") == .originals)
        #expect(PhotosLibraryParts.part(of: "resources/renders/A/edit.jpg") == .edits)
        #expect(PhotosLibraryParts.part(of: "resources/derivatives/thumbs/1.jpg") == .thumbnails)
        #expect(PhotosLibraryParts.part(of: "resources/derivatives/masters/1.jpg") == .thumbnails)
        #expect(PhotosLibraryParts.part(of: "scopes/cloudsharing/data/1.jpg") == .sharedAlbums)
        #expect(PhotosLibraryParts.part(of: "database/Photos.sqlite") == .database)
        #expect(PhotosLibraryParts.part(of: "resources/cpl/cloudsync.noindex/x") == .other)
        #expect(PhotosLibraryParts.part(of: "scopes/momentshared/x") == .other)
        #expect(PhotosLibraryParts.part(of: "originalsOld/x") == .other)
    }

    @Test("Sizes add up, by folder, for a library fixture")
    func measure() throws {
        let package = try makeLibrary([
            "originals/A/a.heic": 400_000, "originals/B/b.mov": 800_000, "resources/renders/A/a.jpg": 100_000,
            "resources/derivatives/thumbs/1.jpg": 50000, "database/Photos.sqlite": 200_000, "scopes/cloudsharing/data/s.jpg": 30000,
            "private/com.apple.assetsd/x": 20000,
        ])
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        let parts = try #require(LivePhotosLibrary.measure(package: package))
        #expect(parts.originals >= 1_200_000 && parts.originals < 1_300_000)
        #expect(parts.edits >= 100_000 && parts.edits < 120_000)
        #expect(parts.thumbnails >= 50000 && parts.thumbnails < 60000)
        #expect(parts.database >= 200_000 && parts.database < 220_000)
        #expect(parts.sharedAlbums >= 30000 && parts.sharedAlbums < 40000)
        #expect(parts.other >= 20000 && parts.other < 30000)
        #expect(parts.total == parts.originals + parts.edits + parts.thumbnails + parts.database + parts.sharedAlbums + parts.other)
    }

    @Test("A library macOS keeps closed says so, rather than reading as empty")
    func noAccess() throws {
        let package = try makeLibrary(["originals/a.heic": 1000])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path)
            try? FileManager.default.removeItem(at: package.deletingLastPathComponent())
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: package.path)
        #expect(LivePhotosLibrary.measure(package: package) == nil)
        #expect(LivePhotosLibrary.measured(package.path).state == .noAccess)
    }

    @Test("A library in ~/Pictures or wherever Spotlight found it; never simulators', the Trash's or a backup's")
    func locations() {
        let home = "/Users/me"
        let found = LivePhotosLibrary.locations(
            home: home,
            spotlight: [
                "/Users/me/Pictures/Photos Library.photoslibrary",
                "/Users/me/Archive/Old Family.photoslibrary",
                "/Volumes/Photos/Photos Library.photoslibrary",
                "/Users/me/Library/Photos/Libraries/Syndication.photoslibrary",
                "/Users/me/Library/Developer/CoreSimulator/Devices/A/data/Library/Photos/Libraries/Syndication.photoslibrary",
                "/Users/me/.Trash/Gone.photoslibrary",
                "/Volumes/TM/Backups.backupdb/Mac/Latest/Photos Library.photoslibrary",
                "/Users/me/Pictures/Photo Booth Library",
            ],
            pictures: ["Photos Library.photoslibrary", "Photo Booth Library", ".DS_Store"]
        )
        #expect(found == [
            "/Users/me/Archive/Old Family.photoslibrary", "/Users/me/Pictures/Photos Library.photoslibrary",
            "/Volumes/Photos/Photos Library.photoslibrary",
        ])
        #expect(LivePhotosLibrary.isOnStartupDrive("/Users/me/Archive/Old Family.photoslibrary", home: home))
        #expect(!LivePhotosLibrary.isOnStartupDrive("/Volumes/Photos/Photos Library.photoslibrary", home: home))
    }

    @Test("A library on another drive isn't walked until asked")
    func anotherDrive() async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("photos-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let source = LivePhotosLibrary(home: home.path, spotlight: { ["/Volumes/Missing/Photos Library.photoslibrary"] })
        let reports = await source.libraries()
        #expect(reports.map(\.state) == [.notMeasured])
        #expect(reports.first?.name == "Photos Library")
        #expect(await source.measure(path: "/Volumes/Missing/Photos Library.photoslibrary").state == .notMeasured)
    }
}
