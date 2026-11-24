import Core
import Foundation
@testable import Storage
import Testing

@Suite("Old app versions and leftovers: second copies, and the check before the Trash (D-282)")
struct OldAppsCopiesTests {

    // MARK: Second copies

    @Test("An older copy is listed with the newer one kept, whatever order they're found in")
    func olderCopy() throws {
        let fixture = try OldAppsFixture()
        try fixture.app("Writer", id: "com.acme.Writer", version: "2.10")
        try fixture.app("Writer Old", id: "com.acme.Writer", version: "2.9", bundleName: "Writer", executable: "Writer")
        let copy = try #require(OldApps.copies(fixture.env).first)
        #expect((copy.path as NSString).lastPathComponent == "Writer Old.app")
        #expect((copy.keptPath as NSString).lastPathComponent == "Writer.app")
        #expect(copy.keptVersion == "2.10")
        #expect(!copy.isSameVersion)
    }

    @Test("Of equals, the plainer one in the first app folder stays")
    func sameVersion() throws {
        let fixture = try OldAppsFixture()
        try fixture.app("Writer", id: "com.acme.Writer")
        let homeApps = fixture.home.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: homeApps, withIntermediateDirectories: true)
        try fixture.app("Writer", id: "com.acme.Writer", in: homeApps)
        let copies = OldApps.copies(fixture.env)
        #expect(copies.count == 1)
        #expect(copies.first?.path.hasPrefix(homeApps.path) == true)
        #expect(copies.first?.isSameVersion == true)
    }

    @Test("A running copy stays and is never listed, even when it's the older one")
    func runningCopy() throws {
        let fixture = try OldAppsFixture()
        let older = try fixture.app("Writer Old", id: "com.acme.Writer", version: "1.0", bundleName: "Writer", executable: "Writer")
        try fixture.app("Writer", id: "com.acme.Writer", version: "2.0")
        fixture.inUse = [older.appendingPathComponent("Contents/MacOS/Writer").path]
        // The other copy is newer than the one in use: it may be what's next, so it stays as well.
        #expect(OldApps.copies(fixture.env).isEmpty)
    }

    @Test("Same ID, different apps: templates and wrappers aren't copies")
    func sameIDDifferentApps() throws {
        let fixture = try OldAppsFixture()
        try fixture.app("Wrapper One", id: "com.wrapper.Shell", bundleName: "One", executable: "one")
        try fixture.app("Wrapper Two", id: "com.wrapper.Shell", bundleName: "Two", executable: "two")
        try fixture.app("Notes App", id: "com.github.Electron", bundleName: "Electron", executable: "Electron")
        try fixture.app("Chat App", id: "com.github.Electron", bundleName: "Electron", executable: "Electron")
        try fixture.app("A", id: "com.example.app", bundleName: "App", executable: "App")
        try fixture.app("B", id: "com.example.app", bundleName: "App", executable: "App")
        #expect(OldApps.copies(fixture.env).isEmpty)
    }

    @Test("Apple's apps are never copies: Xcode and Xcode-beta are both wanted")
    func appleCopies() throws {
        let fixture = try OldAppsFixture()
        try fixture.app("Xcode", id: "com.apple.dt.Xcode", version: "26.0", bundleName: "Xcode", executable: "Xcode")
        try fixture.app("Xcode-beta", id: "com.apple.dt.Xcode", version: "27.0", bundleName: "Xcode", executable: "Xcode")
        #expect(OldApps.copies(fixture.env).isEmpty)
    }

    @Test("A link to an app isn't a copy of it")
    func linkedApp() throws {
        let fixture = try OldAppsFixture()
        let app = try fixture.app("Writer", id: "com.acme.Writer")
        let homeApps = fixture.home.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: homeApps, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: homeApps.appendingPathComponent("Writer.app"), withDestinationURL: app)
        #expect(OldApps.copies(fixture.env).isEmpty)
    }

    @Test("An app inside an app isn't looked at")
    func nestedApp() throws {
        let fixture = try OldAppsFixture()
        let app = try fixture.app("Writer", id: "com.acme.Writer")
        try fixture.app("Writer", id: "com.acme.Writer", in: app.appendingPathComponent("Contents/Helpers"))
        #expect(OldApps.copies(fixture.env).isEmpty)
    }

    @Test("Build folders, drives and the Trash stay out; Downloads and the Desktop count")
    func whereCopiesCount() throws {
        let fixture = try OldAppsFixture()
        try fixture.app("Writer", id: "com.acme.Writer", version: "2.0")
        var known: [URL] = []
        for place in ["Developer/Writer/build/Debug", "Library/Developer/Xcode/DerivedData/x/Build", ".Trash", "Documents"] {
            let folder = fixture.home.appendingPathComponent(place)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try known.append(fixture.app("Writer", id: "com.acme.Writer", version: "1.0", in: folder))
        }
        let drive = fixture.root.appendingPathComponent("Volumes/Backup")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try known.append(fixture.app("Writer", id: "com.acme.Writer", version: "1.0", in: drive))
        fixture.launchServices["com.acme.Writer"] = known
        #expect(OldApps.copies(fixture.env).isEmpty)

        let downloads = fixture.home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let loose = try fixture.app("Writer", id: "com.acme.Writer", version: "1.0", in: downloads)
        fixture.launchServices["com.acme.Writer"] = known + [loose]
        #expect(OldApps.copies(fixture.env).map(\.path) == [downloads.appendingPathComponent("Writer.app").path])
    }

    @Test("A newer copy somewhere else isn't listed: it may be what's next")
    func newerCopyInDownloads() throws {
        let fixture = try OldAppsFixture()
        try fixture.app("Writer", id: "com.acme.Writer", version: "2.0")
        let downloads = fixture.home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fixture.launchServices["com.acme.Writer"] = [fixture.app("Writer", id: "com.acme.Writer", version: "3.0", in: downloads)]
        #expect(OldApps.copies(fixture.env).isEmpty)
    }

    @Test("The installed app is never offered up for one running from Downloads")
    func runningFromDownloads() throws {
        let fixture = try OldAppsFixture()
        try fixture.app("Writer", id: "com.acme.Writer", version: "1.0")
        let downloads = fixture.home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let loose = try fixture.app("Writer", id: "com.acme.Writer", version: "2.0", in: downloads)
        fixture.launchServices["com.acme.Writer"] = [loose]
        fixture.inUse = [loose.appendingPathComponent("Contents/MacOS/Writer").path]
        #expect(OldApps.copies(fixture.env).isEmpty)
    }

    // MARK: Checked again right before the Trash

    @Test("A copy goes only while the one that stays is there, and it hasn't started running")
    func copyRecheck() throws {
        let fixture = try OldAppsFixture()
        let kept = try fixture.app("Writer", id: "com.acme.Writer", version: "2.0")
        let old = try fixture.app("Writer Old", id: "com.acme.Writer", version: "1.0", bundleName: "Writer", executable: "Writer")
        #expect(OldApps.stillCopy(old.path, keeping: kept.path, env: fixture.env))
        fixture.inUse = [old.appendingPathComponent("Contents/MacOS/Writer").path]
        #expect(!OldApps.stillCopy(old.path, keeping: kept.path, env: fixture.env))
        fixture.inUse = []
        #expect(!OldApps.stillCopy(kept.path, keeping: kept.path, env: fixture.env))
        try FileManager.default.removeItem(at: kept)
        #expect(!OldApps.stillCopy(old.path, keeping: kept.path, env: fixture.env))
    }

    @Test("A leftover goes only while it still is one")
    func leftoverRecheck() throws {
        let fixture = try OldAppsFixture()
        try fixture.hadWindows("com.gone.App")
        let support = try fixture.folder("Application Support/com.gone.App")
        #expect(OldApps.stillLeftover(support.path, env: fixture.env))
        #expect(!OldApps.stillLeftover(fixture.home.appendingPathComponent("Documents/com.gone.App").path, env: fixture.env))
        // Used again since the list was made.
        try Data([1]).write(to: support.appendingPathComponent("new.db"))
        #expect(!OldApps.stillLeftover(support.path, env: fixture.env))
        try FileManager.default.removeItem(at: support.appendingPathComponent("new.db"))
        try fixture.age(support, fixture.old)
        #expect(OldApps.stillLeftover(support.path, env: fixture.env))
        // Installed again since the list was made.
        try fixture.app("Back", id: "com.gone.App")
        #expect(!OldApps.stillLeftover(support.path, env: fixture.env))
    }

    @Test("The scope: the Library folders' top only, no containers; apps in their folders")
    func scope() {
        let scope = CleanupScope.oldApps(home: "/Users/me")
        #expect(scope.allows("/Users/me/Library/Caches/com.gone.App"))
        #expect(scope.allows("/Users/me/Library/Preferences/com.gone.App.plist"))
        #expect(scope.allows("/Users/me/Library/Preferences/ByHost/com.gone.App.ABC.plist"))
        #expect(scope.allows("/Applications/Old/Writer.app"))
        #expect(scope.allows("/Users/me/Applications/Writer.app"))
        #expect(scope.allows("/Users/me/Downloads/Writer.app"))
        #expect(!scope.allows("/Users/me/Library/Caches"))
        #expect(!scope.allows("/Users/me/Library/Caches/com.gone.App/inside"))
        #expect(!scope.allows("/Users/me/Library/Containers/com.gone.App"))
        #expect(!scope.allows("/Users/me/Library/Group Containers/TEAM.com.gone.App"))
        #expect(!scope.allows("/Users/me/Library/Mail/V10"))
        #expect(!scope.allows("/Users/me/Documents/Writer.app"))
        #expect(!scope.allows("/System/Applications/Notes.app"))
        #expect(!scope.allows("/Users/me/Library/Caches/../Mail"))
    }
}
