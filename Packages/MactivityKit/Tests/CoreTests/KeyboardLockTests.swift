@testable import Core
import Foundation
import Testing

/// The keyboard cleaning lock (D-203).
struct KeyboardLockTests {
    @Test("Only ⌃⌥K unlocks: not K, not ⌃K, not ⌃⌥⇧K or ⌃⌥⌘K")
    func unlockKey() {
        let controlOption = KeyboardLock.control | KeyboardLock.option
        #expect(KeyboardLock.isUnlock(keyCode: 0x28, flags: controlOption))
        // Caps Lock and the device-dependent bits don't matter.
        #expect(KeyboardLock.isUnlock(keyCode: 0x28, flags: controlOption | 0x10000 | 0x101))
        #expect(!KeyboardLock.isUnlock(keyCode: 0x28, flags: 0))
        #expect(!KeyboardLock.isUnlock(keyCode: 0x28, flags: KeyboardLock.control))
        #expect(!KeyboardLock.isUnlock(keyCode: 0x28, flags: controlOption | KeyboardLock.shift))
        #expect(!KeyboardLock.isUnlock(keyCode: 0x28, flags: controlOption | KeyboardLock.command))
        #expect(!KeyboardLock.isUnlock(keyCode: 0x2E, flags: controlOption))
    }

    @Test("It ends by itself after five minutes")
    func ends() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(KeyboardLock.remaining(since: start, now: start) == 300)
        #expect(KeyboardLock.remaining(since: start, now: start + 299) == 1)
        #expect(KeyboardLock.remaining(since: start, now: start + 400) == 0)
    }
}

/// Quick Search names the newer actions (D-203, D-207).
struct QuickSearchActionTests {
    @Test("Clean Keyboard and Compare only once the words can't be an app's name (D-219)")
    func actions() {
        #expect(QuickSearch.actions("clean k").contains(.cleanKeyboard))
        #expect(QuickSearch.actions("lock keyb").contains(.cleanKeyboard))
        #expect(QuickSearch.actions("keyboard l").contains(.cleanKeyboard))
        #expect(!QuickSearch.actions("clean").contains(.cleanKeyboard), "CleanShot, CleanMyMac")
        #expect(!QuickSearch.actions("keyboard").contains(.cleanKeyboard), "Keyboard Maestro")
        #expect(!QuickSearch.actions("keyboard m").contains(.cleanKeyboard))
        #expect(QuickSearch.actions("compar").contains(.compare))
        #expect(!QuickSearch.actions("comp").contains(.compare), "Compressor")
        #expect(!QuickSearch.actions("safari").contains(.compare))
    }
}
