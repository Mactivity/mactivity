import Foundation
import Testing
@testable import UI

/// Back and Forward between pages (D-195).
@MainActor
struct BackForwardTests {
    @Test("Back returns through the pages visited, Forward goes again, a new page clears Forward")
    func steps() {
        let navigation = AppNavigation()
        #expect(!navigation.canGoBack)
        navigation.selection = .cpu
        navigation.selection = .history
        navigation.goBack()
        #expect(navigation.selection == .cpu)
        #expect(navigation.canGoForward)
        navigation.goBack()
        #expect(navigation.selection == .overview)
        #expect(!navigation.canGoBack)
        navigation.goForward()
        #expect(navigation.selection == .cpu)
        navigation.selection = .storage
        #expect(!navigation.canGoForward)
        navigation.goBack()
        #expect(navigation.selection == .cpu)
    }

    @Test("Reopening on the last page leaves nothing to go back to")
    func reopening() throws {
        let defaults = try #require(UserDefaults(suiteName: "BackForwardTests"))
        defaults.set(SidebarItem.memory.rawValue, forKey: PreferenceKey.lastSidebarItem)
        let navigation = AppNavigation()
        navigation.remember(in: defaults)
        #expect(navigation.selection == .memory)
        #expect(!navigation.canGoBack)
        defaults.removeObject(forKey: PreferenceKey.lastSidebarItem)
    }
}
