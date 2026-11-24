import AppKit
import Core
import SwiftUI
import Testing
@testable import UI

/// Out of the ordinary today (D-198), from made-up findings. Renders into `MACTIVITY_SNAPSHOT_DIR`.
@MainActor
@Suite("Unusual renders", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct UnusualRenderTests {
    private func app(_ name: String, id: String) -> AppIdentity {
        AppIdentity(id: id, name: name, bundleID: id, iconKey: "other", kind: .app)
    }

    @Test("The Overview card")
    func card() throws {
        let found = [
            UnusualUsage(app: app("Safari", id: "com.apple.Safari"), metric: .memory, today: 5.9e9, usual: 1.4e9),
            UnusualUsage(app: app("Docker", id: "com.docker.docker"), metric: .cpu, today: 18, usual: 0.1),
            UnusualUsage(app: app("Claude Code", id: "com.anthropic.claude-code"), metric: .energy, today: 1500, usual: 420),
        ]
        try write(UnusualCard(services: .preview(), sample: found), name: "unusual", width: 760)
    }

    @Test("Today and its usual day, on an app's history page (D-201)")
    func usualRow() throws {
        let safari = app("Safari", id: "com.apple.Safari")
        let usual = [
            UnusualUsage(app: safari, metric: .cpu, today: 6.2, usual: 4.1),
            UnusualUsage(app: safari, metric: .memory, today: 5.9e9, usual: 1.4e9),
            UnusualUsage(app: safari, metric: .energy, today: 380, usual: 310),
        ]
        try write(UsualDayRow(usual: usual), name: "usual-day", width: 740)
    }

    private func write(_ content: some View, name: String, width: CGFloat) throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
        for scheme in [ColorScheme.light, .dark] {
            let view = content
                .padding(Tokens.Spacing.l)
                .frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
