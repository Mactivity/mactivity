import Foundation
import Testing
@testable import UI

/// What's New after an update, and only then (D-179).
@MainActor
struct WhatsNewTests {
    private func defaults(_ test: String = #function) throws -> UserDefaults {
        let name = "app.mactivity.tests.whatsnew.\(test.prefix { $0 != "(" })"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aFirstLaunchSaysNothing() throws {
        let defaults = try defaults()
        #expect(WhatsNewModel(version: "1.0.6", defaults: defaults).pendingVersion == nil)
        #expect(defaults.string(forKey: WhatsNewModel.lastSeenKey) == "1.0.6")
    }

    @Test func theSameVersionAgainSaysNothing() throws {
        let defaults = try defaults()
        defaults.set("1.0.6", forKey: WhatsNewModel.lastSeenKey)
        #expect(WhatsNewModel(version: "1.0.6", defaults: defaults).pendingVersion == nil)
    }

    @Test func anUpdateWithoutNotesSaysNothing() throws {
        // The test bundle has no release notes.
        let defaults = try defaults()
        defaults.set("1.0.5", forKey: WhatsNewModel.lastSeenKey)
        #expect(WhatsNewModel(version: "9.9.9", defaults: defaults, bundle: .main).pendingVersion == nil)
        #expect(defaults.string(forKey: WhatsNewModel.lastSeenKey) == "9.9.9")
    }

    @Test func anUpdateFromBeforeTheKeyIsAnUpdate() throws {
        // 1.0.5 and earlier recorded no version, but onboarding was done.
        let defaults = try defaults()
        defaults.set(true, forKey: PreferenceKey.hasCompletedOnboarding)
        let bundle = try #require(Bundle(path: #filePath.replacingOccurrences(
            of: "/Packages/MactivityKit/Tests/UITests/WhatsNewTests.swift",
            with: "/docs"
        )))
        // docs/releases/1.0.5.md is there: the release notes of a version that exists.
        let model = WhatsNewModel(version: "1.0.5", defaults: defaults, bundle: bundle)
        #expect(model.pendingVersion == "1.0.5")
    }

    @Test func notesAreTheListLines() {
        let text = "- New: **History for any app.** Right-click.\n- Fixed a thing.\n\nNot a note\n-  \n"
        #expect(WhatsNewModel.lines(text) == ["New: **History for any app.** Right-click.", "Fixed a thing."])
    }

    @Test func dismissingClearsIt() {
        let model = WhatsNewModel(pending: "1.0.6", notes: ["A fix."])
        model.open()
        #expect(model.isPresented)
        model.dismiss()
        #expect(model.pendingVersion == nil)
        #expect(!model.isPresented)
    }
}
