import AppKit
import Carbon.HIToolbox
import SwiftUI
import UI

/// Quick Search (D-137): its shortcut (⌃⌥M unless changed, `ShortcutsController`) opens a floating search over apps,
/// processes and ports.
@MainActor
final class QuickSearchPanel {
    static let shared = QuickSearchPanel()

    private var panel: NSPanel?
    private var resignObserver: NSObjectProtocol?

    func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: QuickSearchView(services: AppModel.shared.services) { [weak self] in
            self?.close()
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16)))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 560, height: 420))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.2))
        }
        NSApplication.shared.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        // A Quit… confirmation the panel was showing goes with it, rather than reappearing the
        // next time Quick Search opens (D-142).
        let action = AppModel.shared.services.confirmedAction
        if action.pending?.presenter == .panel {
            action.cancel()
        }
        panel?.orderOut(nil)
        // Release the view: it observes every snapshot while it exists.
        panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
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
        panel.becomesKeyOnlyIfNeeded = false
        // Clicking elsewhere closes it, like Spotlight; not while its quit confirmation is up.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard AppModel.shared.services.confirmedAction.pending == nil else {
                    return
                }
                QuickSearchPanel.shared.close()
            }
        }
        return panel
    }
}

/// A borderless panel can't become key unless it says so; the search field needs the keyboard.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}
