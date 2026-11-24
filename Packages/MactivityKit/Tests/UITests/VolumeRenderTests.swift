import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Renders the Volume tab and the menu bar window's per-app volume section with simulated data, light and dark,
/// into `MACTIVITY_SNAPSHOT_DIR` (`make snapshots M=E15`). Sliders, toggles, and menus are AppKit underneath,
/// which `ImageRenderer` can't draw, so this hosts the views in an offscreen window.
@MainActor
@Suite("Volume renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct VolumeRenderTests {
    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    /// Simulated services with a snapshot in hand, so rows show app names and icons.
    private func services() async -> AppServices {
        let services = AppServices.preview()
        await services.metrics.apply(SimulatedSnapshotSource().next())
        return services
    }

    private func loadedModel(_ services: AppServices) async -> PerAppAudioModel {
        let model = PerAppAudioModel()
        await model.refresh(services.audio)
        return model
    }

    /// Lets AppKit lay out and draw. Synchronous: `RunLoop.run` isn't available from async code.
    private static func spinRunLoop(seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Async so `.task`s in the view (the menu bar window's poll) get to run before the capture.
    private func write(_ view: some View, name: String, size: CGSize) async throws {
        _ = NSApplication.shared
        for dark in [false, true] {
            let framed = view
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: framed)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            Self.spinRunLoop(seconds: 0.3)
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            window.close()
        }
    }

    @Test("Volume tab: untouched, muted, and routed apps")
    func volumeTab() async throws {
        let services = await services()
        let model = await loadedModel(services)
        try await write(VolumeView(services: services, model: model), name: "volume-tab", size: CGSize(width: 900, height: 360))
    }

    @Test("Menu bar window's per-app volume section")
    func menuBarSection() async throws {
        let services = await services()
        let model = await loadedModel(services)
        let section = CompactVolumeSection(model: model, metrics: services.metrics)
            .padding(Tokens.Spacing.s)
            .frame(width: Tokens.Layout.menuBarWindowWidth)
        try await write(section, name: "menubar-volume-section", size: CGSize(width: Tokens.Layout.menuBarWindowWidth, height: 260))
    }

    @Test("The whole menu bar window with the flag on")
    func menuBarWindow() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: PreferenceKey.perAppVolume)
        defaults.set(true, forKey: PreferenceKey.perAppVolume)
        defer { defaults.set(previous, forKey: PreferenceKey.perAppVolume) }
        let services = await services()
        let window = MenuBarContent(services: services, isSimulated: .constant(true), mainWindowID: "main")
        try await write(window, name: "menubar-window", size: CGSize(width: Tokens.Layout.menuBarWindowWidth, height: 760))
    }
}
