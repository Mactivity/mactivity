import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Core
import os
import SwiftUI
import UI

/// Clean Keyboard (D-203): ⌃⌥K, View → Clean Keyboard or Quick Search locks every key, media and
/// brightness keys included, until ⌃⌥K again, Unlock, or five minutes. The pointer keeps working.
///
/// A session event tap (public API) that drops key events; it needs Accessibility permission,
/// which macOS asks for the first time. The tap exists only while locked and looks at nothing but
/// each key's code and modifiers, to find ⌃⌥K. Nothing is recorded.
@MainActor
final class KeyboardLockController {
    static let shared = KeyboardLockController()
    private static let log = Logger(subsystem: "app.mactivity.app", category: "keyboardlock")

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var panel: NSPanel?
    private var timeout: Task<Void, Never>?

    var isLocked: Bool {
        tap != nil
    }

    func lock() {
        guard !isLocked else {
            return
        }
        // Asks macOS to show its Accessibility prompt the first time; locking works once it's on.
        // `kAXTrustedCheckOptionPrompt`'s value; the global itself isn't concurrency-safe to read.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            Self.log.notice("Clean Keyboard: waiting for Accessibility permission")
            // macOS prompts only once. After that, say so ourselves, or ⌃⌥K would do nothing
            // visible and the next key typed would land in the app in front (D-219).
            if UserDefaults.standard.bool(forKey: Self.promptedKey) {
                Self.explainPermission()
            }
            UserDefaults.standard.set(true, forKey: Self.promptedKey)
            return
        }
        // NX_SYSDEFINED (14): the media, volume and brightness keys.
        let types: [UInt32] = [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, 14]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: keyboardLockTap, userInfo: nil
        ) else {
            Self.log.error("Clean Keyboard: the event tap couldn't be created")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        let endsAt = Date().addingTimeInterval(KeyboardLock.duration)
        showPanel(endsAt: endsAt)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(KeyboardLock.duration))
            guard !Task.isCancelled else {
                return
            }
            self?.unlock()
        }
        Self.log.info("Clean Keyboard: locked")
    }

    private static let promptedKey = "keyboardLock.accessibilityPrompted"

    private static func explainPermission() {
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Clean Keyboard needs Accessibility")
        alert.informativeText = String(localized: """
        To hold back key presses while you wipe the keyboard, Mactivity needs to be allowed in System Settings → \
        Privacy & Security → Accessibility. The keyboard isn't locked.
        """)
        alert.addButton(withTitle: String(localized: "Open Accessibility Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func unlock() {
        timeout?.cancel()
        timeout = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        Self.log.info("Clean Keyboard: unlocked")
    }

    /// macOS turns a tap off when a callback is slow or on some user input; it stays on while locked.
    fileprivate func reenable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func showPanel(endsAt: Date) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: KeyboardLockView(endsAt: endsAt) {
            KeyboardLockController.shared.unlock()
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 24)))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 480, height: 360))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        // Mactivity in front takes the keyboard's focus from wherever it was, so a key that gets
        // past the tap (a password field's secure input hides keys from taps) lands here.
        NSApplication.shared.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = LockPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

/// Drops every key event while locked; ⌃⌥K or Clean Keyboard's own shortcut unlocks. Runs on the main run loop.
private func keyboardLockTap(
    proxy _: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        MainActor.assumeIsolated { KeyboardLockController.shared.reenable() }
        return Unmanaged.passUnretained(event)
    case .keyDown:
        let shortcut = MainActor.assumeIsolated { ShortcutStore.shared.shortcut(for: .cleanKeyboard) }
        if KeyboardLock.isUnlock(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags.rawValue,
            shortcut: shortcut
        ) {
            // After this callback returns: the tap is removed from inside its own callback otherwise.
            Task { @MainActor in KeyboardLockController.shared.unlock() }
        }
        return nil
    default:
        return nil
    }
}

/// A borderless panel can't become key unless it says so.
private final class LockPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}
