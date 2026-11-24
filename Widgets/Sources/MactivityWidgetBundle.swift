import SwiftUI
import WidgetKit

/// Desktop widgets (E7). The extension is sandboxed and never samples: it reads the small JSON
/// file Mactivity writes into the shared app group container (`Readouts.WidgetSnapshot`).
@main
struct MactivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        SystemWidget()
        TodayWidget()
        // Interactive (1.6).
        StayAwakeWidget()
        // Control Center and the menu bar (D-210).
        CleanKeyboardControl()
        StayAwakeControl()
    }
}
