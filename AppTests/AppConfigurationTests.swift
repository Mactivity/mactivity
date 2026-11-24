import Foundation
@testable import Mactivity
import Testing
import UI

/// Checks the built app bundle is configured the way the spec requires.
@Suite("App configuration")
struct AppConfigurationTests {
    private let info = Bundle.main.infoDictionary ?? [:]

    @Test("Bundle ID and deployment target")
    func identity() {
        #expect(Bundle.main.bundleIdentifier == "app.mactivity.Mactivity")
        #expect(info["LSMinimumSystemVersion"] as? String == "26.0")
    }

    @Test("App icon comes from the Icon Composer asset")
    func icon() {
        #expect(info["CFBundleIconName"] as? String == "Mactivity")
    }

    @Test("Real sampling by default; the toggle persists and the next launch follows it")
    @MainActor
    func simulatedToggle() throws {
        let suite = "AppConfigurationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!AppModel(defaults: defaults, startsServices: false).services.metrics.isSimulated)

        defaults.set(true, forKey: PreferenceKey.simulatedData)
        let model = AppModel(defaults: defaults, startsServices: false)
        #expect(model.isSimulated)
        #expect(model.services.metrics.isSimulated)

        model.isSimulated = false
        #expect(!defaults.bool(forKey: PreferenceKey.simulatedData))
        #expect(!AppModel(defaults: defaults, startsServices: false).services.metrics.isSimulated)
    }

    @Test("Hosted by the tests, Mactivity starts nothing")
    func testHost() {
        #expect(MactivityMain.isTestHost)
    }
}
