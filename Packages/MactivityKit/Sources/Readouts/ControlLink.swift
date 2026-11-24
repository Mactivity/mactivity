import Foundation

/// Control Center controls (D-210): Clean Keyboard, and Stay Awake on or off, as links the
/// controls open in Mactivity. Each link carries a token that only Mactivity and its widget
/// extension can read, from their shared container, so a web page or another app opening
/// `mactivity://control/…` does nothing.
public enum ControlLink {
    public enum Action: Equatable, Sendable {
        case cleanKeyboard
        case stayAwake(Bool)
        /// The Today so far widget's button (1.6): History, on today's Your day.
        case yourDay
    }

    public static let cleanKeyboardKind = "app.mactivity.control.clean-keyboard"
    public static let stayAwakeKind = "app.mactivity.control.stay-awake"
    /// The Stay Awake desktop widget (1.6), reloaded with the control.
    public static let stayAwakeWidgetKind = "app.mactivity.widget.stay-awake"
    static let host = "control"

    public static func url(_ action: Action, token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mactivity"
        components.host = host
        switch action {
        case .cleanKeyboard:
            components.path = "/clean-keyboard"
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        case let .stayAwake(on):
            components.path = "/stay-awake"
            components.queryItems = [URLQueryItem(name: "on", value: on ? "1" : "0"), URLQueryItem(name: "token", value: token)]
        case .yourDay:
            components.path = "/your-day"
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        return components.url
    }

    /// The action, when `url` is a control link with `token`; nil for anything else, a missing
    /// or wrong token, or no token on this Mac yet.
    public static func action(_ url: URL, token: String?) -> Action? {
        guard url.scheme == "mactivity", url.host == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token, !token.isEmpty, items.first(where: { $0.name == "token" })?.value == token else {
            return nil
        }
        switch url.path {
        case "/clean-keyboard": return .cleanKeyboard
        case "/stay-awake": return .stayAwake(items.first { $0.name == "on" }?.value == "1")
        case "/your-day": return .yourDay
        default: return nil
        }
    }
}

/// What the controls read: the link token, and whether Stay Awake is on. Written by Mactivity
/// at launch and when Stay Awake changes; `controls.json` beside the widget file.
public struct ControlState: Codable, Sendable, Equatable {
    public var token: String
    public var stayAwake: Bool

    public init(token: String, stayAwake: Bool) {
        self.token = token
        self.stayAwake = stayAwake
    }

    /// Beside the widget file in the app group's container.
    public static func fileURL(widgetFile: URL) -> URL {
        widgetFile.deletingLastPathComponent().appendingPathComponent("controls.json")
    }

    public static func read(_ url: URL) -> ControlState? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ControlState.self, from: $0) }
    }

    public func write(_ url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
