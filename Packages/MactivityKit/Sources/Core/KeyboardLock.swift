import Foundation

/// Cleaning the keyboard (D-203): every key does nothing until the same shortcut, ⌃⌥K, is
/// pressed again, Unlock is clicked, or five minutes pass. Pure: which key unlocks, and when the
/// lock ends. The event tap that swallows keys is the app's.
public enum KeyboardLock {
    /// The lock never outlasts this: a keyboard that won't come back is worse than a sticky one.
    public static let duration: TimeInterval = 5 * 60
    /// K on any layout's physical key position (`kVK_ANSI_K`).
    public static let keyCode: Int64 = 0x28

    /// Modifier bits of a `CGEventFlags` raw value: Shift, Control, Option, Command.
    public static let shift: UInt64 = 0x20000
    public static let control: UInt64 = 0x40000
    public static let option: UInt64 = 0x80000
    public static let command: UInt64 = 0x100000

    /// ⌃⌥K exactly: Control and Option down, Shift and Command up, so ⌃⌥⇧K doesn't unlock. A
    /// shortcut the person chose for Clean Keyboard (1.6) unlocks too; ⌃⌥K always does, so a
    /// changed or cleared shortcut can't leave the keyboard locked.
    public static func isUnlock(keyCode: Int64, flags: UInt64, shortcut: KeyShortcut? = nil) -> Bool {
        let modifiers = flags & (shift | control | option | command)
        if keyCode == Self.keyCode, modifiers == control | option {
            return true
        }
        return shortcut?.matches(keyCode: keyCode, flags: flags) ?? false
    }

    /// Seconds left of a lock that started at `start`; zero once it's over.
    public static func remaining(since start: Date, now: Date) -> TimeInterval {
        max(0, duration - now.timeIntervalSince(start))
    }
}
