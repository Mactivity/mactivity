import AppKit
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Renders every Settings tab, and measures its height: the window takes its tab's height, so a
/// tab taller than a small screen leaves its bottom out of reach (D-175). Renders run only with
/// `MACTIVITY_SNAPSHOT_DIR`; the height check always runs.
@MainActor
@Suite("Settings", .serialized)
struct SettingsFitTests {
    /// About the usable height of a 13-inch MacBook Air's screen under the menu bar and title bar.
    static let smallScreenHeight: CGFloat = 860

    init() {
        _ = PseudoLocalization.isOn
        _ = LargerFigures.isOn
    }

    @Test("Every Settings tab fits a small screen", arguments: SettingsTab.allCases)
    func fits(_ tab: SettingsTab) async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: PreferenceKey.settingsTab)
        defer { defaults.set(saved, forKey: PreferenceKey.settingsTab) }
        defaults.set(tab.rawValue, forKey: PreferenceKey.settingsTab)
        _ = NSApplication.shared
        let services = AppServices.preview()
        await services.metrics.apply(SimulatedSnapshotSource().next())
        let hosting = NSHostingView(rootView: SettingsView(services: services))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: Tokens.Layout.settingsWidth, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        for _ in 0 ..< 8 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let size = hosting.fittingSize
        #expect(size.height <= Self.smallScreenHeight, "Settings → \(tab.rawValue) is \(size.height) pt tall")
        #expect(size.width <= Tokens.Layout.settingsWidth + 1, "Settings → \(tab.rawValue) is \(size.width) pt wide")
        if let directory = ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] {
            window.setContentSize(size)
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-\(tab.rawValue).png"))
        }
        window.close()
    }
}
