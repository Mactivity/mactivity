import Core
import Foundation
@testable import Storage
import Testing

/// Old app versions and leftovers (D-282). Most of these are false positives: each builds what a
/// real Mac can hold and checks it stays off the list.
@Suite("Old app versions and leftovers: who owns what (D-282)")
struct OldAppsTests {

    // MARK: What's listed

    @Test("An app that's gone: its folders and files under its full ID, with why and what's inside")
    func listsAGoneApp() throws {
        let fixture = try OldAppsFixture()
        try fixture.hadWindows("com.gone.App")
        try fixture.folder("Application Support/com.gone.App")
        try fixture.folder("Caches/com.gone.App")
        try fixture.folder("Logs/com.gone.App")
        try fixture.file("Preferences/com.gone.App.plist")
        try fixture.file("Preferences/ByHost/com.gone.App.3D2C1F00-AAAA-4BBB-8CCC-001122334455.plist")
        let items = OldApps.leftovers(fixture.env)
        #expect(items.map { ($0.path as NSString).lastPathComponent }.sorted() == [
            "com.gone.App", "com.gone.App", "com.gone.App", "com.gone.App.3D2C1F00-AAAA-4BBB-8CCC-001122334455.plist",
            "com.gone.App.plist", "com.gone.App.savedState",
        ])
        let support = try #require(items.first { $0.kind == .applicationSupport })
        #expect(support.owner == "com.gone.App")
        #expect(!support.matchedByName)
        #expect(support.fileCount == 1)
        #expect(support.contents == ["data.bin"])
        #expect(support.size > 0)
    }

    @Test("Mactivity saw it run: that's the sign, and the row can say its name")
    func recordedApp() throws {
        let fixture = try OldAppsFixture()
        fixture.recorded = [RecordedApp(name: "Gone Writer", bundleID: "com.gone.writer")]
        try fixture.folder("Caches/com.gone.writer")
        #expect(OldApps.leftovers(fixture.env).first?.appName == "Gone Writer")
    }

    @Test("A settings file that remembers a window is the sign too; one without isn't")
    func windowSettings() throws {
        let fixture = try OldAppsFixture()
        try fixture.file("Preferences/com.windows.App.plist", contents: ["NSWindow Frame Main": "0 0 100 100"])
        try fixture.file("Preferences/com.plain.tool.plist", contents: ["verbose": true])
        #expect(fixture.leftoverNames() == ["com.windows.App.plist"])
    }

    @Test("An exact name, of an app Mactivity saw run that's gone")
    func exactName() throws {
        let fixture = try OldAppsFixture()
        fixture.recorded = [RecordedApp(name: "Gone Writer", bundleID: "com.gone.writer")]
        try fixture.folder("Application Support/Gone Writer")
        let item = try #require(OldApps.leftovers(fixture.env).first)
        #expect(item.matchedByName)
        #expect(item.appName == "Gone Writer")
    }

    // MARK: Not listed: someone still owns it

    @Test("The app's installed, whatever the letter case")
    func installed() throws {
        let fixture = try OldAppsFixture()
        try fixture.app("Writer", id: "com.acme.Writer")
        try fixture.hadWindows("com.ACME.writer")
        try fixture.folder("Application Support/com.ACME.writer")
        #expect(fixture.leftoverNames().isEmpty)
    }

    @Test("Helpers and siblings of an installed app share its vendor, under any similar name")
    func sameVendor() throws {
        let fixture = try OldAppsFixture()
        try fixture.app("Writer", id: "com.acme.Writer")
        for id in ["com.acme.Writer.helper", "com.acme.Writer.ShipIt", "com.acme.WriterAgent", "com.acme.Updater"] {
            try fixture.hadWindows(id)
            try fixture.folder("Caches/\(id)")
        }
        #expect(fixture.leftoverNames().isEmpty)
    }

    @Test("A helper inside an installed app, under another vendor's ID")
    func nestedHelper() throws {
        let fixture = try OldAppsFixture()
        let app = try fixture.app("Suite", id: "com.acme.Suite")
        try fixture.app("Login", id: "net.other.loginitem", in: app.appendingPathComponent("Contents/Library/LoginItems"))
        try fixture.hadWindows("net.other.loginitem")
        try fixture.folder("Caches/net.other.loginitem")
        #expect(fixture.leftoverNames().isEmpty)
    }

    @Test("An app installed outside the app folders, known only to Launch Services")
    func installedElsewhere() throws {
        let fixture = try OldAppsFixture()
        fixture.launchServices["com.elsewhere.App"] = [fixture.root.appendingPathComponent("Volumes/Work/Elsewhere.app")]
        try fixture.hadWindows("com.elsewhere.App")
        try fixture.folder("Application Support/com.elsewhere.App")
        #expect(fixture.leftoverNames().isEmpty)
    }

    @Test("An app in a subfolder of the app folders, or in ~/Applications")
    func installedInSubfolders() throws {
        let fixture = try OldAppsFixture()
        let nested = fixture.applications.appendingPathComponent("Suite/Tools")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try fixture.app("Deep", id: "com.deep.App", in: nested)
        let homeApps = fixture.home.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: homeApps, withIntermediateDirectories: true)
        try fixture.app("Mine", id: "com.mine.App", in: homeApps)
        for id in ["com.deep.App", "com.mine.App"] {
            try fixture.hadWindows(id)
            try fixture.folder("Caches/\(id)")
        }
        #expect(fixture.leftoverNames().isEmpty)
    }

    @Test("An app running from anywhere: a build folder, a disk image")
    func runningFromAnywhere() throws {
        let fixture = try OldAppsFixture()
        let build = fixture.root.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let app = try fixture.app("Built", id: "com.built.App", in: build)
        fixture.inUse = [app.appendingPathComponent("Contents/MacOS/Built").path]
        try fixture.hadWindows("com.built.App")
        try fixture.folder("Caches/com.built.App")
        #expect(fixture.leftoverNames().isEmpty)
    }

    @Test("Still set up to run: a launch agent, under the ID or its vendor")
    func launchAgent() throws {
        let fixture = try OldAppsFixture()
        try fixture.file("LaunchAgents/com.tool.daemon.plist")
        try fixture.hadWindows("com.tool.App")
        try fixture.folder("Caches/com.tool.App")
        #expect(fixture.leftoverNames().isEmpty)
    }

    @Test("A program has a file in it open, or runs from inside it")
    func inUse() throws {
        let fixture = try OldAppsFixture()
        try fixture.hadWindows("com.gone.App")
        let support = try fixture.folder("Application Support/com.gone.App")
        fixture.inUse = [support.appendingPathComponent("db.sqlite").path]
        #expect(fixture.leftoverNames() == ["com.gone.App.savedState"])
        let state = fixture.library.appendingPathComponent("Saved Application State/com.gone.App.savedState/window_1.data")
        fixture.inUse = [state.path, support.path]
        #expect(fixture.leftoverNames().isEmpty)
    }
}
