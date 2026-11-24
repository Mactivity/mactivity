import Foundation
import Testing
@testable import UI

/// The main window reopens on the page it showed at the last quit or update.
@MainActor
struct NavigationMemoryTests {
    /// One fixed suite per test: a new name each run left an empty plist in ~/Library/Preferences.
    private func defaults(_ test: String = #function) throws -> UserDefaults {
        let name = "app.mactivity.tests.navigation.\(test.prefix { $0 != "(" })"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func reopensOnTheLastPage() throws {
        let defaults = try defaults()
        let first = AppNavigation()
        first.remember(in: defaults)
        #expect(first.selection == .overview)
        first.selection = .storage

        let next = AppNavigation()
        next.remember(in: defaults)
        #expect(next.selection == .storage)
    }

    @Test func keepsNothingUntilAskedTo() throws {
        let defaults = try defaults()
        // Tests and previews never call remember(in:): their pages aren't saved anywhere.
        let unsaved = AppNavigation()
        unsaved.selection = .history
        #expect(defaults.string(forKey: PreferenceKey.lastSidebarItem) == nil)
        let next = AppNavigation()
        next.remember(in: defaults)
        #expect(next.selection == .overview)
    }

    @Test func ignoresAPageThatNoLongerExists() throws {
        let defaults = try defaults()
        defaults.set("someRemovedTab", forKey: PreferenceKey.lastSidebarItem)
        let navigation = AppNavigation()
        navigation.remember(in: defaults)
        #expect(navigation.selection == .overview)
    }
}
