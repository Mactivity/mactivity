import Core
import Foundation
@testable import Storage
import Testing

@Suite("Old app versions and leftovers: too recent, unsure, never (D-282)")
struct OldAppsNeverListedTests {

    // MARK: Not listed: too recent, or can't be sure

    @Test("Changed lately, even one file deep inside an old folder")
    func recentlyChanged() throws {
        let fixture = try OldAppsFixture()
        try fixture.hadWindows("com.gone.App")
        let support = try fixture.folder("Application Support/com.gone.App")
        let inner = support.appendingPathComponent("deep/deeper")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data([1]).write(to: inner.appendingPathComponent("today.db"))
        try fixture.age(support, fixture.old)
        #expect(fixture.leftoverNames() == ["com.gone.App.savedState"])
    }

    @Test("Part of it can't be read, so it can't be called untouched")
    func unreadable() throws {
        let fixture = try OldAppsFixture()
        try fixture.hadWindows("com.gone.App")
        let support = try fixture.folder("Application Support/com.gone.App")
        let locked = support.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try fixture.age(support, fixture.old)
        try fixture.age(locked, fixture.old)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(fixture.leftoverNames() == ["com.gone.App.savedState"])
    }

    @Test("No sign it was an app: command-line tools and bits of macOS")
    func noEvidence() throws {
        let fixture = try OldAppsFixture()
        try fixture.folder("Application Support/com.charcoaldesign.swiftformat")
        try fixture.folder("Caches/com.charcoaldesign.swiftformat")
        try fixture.file("Preferences/org.cups.PrintingPrefs.plist")
        #expect(fixture.leftoverNames().isEmpty)
    }

    @Test("An app of that name is still here: it only changed its ID")
    func changedID() throws {
        let fixture = try OldAppsFixture()
        try fixture.app("Mactivity", id: "app.mactivity.Mactivity")
        fixture.recorded = [RecordedApp(name: "Mactivity", bundleID: "com.kadeclifton.mactivity")]
        try fixture.file("Preferences/com.kadeclifton.mactivity.plist")
        #expect(fixture.leftoverNames().isEmpty)
    }

    // MARK: Never listed

    @Test("Apple's, shared groups, libraries many apps use, even with signs of an app")
    func untouchable() throws {
        let fixture = try OldAppsFixture()
        for id in [
            "com.apple.Notes", "group.com.foo.shared", "systemgroup.com.apple.x", "iCloud.com.foo.App",
            "org.sparkle-project.Sparkle", "com.crashlytics.data", "org.python.python",
        ] {
            try fixture.hadWindows(id)
            try fixture.folder("Application Support/\(id)")
            try fixture.folder("Caches/\(id)")
        }
        #expect(fixture.leftoverNames().isEmpty)
    }

    @Test("Containers and Group Containers aren't looked in at all")
    func containers() throws {
        let fixture = try OldAppsFixture()
        try fixture.hadWindows("com.gone.App")
        try fixture.folder("Containers/com.gone.App")
        try fixture.folder("Group Containers/TEAM123.com.gone.App")
        #expect(fixture.leftoverNames() == ["com.gone.App.savedState"])
    }

    @Test("Names that aren't full bundle IDs or exact app names")
    func notNames() throws {
        let fixture = try OldAppsFixture()
        fixture.recorded = [
            RecordedApp(name: "Writer", bundleID: "com.gone.writer"), RecordedApp(name: "Code", bundleID: "com.gone.code"),
            RecordedApp(name: "Terminal Thing", bundleID: "com.gone.term", isApp: false),
        ]
        for name in [
            "Google", "Homebrew", "Writer Helper", "writer", "Writers", "Code", "Terminal Thing", "python3.11.5", "data.backup.old",
            "com.gone", "CallHistoryDB",
        ] {
            try fixture.folder("Application Support/\(name)")
        }
        #expect(fixture.leftoverNames().isEmpty)
    }

    @Test("A name in a folder apps don't name things in, or one an installed app goes by")
    func namesOnlyWhereAppsUseThem() throws {
        let fixture = try OldAppsFixture()
        fixture.recorded = [RecordedApp(name: "Gone Writer", bundleID: "com.gone.writer")]
        try fixture.folder("WebKit/Gone Writer")
        try fixture.folder("HTTPStorages/Gone Writer")
        #expect(fixture.leftoverNames().isEmpty)
        try fixture.folder("Caches/Gone Writer")
        try fixture.app("Gone Writer", id: "io.reborn.Writer")
        #expect(fixture.leftoverNames().isEmpty)
    }

    @Test("A link is never followed or listed")
    func links() throws {
        let fixture = try OldAppsFixture()
        try fixture.hadWindows("com.gone.App")
        let outside = fixture.root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let caches = fixture.library.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("com.gone.App"), withDestinationURL: outside)
        #expect(fixture.leftoverNames() == ["com.gone.App.savedState"])
    }

    @Test("What a name in each folder means")
    func ownerNames() {
        #expect(OldApps.ownerName(of: "com.a.b.plist", in: .preferences) == "com.a.b")
        #expect(OldApps.ownerName(of: "com.a.b.txt", in: .preferences) == nil)
        #expect(OldApps.ownerName(of: "com.a.b.savedState", in: .savedState) == "com.a.b")
        #expect(OldApps.ownerName(of: "com.a.b", in: .savedState) == nil)
        #expect(OldApps.ownerName(of: "com.a.b.binarycookies", in: .cookies) == "com.a.b")
        #expect(OldApps.ownerName(of: "com.a.b.binarycookies", in: .httpStorages) == "com.a.b")
        #expect(OldApps.ownerName(of: "com.a.b.ABCDEF12.plist", in: .byHost) == "com.a.b")
        #expect(OldApps.ownerName(of: "com.a.b.plist", in: .byHost) == nil)
        #expect(OldApps.ownerName(of: ".hidden", in: .caches) == nil)
        #expect(OldApps.isFullBundleID("com.foo.App"))
        #expect(!OldApps.isFullBundleID("com.foo"))
        #expect(!OldApps.isFullBundleID("../Mail"))
        #expect(!OldApps.isFullBundleID("data.backup.old"))
    }
}
