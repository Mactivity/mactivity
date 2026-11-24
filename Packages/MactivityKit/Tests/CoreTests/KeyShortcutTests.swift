@testable import Core
import Testing

/// Your own shortcuts (1.6), and Clean Keyboard's unlock.
struct KeyShortcutTests {
    @Test("Labels in macOS's order; a key alone isn't a global shortcut, a function key is")
    func labels() {
        let shortcut = KeyShortcut(keyCode: 0x2E, modifiers: [.command, .shift, .control], key: "M")
        #expect(shortcut.label == "⌃⇧⌘M")
        #expect(!KeyShortcut(keyCode: 0x2E, modifiers: [.shift], key: "M").isUsable)
        #expect(KeyShortcut(keyCode: 0x60, modifiers: [], key: "F5").isUsable)
        #expect(KeyShortcut.quickSearch.label == "⌃⌥M")
    }

    @Test("⌃⌥K always unlocks; a chosen shortcut unlocks too; neither with an extra modifier")
    func unlock() {
        let controlOption = KeyboardLock.control | KeyboardLock.option
        #expect(KeyboardLock.isUnlock(keyCode: 0x28, flags: controlOption))
        let mine = KeyShortcut(keyCode: 0x0E, modifiers: [.command, .option], key: "E")
        #expect(KeyboardLock.isUnlock(keyCode: 0x0E, flags: KeyboardLock.command | KeyboardLock.option, shortcut: mine))
        #expect(KeyboardLock.isUnlock(keyCode: 0x28, flags: controlOption, shortcut: mine))
        let withShift = KeyboardLock.command | KeyboardLock.option | KeyboardLock.shift
        #expect(!KeyboardLock.isUnlock(keyCode: 0x0E, flags: withShift, shortcut: mine))
        #expect(!KeyboardLock.isUnlock(keyCode: 0x28, flags: controlOption | KeyboardLock.shift))
    }
}
