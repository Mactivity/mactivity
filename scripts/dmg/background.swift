// Draws the DMG window's background: a quiet gradient, an arrow from the app to Applications,
// and one line of instruction. Run by scripts/dmg.sh; writes background.png and background@2x.png.
// Layout matches the icon positions in scripts/dmg.sh (window 660 × 400 pt, icons at x 170 and 490).
import AppKit

let size = CGSize(width: 660, height: 400)
let output = CommandLine.arguments.dropFirst().first ?? "."

func render(scale: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Background: a soft light gradient, readable under Finder's dark and light icon labels.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.98, alpha: 1),
    ])
    gradient?.draw(in: CGRect(origin: .zero, size: size), angle: -90)

    // Arrow from the app (x 170) toward Applications (x 490), at the icons' height (y 190 from the top).
    let y = size.height - 190
    let accent = NSColor(calibratedRed: 0.36, green: 0.58, blue: 0.97, alpha: 1)
    accent.setStroke()
    accent.setFill()
    let shaft = NSBezierPath()
    shaft.move(to: CGPoint(x: 262, y: y))
    shaft.line(to: CGPoint(x: 386, y: y))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: 400, y: y))
    head.line(to: CGPoint(x: 380, y: y + 13))
    head.line(to: CGPoint(x: 380, y: y - 13))
    head.close()
    head.fill()

    // Instruction under the icons.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let text = NSAttributedString(string: "Drag Mactivity to Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    text.draw(in: CGRect(x: 0, y: 70, width: size.width, height: 22))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    guard let data = render(scale: scale) else { fatalError("Couldn't render \(name)") }
    try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}
