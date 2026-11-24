import Core
import Foundation
import Testing
@testable import UI

/// Your own shortcuts (1.6).
@MainActor
struct ShortcutStoreTests {
    func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ShortcutStoreTests-\(UUID().uuidString)"))
    }

    @Test("At first: ⌃⌥M and ⌃⌥K; no ⌃⌥M if its old switch was off")
    func firstShortcuts() throws {
        let fresh = try ShortcutStore(defaults: defaults())
        #expect(fresh.shortcut(for: .quickSearch) == .quickSearch)
        #expect(fresh.shortcut(for: .cleanKeyboard) == .cleanKeyboard)
        #expect(fresh.shortcut(for: .stayAwake) == nil)
        let off = try defaults()
        off.set(false, forKey: PreferenceKey.quickSearchShortcut)
        #expect(ShortcutStore(defaults: off).shortcut(for: .quickSearch) == nil)
    }

    @Test("A shortcut does one thing: given to another action, the first loses it; choices persist")
    func oneThing() throws {
        let saved = try defaults()
        let store = ShortcutStore(defaults: saved)
        store.set(.quickSearch, for: .page(.cpu))
        #expect(store.shortcut(for: .quickSearch) == nil)
        #expect(store.shortcut(for: .page(.cpu)) == .quickSearch)
        store.set(nil, for: .cleanKeyboard)
        let again = ShortcutStore(defaults: saved)
        #expect(again.shortcut(for: .page(.cpu)) == .quickSearch)
        #expect(again.shortcut(for: .cleanKeyboard) == nil)
        again.resetToDefaults()
        #expect(again.isDefault)
    }

    @Test("Hot key IDs are unique")
    func uniqueIDs() {
        let ids = ShortcutAction.all.map(\.hotKeyID)
        #expect(Set(ids).count == ids.count)
    }
}
