import AppKit
import SwiftUI
import Testing
@testable import UI

/// Clean Keyboard's panel (D-203). Renders into `MACTIVITY_SNAPSHOT_DIR`.
@MainActor
@Suite("Keyboard lock renders", .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct KeyboardLockRenderTests {
    @Test("The locked panel")
    func panel() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
        for scheme in [ColorScheme.light, .dark] {
            let view = KeyboardLockView(endsAt: Date().addingTimeInterval(272)) {}
                .background(.regularMaterial, in: .rect(cornerRadius: 24))
                .padding(Tokens.Spacing.l)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("keyboard-lock-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
