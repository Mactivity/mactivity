import SwiftUI

/// SwiftUI keeps the views of a closed window (the main window, the menu bar window, Settings)
/// alive: they go on observing `LiveMetrics` and re-evaluating on every snapshot, and now and then
/// render offscreen (D-055). This swaps the content for an empty view of the same size when it
/// disappears, which drops its view tree, observations and cached state, and builds it again when
/// it appears. The placeholder keeps the last size, so a window sized by its content (the menu bar
/// window) reopens at its size rather than growing from nothing (D-086).
struct ReleasedWhileHidden: ViewModifier {
    @State private var isShown = true
    @State private var size: CGSize?

    func body(content: Content) -> some View {
        Group {
            if isShown {
                content
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            } else {
                Color.clear
                    .frame(width: size?.width, height: size?.height)
            }
        }
        .onAppear { isShown = true }
        .onDisappear { isShown = false }
    }
}

extension View {
    /// Drops this view's tree while it's not on screen, and builds it again when it is.
    func releasedWhileHidden() -> some View {
        modifier(ReleasedWhileHidden())
    }
}
