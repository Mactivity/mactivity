import AppKit
import Core
import Observation
import SwiftUI

/// What a shortcut does (1.6, your own shortcuts).
public enum ShortcutAction: Hashable, Sendable, Identifiable {
    case quickSearch, cleanKeyboard, stayAwake
    /// Opens the main window on a page.
    case page(SidebarItem)

    public static var all: [ShortcutAction] {
        [.quickSearch, .cleanKeyboard, .stayAwake] + SidebarItem.allCases.map(ShortcutAction.page)
    }

    public var id: String {
        switch self {
        case .quickSearch: "quickSearch"
        case .cleanKeyboard: "cleanKeyboard"
        case .stayAwake: "stayAwake"
        case let .page(item): "page." + item.rawValue
        }
    }

    /// The Carbon hot key ID: 1–3 for the actions, 100 on for the pages.
    public var hotKeyID: UInt32 {
        switch self {
        case .quickSearch: 1
        case .cleanKeyboard: 2
        case .stayAwake: 3
        case let .page(item): 100 + UInt32(SidebarItem.allCases.firstIndex(of: item) ?? 0)
        }
    }

    var title: String {
        switch self {
        case .quickSearch: String(localized: "Quick Search", bundle: .strings)
        case .cleanKeyboard: String(localized: "Clean Keyboard", bundle: .strings)
        case .stayAwake: String(localized: "Stay Awake on or off", bundle: .strings, comment: "Shortcut: turns Stay Awake on or off")
        case let .page(item): item.title
        }
    }
}

/// The shortcuts the person chose, kept in the app's defaults (1.6). Before anyone changes them:
/// ⌃⌥M for Quick Search, unless its old switch was off, and ⌃⌥K for Clean Keyboard.
@MainActor
@Observable
public final class ShortcutStore {
    public static let shared = ShortcutStore()

    public private(set) var shortcuts: [String: KeyShortcut]
    /// Shortcuts another app already holds, set by the app when it registers them.
    public var taken: Set<String> = []
    /// While a shortcut is being recorded, none of them work, so the keys reach the recorder.
    public var isRecording = false {
        didSet { onChange() }
    }

    @ObservationIgnored public var onChange: () -> Void = {}
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcuts = Self.load(defaults)
    }

    static func load(_ defaults: UserDefaults) -> [String: KeyShortcut] {
        if let data = defaults.data(forKey: PreferenceKey.keyShortcuts),
           let stored = try? JSONDecoder().decode([String: KeyShortcut].self, from: data) {
            return stored
        }
        return defaultShortcuts(quickSearchOn: defaults.object(forKey: PreferenceKey.quickSearchShortcut) as? Bool ?? true)
    }

    static func defaultShortcuts(quickSearchOn: Bool) -> [String: KeyShortcut] {
        var shortcuts = [ShortcutAction.cleanKeyboard.id: KeyShortcut.cleanKeyboard]
        if quickSearchOn {
            shortcuts[ShortcutAction.quickSearch.id] = .quickSearch
        }
        return shortcuts
    }

    public func shortcut(for action: ShortcutAction) -> KeyShortcut? {
        shortcuts[action.id]
    }

    /// Sets or clears one. A shortcut can do only one thing: another action that had it loses it.
    public func set(_ shortcut: KeyShortcut?, for action: ShortcutAction) {
        if let shortcut {
            for (id, existing) in shortcuts where existing.keyCode == shortcut.keyCode && existing.modifiers == shortcut.modifiers {
                shortcuts[id] = nil
            }
        }
        shortcuts[action.id] = shortcut
        save()
    }

    public func resetToDefaults() {
        shortcuts = Self.defaultShortcuts(quickSearchOn: true)
        save()
    }

    public var isDefault: Bool {
        shortcuts == Self.defaultShortcuts(quickSearchOn: true)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            defaults.set(data, forKey: PreferenceKey.keyShortcuts)
        }
        onChange()
    }
}

/// Settings → General → Keyboard Shortcuts (1.6): a recorder for each action and page.
struct ShortcutsSection: View {
    @Bindable private var store = ShortcutStore.shared
    @State private var showsPages = false

    var body: some View {
        Section {
            ForEach([ShortcutAction.quickSearch, .cleanKeyboard, .stayAwake]) { action in
                row(action)
            }
            DisclosureGroup(isExpanded: $showsPages) {
                ForEach(SidebarItem.allCases, id: \.self) { item in
                    row(.page(item))
                }
            } label: {
                Text("Open a page", bundle: .strings, comment: "Settings: shortcuts that open the main window on a page")
            }
            if !store.isDefault {
                Button(String(localized: "Back to the Defaults", bundle: .strings, comment: "Customize: undoes every choice")) {
                    store.resetToDefaults()
                }
            }
        } header: {
            Text("Keyboard Shortcuts", bundle: .strings)
        } footer: {
            Text("They work from any app. Click one, then press the keys; Delete clears it, Escape cancels.", bundle: .strings)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        LabeledContent {
            ShortcutRecorder(action: action)
        } label: {
            Text(action.title)
            if store.taken.contains(action.id) {
                Text("Another app uses this shortcut, so it doesn't reach Mactivity.", bundle: .strings)
                    .foregroundStyle(Tokens.Colors.strainLabel)
            }
        }
    }
}

/// A button that shows a shortcut and, clicked, records the next one typed.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @State private var recording = false
    @State private var hint: String?
    @State private var monitor: Any?
    private var store: ShortcutStore {
        ShortcutStore.shared
    }

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(label)
                .monospacedDigit()
                .frame(minWidth: 96)
        }
        .help(hint ?? "")
        .onDisappear { stop() }
        .accessibilityLabel(Text(action.title))
        .accessibilityValue(Text(store.shortcut(for: action)?.label ?? String(localized: "None", bundle: .strings)))
    }

    private var label: String {
        if recording {
            return hint ?? String(localized: "Type keys…", bundle: .strings, comment: "Shortcut recorder: waiting for keys")
        }
        return store.shortcut(for: action)?.label ?? String(localized: "None", bundle: .strings, comment: "Shortcut recorder: no shortcut")
    }

    private func start() {
        recording = true
        hint = nil
        store.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if recording {
            recording = false
            store.isRecording = false
        }
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 0x35: // Escape
            stop()
        case 0x33, 0x75: // Delete, Forward Delete
            store.set(nil, for: action)
            stop()
        default:
            let shortcut = KeyShortcut(
                keyCode: Int(event.keyCode), modifiers: Self.modifiers(event.modifierFlags), key: Self.keyLabel(event)
            )
            guard shortcut.isUsable else {
                hint = String(localized: "Add ⌘, ⌃ or ⌥", bundle: .strings, comment: "Shortcut recorder: a key alone isn't allowed")
                return
            }
            store.set(shortcut, for: action)
            stop()
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyShortcut.Modifiers {
        var modifiers: KeyShortcut.Modifiers = []
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        return modifiers
    }

    /// What the key prints, without its modifiers; named keys get their names.
    static func keyLabel(_ event: NSEvent) -> String {
        let named: [UInt16: String] = [
            0x31: "Space", 0x24: "↩", 0x30: "⇥", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
            0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        ]
        if let name = named[event.keyCode] {
            return name
        }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
