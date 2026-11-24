import AppKit
import SwiftUI

/// Reports whether the hosting window can be seen at all. False when it's completely covered by
/// other windows, minimized, on another Space, or the app is hidden (`NSWindow.occlusionState`).
/// The main window uses it to drop to the idle cadence while nobody can see it (D-061).
struct WindowOcclusionReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context _: Context) -> OcclusionView {
        OcclusionView(onChange: onChange)
    }

    func updateNSView(_ view: OcclusionView, context _: Context) {
        view.onChange = onChange
    }

    final class OcclusionView: NSView {
        var onChange: (Bool) -> Void
        private var observer: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else {
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            onChange(window?.occlusionState.contains(.visible) ?? false)
        }
    }
}
