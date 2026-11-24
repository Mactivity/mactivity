import AppKit
import Core
import Projects
import Simulated
import SwiftUI
import Testing
@testable import UI

/// Renders the process inspector and an app's connections to PNG in light and dark for
/// docs/screenshots/E12. Runs only when `MACTIVITY_SNAPSHOT_DIR` is set.
///
/// These views use `Table` and `TabView`, which are AppKit underneath and which `ImageRenderer`
/// can't draw, so they're hosted in an off-screen window and captured with `cacheDisplay`.
@MainActor
@Suite("Inspector renders", .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct InspectorRenderTests {
    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    private let source = SimulatedProcessDetailsSource()

    private func write(_ view: some View, name: String, size: CGSize) async throws {
        _ = NSApplication.shared
        for dark in [false, true] {
            let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = hosting
            window.orderFrontRegardless()
            // Let `.task` load the simulated details, then let tables lay out their rows.
            for _ in 0 ..< 6 {
                try await Task.sleep(for: .milliseconds(100))
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            let png = try #require(try capture(hosting))
            window.orderOut(nil)
            try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    /// Draws the view's layer tree at 2x. `cacheDisplay` misses SwiftUI's text layers.
    private func capture(_ view: NSView) throws -> Data? {
        let scale: CGFloat = 2
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        let layer = try #require(view.layer)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // The hosting view's layers are top-down; the bitmap context is bottom-up.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        var background = CGColor(gray: 1, alpha: 1)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: view.bounds.size))
        layer.render(in: context)
        let image = try #require(context.makeImage())
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    @Test("Inspector: overview, open files, and network of a dev server")
    func devServer() async throws {
        let services = AppServices.preview()
        // The overview is taller than the ideal size so the parent chain is in the picture.
        let tall = CGSize(width: InspectorLayout.idealSize.width, height: 1000)
        for (tab, name, size) in [
            (InspectorTab.overview, "overview", tall), (.files, "files", InspectorLayout.idealSize),
            (.network, "network", InspectorLayout.idealSize),
        ] {
            try await write(
                ProcessInspectorView(pid: SimulatedDevServers.storefrontPID, source: source, services: services, tab: tab).onDone {},
                name: "inspector-\(name)",
                size: size
            )
        }
    }

    @Test("Inspector: launchd without the helper")
    func unreadable() async throws {
        try await write(
            ProcessInspectorView(pid: 1, source: source, services: AppServices.preview(), tab: .network).onDone {},
            name: "inspector-unreadable",
            size: InspectorLayout.minimumSize
        )
    }

    @Test("Connections per app: Safari")
    func appConnections() async throws {
        try await write(
            AppConnectionsView(appName: "Safari", pids: [400, 401, 402, 403], source: source),
            name: "app-connections",
            size: InspectorLayout.connectionsIdealSize
        )
    }
}
