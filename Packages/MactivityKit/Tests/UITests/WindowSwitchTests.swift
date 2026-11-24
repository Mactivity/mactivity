import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Switching tabs must leave the window its size (D-239): going from Battery to Network grew the
/// window to fill the screen, in a running copy, though each tab on its own kept it.
@MainActor
@Suite("Switching tabs keeps the window's size")
struct WindowSwitchTests {
    @Test("From each tab to each metric tab", arguments: [SidebarItem.battery, .network, .cpu, .overview, .disk])
    func switching(from start: SidebarItem) async throws {
        _ = NSApplication.shared
        let services = AppServices.preview()
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 5 {
            await services.metrics.apply(source.next())
        }
        let size = Tokens.Layout.mainWindowDefault
        // Hosted as the app's window is: a controller that sets the window's minimum size.
        let controller = NSHostingController(rootView: MainWindowView(services: services, isSimulated: .constant(true))
            .frame(minWidth: Tokens.Layout.mainWindowMinimum.width, minHeight: Tokens.Layout.mainWindowMinimum.height))
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        let hosting = controller.view
        for item in [start, .network, .battery, .network, .cpu, .network] {
            services.navigation.selection = item
            for _ in 0 ..< (item == .network ? 30 : 8) {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            let content = window.contentView?.frame.size ?? .zero
            #expect(content.width <= size.width + 1, "\(start.rawValue) → \(item.rawValue): \(content.width) pt wide")
            #expect(content.height <= size.height + 1, "\(start.rawValue) → \(item.rawValue): \(content.height) pt tall")
        }
        window.close()
    }
}
