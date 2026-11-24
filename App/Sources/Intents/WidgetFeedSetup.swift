import Foundation
import Readouts
import WidgetKit

@MainActor
extension WidgetFeed {
    /// The feed for this build, or nil when widgets can't get data: ad-hoc builds have no team,
    /// so no `<TEAMID>.app.mactivity` app group, and nothing is written (no file, no prompt, no
    /// reload). The widgets then say "Open Mactivity". A Developer ID build turns it on.
    static func forThisApp() -> WidgetFeed? {
        let url = WidgetFeed.fileURL(teamID: HelperControl.teamID) { group in
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        }
        guard let url else {
            return nil
        }
        return WidgetFeed(fileURL: url) {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.todayWidgetKind)
        }
    }
}

/// Control Center's Clean Keyboard and Stay Awake (D-210): the state the controls read, written at
/// launch and whenever Stay Awake turns on or off, and the token their links must carry. Only
/// with a widget feed: the controls read it from the same app group, which needs a signed build.
@MainActor
final class ControlPublisher {
    /// Kept from launch to launch: a control used while Mactivity isn't running opens it with
    /// the token it last wrote.
    let token: String
    private let url: URL
    private var written: ControlState?

    init(widgetFile: URL) {
        url = ControlState.fileURL(widgetFile: widgetFile)
        token = ControlState.read(url)?.token ?? UUID().uuidString
    }

    func update(stayAwake: Bool) {
        let state = ControlState(token: token, stayAwake: stayAwake)
        guard state != written else {
            return
        }
        do {
            try state.write(url)
            written = state
        } catch {
            return
        }
        ControlCenter.shared.reloadControls(ofKind: ControlLink.stayAwakeKind)
        WidgetCenter.shared.reloadTimelines(ofKind: ControlLink.stayAwakeWidgetKind)
    }
}
