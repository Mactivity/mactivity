import Foundation

/// A key with modifiers, as the person typed it (1.6, your own shortcuts). The label is kept
/// from when it was recorded: what the key prints depends on the keyboard layout.
public struct KeyShortcut: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// The key's physical position (a `kVK_` code), the same on every layout.
    public let keyCode: Int
    public let modifiers: Modifiers
    /// "M", "K", "F5": what the key printed when recorded.
    public let key: String

    public init(keyCode: Int, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// "⌃⌥⇧⌘M", in the order macOS shows them.
    public var label: String {
        var text = ""
        if modifiers.contains(.control) {
            text += "⌃"
        }
        if modifiers.contains(.option) {
            text += "⌥"
        }
        if modifiers.contains(.shift) {
            text += "⇧"
        }
        if modifiers.contains(.command) {
            text += "⌘"
        }
        return text + key
    }

    /// Pure: a global shortcut needs Control, Option or Command, or it would take a key away from
    /// typing everywhere. Function keys may stand alone.
    public var isUsable: Bool {
        !modifiers.isDisjoint(with: [.control, .option, .command]) || Self.functionKeys.contains(keyCode)
    }

    /// F1–F20's key codes.
    static let functionKeys: Set<Int> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]

    /// ⌃⌥M, Quick Search's since D-137.
    public static let quickSearch = KeyShortcut(keyCode: 0x2E, modifiers: [.control, .option], key: "M")
    /// ⌃⌥K, Clean Keyboard's since D-203.
    public static let cleanKeyboard = KeyShortcut(keyCode: Int(KeyboardLock.keyCode), modifiers: [.control, .option], key: "K")

    /// Whether a `CGEventFlags` raw value and key code are this shortcut, exactly: ⌃⌥⇧K isn't ⌃⌥K.
    public func matches(keyCode: Int64, flags: UInt64) -> Bool {
        keyCode == Int64(self.keyCode) && Self.modifiers(cgFlags: flags) == modifiers
    }

    /// The modifiers in a `CGEventFlags` raw value.
    public static func modifiers(cgFlags flags: UInt64) -> Modifiers {
        var modifiers: Modifiers = []
        if flags & KeyboardLock.control != 0 {
            modifiers.insert(.control)
        }
        if flags & KeyboardLock.option != 0 {
            modifiers.insert(.option)
        }
        if flags & KeyboardLock.shift != 0 {
            modifiers.insert(.shift)
        }
        if flags & KeyboardLock.command != 0 {
            modifiers.insert(.command)
        }
        return modifiers
    }
}
