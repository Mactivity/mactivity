import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Renders the whole main window (title bar, toolbar, sidebar, detail) at the default size for
/// every sidebar item, dark, into `MACTIVITY_SNAPSHOT_DIR` (`make snapshots M=window
/// FILTER=WindowRenderTests`). For layout bugs that only show in a real window, like a page taller
/// than the window pushing the sidebar up under the title bar (D-055, D-072).
@MainActor
@Suite("Window renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct WindowRenderTests {
    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    init() {
        // Doubled strings with MACTIVITY_PSEUDO_LOCALIZATION=1, to see what long languages widen.
        _ = PseudoLocalization.isOn
    }

    @Test("Every tab in a default-size window", arguments: SidebarItem.allCases)
    func tab(_ item: SidebarItem) async throws {
        try await render(item, size: Tokens.Layout.mainWindowDefault, suffix: "")
    }

    /// The short and the minimum window, where pages have to give up height (D-172, D-174).
    @Test("Every tab in a short and a minimum-size window", arguments: SidebarItem.allCases)
    func smallWindows(_ item: SidebarItem) async throws {
        try await render(item, size: CGSize(width: 1000, height: 640), suffix: "-short")
        try await render(item, size: Tokens.Layout.mainWindowMinimum, suffix: "-minimum")
    }

    /// Increase Contrast, dark and light: the high-contrast appearances it switches to (CLAUDE.md rule 8).
    @Test("Every tab with Increase Contrast", arguments: SidebarItem.allCases)
    func increasedContrast(_ item: SidebarItem) async throws {
        try await render(item, size: Tokens.Layout.mainWindowDefault, suffix: "-contrast", appearance: .accessibilityHighContrastDarkAqua)
        try await render(item, size: Tokens.Layout.mainWindowDefault, suffix: "-contrast-light", appearance: .accessibilityHighContrastAqua)
    }

    private func render(
        _ item: SidebarItem, size: CGSize, suffix: String, appearance: NSAppearance.Name = .darkAqua
    ) async throws {
        _ = NSApplication.shared
        let services = AppServices.preview()
        let source = SimulatedSnapshotSource()
        for _ in 0 ..< 30 {
            await services.metrics.apply(source.next())
        }
        services.navigation.selection = item
        let hosting = NSHostingView(rootView: MainWindowView(services: services, isSimulated: .constant(true)))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(1))
        hosting.layoutSubtreeIfNeeded()
        let frame = window.contentView?.bounds ?? .zero
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: frame))
        hosting.cacheDisplay(in: frame, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(item.rawValue)\(suffix)\(appearance == .darkAqua ? "-dark" : "").png"))
        window.close()
    }
}
