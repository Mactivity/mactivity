// The website demo's app icons (D-166), as macOS draws them, at 64 px (2× a 32 pt row).
//   swift scripts/demo-app-icons.swift website/icons/apps
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "website/icons/apps")
let apps: [(slug: String, path: String)] = [
    ("xcode", "/Applications/Xcode.app"),
    ("safari", "/Applications/Safari.app"),
    ("terminal", "/System/Applications/Utilities/Terminal.app"),
    ("code", "/Applications/Visual Studio Code.app"),
    ("music", "/System/Applications/Music.app"),
    ("finder", "/System/Library/CoreServices/Finder.app"),
    ("facetime", "/System/Applications/FaceTime.app"),
    ("podcasts", "/System/Applications/Podcasts.app"),
]

func png(size: Int, _ draw: (CGRect) -> Void) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        return nil
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for app in apps where FileManager.default.fileExists(atPath: app.path) {
    let icon = NSWorkspace.shared.icon(forFile: app.path)
    let data = png(size: 64) { icon.draw(in: $0, from: .zero, operation: .sourceOver, fraction: 1) }
    try data?.write(to: output.appendingPathComponent("\(app.slug).png"))
    print("✓ \(app.slug)")
}

// macOS's own processes: the Apple logo, as the app shows it (SF Symbol "applelogo").
if let symbol = NSImage(systemSymbolName: "applelogo", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 40, weight: .regular)) {
    let data = png(size: 64) { rect in
        NSColor(white: 0.55, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14).fill()
        let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        let side: CGFloat = 34
        tinted.draw(in: CGRect(
            x: (64 - side * symbol.size.width / symbol.size.height) / 2,
            y: 15,
            width: side * symbol.size.width / symbol.size.height,
            height: side
        ))
    }
    try data?.write(to: output.appendingPathComponent("macos.png"))
    print("✓ macos")
}
