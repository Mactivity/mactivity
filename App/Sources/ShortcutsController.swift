import AppKit
import Carbon.HIToolbox
import Core
import UI

/// Your own shortcuts (1.6): registers every shortcut in `ShortcutStore` as a global hot key,
/// again whenever one changes, and none while one is being recorded.
@MainActor
final class ShortcutsController {
    static let shared = ShortcutsController()

    private var registered: [EventHotKeyRef] = []

    /// Registers the shortcuts now and whenever they change. Never for screenshots, the demo
    /// video or measurements.
    func start() {
        guard !LaunchOverrides.isScreenshotMode else {
            return
        }
        ShortcutStore.shared.onChange = { [weak self] in self?.reregister() }
        reregister()
    }

    private func reregister() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered = []
        let store = ShortcutStore.shared
        guard !store.isRecording else {
            return
        }
        var taken: Set<String> = []
        for action in ShortcutAction.all {
            guard let shortcut = store.shortcut(for: action) else {
                continue
            }
            if let reference = GlobalHotKeys.register(
                id: action.hotKeyID, keyCode: shortcut.keyCode, modifiers: Self.carbon(shortcut.modifiers), action: { Self.run(action) }
            ) {
                registered.append(reference)
            } else {
                taken.insert(action.id)
            }
        }
        store.taken = taken
    }

    static func carbon(_ modifiers: KeyShortcut.Modifiers) -> Int {
        var flags = 0
        if modifiers.contains(.control) {
            flags |= controlKey
        }
        if modifiers.contains(.option) {
            flags |= optionKey
        }
        if modifiers.contains(.shift) {
            flags |= shiftKey
        }
        if modifiers.contains(.command) {
            flags |= cmdKey
        }
        return flags
    }

    static func run(_ action: ShortcutAction) {
        let services = AppModel.shared.services
        switch action {
        case .quickSearch:
            QuickSearchPanel.shared.toggle()
        case .cleanKeyboard:
            KeyboardLockController.shared.lock()
        case .stayAwake:
            services.keepAwake.set(services.keepAwake.isOn ? .off : .indefinitely)
        case let .page(item):
            services.navigation.selection = item
            services.navigation.openMainWindow()
            NSApplication.shared.activate()
        }
    }
}
