import Foundation
@testable import Storage
import Testing

/// Big files you forgot (1.6): which files may be listed, and when one counts as forgotten.
struct ForgottenFilesTests {
    let home = "/Users/robin"
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Only the person's own files: not Library, not hidden folders, not outside home")
    func listable() {
        #expect(ForgottenFiles.isListable("/Users/robin/Movies/Export.mov", home: home))
        #expect(ForgottenFiles.isListable("/Users/robin/Documents/Old/backup.zip", home: home))
        #expect(!ForgottenFiles.isListable("/Users/robin/Library/Application Support/App/data.db", home: home))
        // iCloud Drive lives under Library; it's for Cloud folders, where a file can stay in iCloud.
        #expect(!ForgottenFiles.isListable("/Users/robin/Library/Mobile Documents/com~apple~CloudDocs/a.mov", home: home))
        #expect(!ForgottenFiles.isListable("/Users/robin/.docker/disk.raw", home: home))
        #expect(!ForgottenFiles.isListable("/Users/robin/Projects/.git/objects/pack.pack", home: home))
        #expect(!ForgottenFiles.isListable("/Applications/Big.app/Contents/Resources/x", home: home))
        #expect(!ForgottenFiles.isListable("/Users/robin/../other/file", home: home))
        #expect(!ForgottenFiles.isListable("/Users/robinother/file", home: home))
    }

    @Test("Forgotten means nothing touched it for a year: opened, changed, or added")
    func forgotten() throws {
        let old = now.addingTimeInterval(-400 * 86400)
        let recent = now.addingTimeInterval(-30 * 86400)
        let allOld = try #require(ForgottenFiles.lastTouched(opened: old, modified: old, added: old))
        #expect(ForgottenFiles.isForgotten(lastTouched: allOld, now: now))
        // Downloaded last month, though made years ago: not forgotten.
        let added = try #require(ForgottenFiles.lastTouched(opened: nil, modified: old, added: recent))
        #expect(!ForgottenFiles.isForgotten(lastTouched: added, now: now))
        // Opened last month.
        let opened = try #require(ForgottenFiles.lastTouched(opened: recent, modified: old, added: nil))
        #expect(!ForgottenFiles.isForgotten(lastTouched: opened, now: now))
        #expect(ForgottenFiles.lastTouched(opened: nil, modified: nil, added: nil) == nil)
    }

    @Test("A file inside a package isn't listed, one beside it is")
    func packages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forgotten-\(UUID().uuidString)")
        let library = root.appendingPathComponent("Photos Library.photoslibrary/originals", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = library.appendingPathComponent("IMG.mov").path
        let beside = root.appendingPathComponent("Clip.mov").path
        #expect(ForgottenFiles.insidePackage(inside, home: root.path))
        #expect(!ForgottenFiles.insidePackage(beside, home: root.path))
    }

    @Test("Files in a code project or a build folder are the project's, not the person's to clean")
    func projects() throws {
        #expect(ForgottenFiles.inBuildFolder("/Users/robin/Code/app/node_modules/lib/x.dylib", home: home))
        #expect(ForgottenFiles.inBuildFolder("/Users/robin/Code/app/build/site/a.dmg", home: home))
        #expect(!ForgottenFiles.inBuildFolder("/Users/robin/Movies/build.mov", home: home))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Repo/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Repo/assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Movies"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ForgottenFiles.insideProject(root.appendingPathComponent("Repo/assets/big.psd").path, home: root.path))
        #expect(!ForgottenFiles.insideProject(root.appendingPathComponent("Movies/clip.mov").path, home: root.path))
    }
}
