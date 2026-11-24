import Carbon.HIToolbox
import os

/// Shortcuts that work from any app, the ones the person set (1.6; Quick Search's ⌃⌥M, D-137,
/// and Clean Keyboard's ⌃⌥K, D-203, by default). Carbon's `RegisterEventHotKey`: public, and
/// unlike an event tap it needs no Accessibility permission. One handler, which runs the action
/// registered for the key's ID.
@MainActor
enum GlobalHotKeys {
    private static let log = Logger(subsystem: "app.mactivity.app", category: "hotkeys")
    private static var handler: EventHandlerRef?
    private static var actions: [UInt32: @MainActor () -> Void] = [:]

    /// The registration, or nil when another app already holds the shortcut.
    static func register(id key: UInt32, keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) -> EventHotKeyRef? {
        guard installHandler() else {
            return nil
        }
        actions[key] = action
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D41_4354), id: key) // "MACT"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            log.notice("Shortcut \(key) is taken (\(status))")
            return nil
        }
        return reference
    }

    private static func installHandler() -> Bool {
        guard handler == nil else {
            return true
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let read = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard read == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated { GlobalHotKeys.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
        if status != noErr {
            log.error("Shortcut handler not installed (\(status))")
        }
        return status == noErr
    }
}
