import AppIntents
import Readouts
import SwiftUI
import WidgetKit

// Control Center and menu bar controls (D-210): Clean Keyboard, and Stay Awake on or off. Each
// opens a `mactivity://control/…` link with the token Mactivity wrote to the shared container,
// so Mactivity does the work, opening first if it isn't running. Signed builds only, like the
// widgets: the container needs the team's app group.

struct CleanKeyboardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlLink.cleanKeyboardKind) {
            ControlWidgetButton(action: CleanKeyboardIntent()) {
                Label("Clean Keyboard", systemImage: "keyboard")
            }
        }
        .displayName("Clean Keyboard")
        .description("Locks every key while you wipe the keyboard. ⌃⌥K, Unlock or five minutes ends it.")
    }
}

struct StayAwakeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlLink.stayAwakeKind, provider: StayAwakeValue()) { isOn in
            ControlWidgetToggle("Stay Awake", isOn: isOn, action: StayAwakeIntent()) { on in
                Label(on ? "On" : "Off", systemImage: on ? "cup.and.saucer.fill" : "cup.and.saucer")
            }
        }
        .displayName("Stay Awake")
        .description("Keeps your Mac from sleeping until you switch it off. It still lets go on a low battery or when hot.")
    }
}

struct StayAwakeValue: ControlValueProvider {
    var previewValue: Bool {
        false
    }

    func currentValue() async throws -> Bool {
        ControlsFile.state?.stayAwake ?? false
    }
}

struct CleanKeyboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Keyboard"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult & OpensIntent {
        try .result(opensIntent: OpenURLIntent(ControlsFile.link(.cleanKeyboard)))
    }
}

struct StayAwakeIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Stay Awake"
    static let isDiscoverable = false

    @Parameter(title: "Stay Awake")
    var value: Bool

    func perform() async throws -> some IntentResult & OpensIntent {
        try .result(opensIntent: OpenURLIntent(ControlsFile.link(.stayAwake(value))))
    }
}

/// The state Mactivity writes for the controls, beside the widget file.
enum ControlsFile {
    struct NotReady: Error, CustomLocalizedStringResourceConvertible {
        var localizedStringResource: LocalizedStringResource {
            "Open Mactivity once, then try again."
        }
    }

    static var state: ControlState? {
        SharedFile.url.flatMap { ControlState.read(ControlState.fileURL(widgetFile: $0)) }
    }

    static func link(_ action: ControlLink.Action) throws -> URL {
        guard let token = state?.token, let url = ControlLink.url(action, token: token) else {
            throw NotReady()
        }
        return url
    }
}
