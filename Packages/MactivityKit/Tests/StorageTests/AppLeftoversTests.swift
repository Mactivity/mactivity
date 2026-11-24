import Foundation
@testable import Storage
import Testing

@Suite("App uninstaller (D-104)")
struct AppLeftoversTests {
    /// A home with an app and its leftovers, and some things that aren't its.
    private func makeHome() throws -> (home: URL, app: URL) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString)")
        let library = home.appendingPathComponent("Library")
        let app = home.appendingPathComponent("Applications/Slackish Chat.app/Contents")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "com.example.slackish", "CFBundleName": "Slackish Chat"]
        try info.write(to: app.appendingPathComponent("Info.plist"))
        for folder in [
            "Application Support/com.example.slackish", "Caches/com.example.slackish", "Containers/com.example.slackish",
            "Group Containers/TEAM123.com.example.slackish", "Application Support/Slackish Chat",
            "Caches/com.example.other", "Preferences/ByHost", "LaunchAgents",
        ] {
            try fm.createDirectory(at: library.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 50000).write(to: library.appendingPathComponent("Caches/com.example.slackish/blob"))
        try Data([1]).write(to: library.appendingPathComponent("Preferences/com.example.slackish.plist"))
        try Data([1]).write(to: library.appendingPathComponent("Preferences/ByHost/com.example.slackish.ABC.plist"))
        try Data([1]).write(to: library.appendingPathComponent("LaunchAgents/com.example.slackish.helper.plist"))
        try Data([1]).write(to: library.appendingPathComponent("LaunchAgents/com.example.slackishness.plist"))
        return (home, home.appendingPathComponent("Applications/Slackish Chat.app"))
    }

    @Test("The app first, then its leftovers by bundle ID; nothing of other apps")
    func plan() throws {
        let (home, app) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let plan = try AppLeftovers.plan(appURL: app, home: home)
        #expect(plan.bundleID == "com.example.slackish")
        #expect(plan.items.first?.kind == .app)
        let names = plan.items.map { ($0.path as NSString).lastPathComponent }
        #expect(names.contains("TEAM123.com.example.slackish"))
        #expect(names.contains("com.example.slackish.ABC.plist"))
        #expect(names.contains("com.example.slackish.helper.plist"))
        #expect(!names.contains("com.example.other"))
        #expect(!names.contains("com.example.slackishness.plist"))
        // The biggest leftover comes right after the app.
        #expect((plan.items[1].path as NSString).lastPathComponent == "com.example.slackish")
        #expect(plan.items[1].kind == .caches)
    }

    @Test("A folder found only by the app's name is marked, so it starts unticked")
    func byName() throws {
        let (home, app) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let plan = try AppLeftovers.plan(appURL: app, home: home)
        let named = plan.items.filter(\.matchedByName)
        #expect(named.map { ($0.path as NSString).lastPathComponent } == ["Slackish Chat"])
        #expect(!AppLeftovers.isSpecificName("Code"))
        #expect(AppLeftovers.isSpecificName("Visual Studio Code"))
    }

    @Test("macOS's own apps and things that aren't apps are refused")
    func refused() {
        #expect(throws: UninstallError.systemApp) {
            try AppLeftovers.plan(appURL: URL(fileURLWithPath: "/System/Applications/Chess.app"))
        }
        #expect(throws: UninstallError.notAnApp) {
            try AppLeftovers.plan(appURL: FileManager.default.temporaryDirectory)
        }
    }

    @Test("A bundle ID or name that's a path never names a folder outside the app's own (D-140)")
    func unsafeNames() {
        #expect(AppLeftovers.isSafeBundleID("com.example.App"))
        #expect(AppLeftovers.isSafeBundleID("com.example.my_app-2"))
        #expect(!AppLeftovers.isSafeBundleID("../Mail"))
        #expect(!AppLeftovers.isSafeBundleID(""))
        #expect(!AppLeftovers.isSafeBundleID("."))
        #expect(!AppLeftovers.isSafeBundleID("com.example/../../Mail"))
        #expect(!AppLeftovers.isSpecificName("../Mail Downloads"))
        #expect(!AppLeftovers.isSpecificName(".hidden folder"))
        let scope = AppLeftovers.leftoverScope(home: URL(fileURLWithPath: "/Users/me"))
        #expect(scope.allows("/Users/me/Library/Caches/com.example.App"))
        #expect(scope.allows("/Users/me/Library/Preferences/ByHost/com.example.App.1234.plist"))
        #expect(!scope.allows("/Users/me/Library/Mail"))
        #expect(!scope.allows("/Users/me/Library/Application Support"))
        #expect(!scope.allows("/Users/me/Library/Caches/com.example.App/../../Mail"))
    }
}
