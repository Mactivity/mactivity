import Foundation
import Testing
@testable import UI

@MainActor
@Suite("Icons for bundles without one (D-167)")
struct AppIconLookupTests {
    @Test("A bundle in an app's support folder takes that app's icon")
    func owningApp() {
        let path = "/Users/demo/Library/Application Support/Claude/claude-code/2.1.295/abc/claude.app"
        #expect(AppIconLookup.owningApp(of: path) { $0 == "/Applications/Claude.app" } == "/Applications/Claude.app")
        #expect(AppIconLookup.owningApp(of: path) { $0 == "/Users/demo/Applications/Claude.app" } == "/Users/demo/Applications/Claude.app")
        #expect(AppIconLookup.owningApp(of: path) { _ in false } == nil)
        #expect(AppIconLookup.owningApp(of: "/Applications/Xcode.app") { _ in true } == nil)
    }

    @Test("Live: Claude Code's claude.app has no icon of its own, Safari does")
    func ownIcon() {
        #expect(AppIconLookup.hasOwnIcon("/Applications/Safari.app"))
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code")
        guard let version = try? FileManager.default.contentsOfDirectory(atPath: support.path).first else {
            return
        }
        let builds = support.appendingPathComponent(version)
        guard let build = try? FileManager.default.contentsOfDirectory(atPath: builds.path).first else {
            return
        }
        let app = builds.appendingPathComponent(build).appendingPathComponent("claude.app").path
        if FileManager.default.fileExists(atPath: app) {
            #expect(!AppIconLookup.hasOwnIcon(app))
        }
    }
}
