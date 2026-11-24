// Logo images, for anywhere a logo is needed (docs/brand, used by scripts/media-cards.swift).
//   swift scripts/brand-images.swift <path to Mactivity.app> <output folder>
// The icon is the app's own, drawn by macOS from its Icon Composer asset, so it matches the Dock.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: brand-images.swift <Mactivity.app> <output folder>\n".utf8))
    exit(64)
}

let appPath = arguments[1]
let output = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

// Brand colors, from App/Mactivity.icon's fill.
let blue = NSColor(displayP3Red: 0.20, green: 0.52, blue: 1.00, alpha: 1)
let violet = NSColor(displayP3Red: 0.28, green: 0.16, blue: 0.78, alpha: 1)
let night = NSColor(displayP3Red: 0.035, green: 0.04, blue: 0.09, alpha: 1)

func render(width: Int, height: Int, _ draw: (CGRect) -> Void) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        return nil
    }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func save(_ data: Data?, _ name: String) {
    guard let data else {
        print("✗ \(name)")
        return
    }
    try? data.write(to: output.appendingPathComponent(name))
    print("✓ \(name)")
}

let icon = NSWorkspace.shared.icon(forFile: appPath)
icon.size = NSSize(width: 1024, height: 1024)

func drawIcon(in rect: CGRect, glow: Bool) {
    if glow {
        let shadow = NSShadow()
        shadow.shadowColor = blue.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = rect.width * 0.18
        shadow.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
    icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

func background(_ rect: CGRect) {
    night.setFill()
    rect.fill()
    // Two soft pools of the icon's colors, like light behind glass.
    for (center, color, radius) in [
        (CGPoint(x: rect.width * 0.22, y: rect.height * 0.78), blue.withAlphaComponent(0.42), rect.width * 0.62),
        (CGPoint(x: rect.width * 0.86, y: rect.height * 0.18), violet.withAlphaComponent(0.48), rect.width * 0.58),
    ] {
        let gradient = NSGradient(colors: [color, color.withAlphaComponent(0)])
        gradient?.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
}

func font(_ size: CGFloat, _ weight: NSFont.Weight, rounded: Bool = false) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else {
        return base
    }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

func text(_ string: String, _ font: NSFont, _ color: NSColor, centeredIn width: CGFloat, y: CGFloat, x: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    let size = attributed.boundingRect(with: CGSize(width: width, height: 1000), options: [.usesLineFragmentOrigin]).size
    attributed.draw(with: CGRect(x: x, y: y, width: width, height: ceil(size.height)), options: [.usesLineFragmentOrigin])
}

// 1. Logos: the icon alone on transparency, for anywhere a square is wanted.
for size in [1024, 512, 256] {
    save(render(width: size, height: size) { rect in
        drawIcon(in: rect.insetBy(dx: CGFloat(size) * 0.02, dy: CGFloat(size) * 0.02), glow: false)
    }, "logo-\(size).png")
}

// 1b. An avatar, for places that crop to a circle: the icon's own background fills the
// whole square, so the circle shows no edge of the icon's rounded corners.
if let probe = NSBitmapImageRep(data: icon.tiffRepresentation ?? Data()) {
    // macOS pads an icon's rounded square inside its canvas: down from the top center to the
    // first opaque pixel is the square's edge, and a little further in is its flat background.
    let x = probe.pixelsWide / 2
    let edge = (0 ..< probe.pixelsHigh).first { (probe.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.99 } ?? 0
    let fill = probe.colorAt(x: x, y: edge + probe.pixelsHigh / 30) ?? night
    // Scaled so the rounded square overflows the canvas and only its flat middle shows.
    let overflow = Double(edge) / Double(probe.pixelsHigh) + 0.04
    save(render(width: 512, height: 512) { rect in
        fill.setFill()
        rect.fill()
        let grow = rect.width * overflow / (1 - 2 * overflow)
        drawIcon(in: rect.insetBy(dx: -grow, dy: -grow), glow: false)
    }, "avatar-512.png")
}
