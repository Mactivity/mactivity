// Social cards and brand images for the media library (scripts/media.sh).
//   swift scripts/media-cards.swift <brand folder> <library folder>
// The brand folder is docs/brand (logo-1024.png, avatar-512.png, from make brand).
// Cards are 1600 × 900, the size X shows in full: the brand background, a headline, and either a
// screenshot from <library>/screenshots or a single fact. Every figure on a card is one the
// website states too; keep them in step with the latest measurements.
import AppKit
import AVFoundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: media-cards.swift <brand folder> <library folder>\n".utf8))
    exit(64)
}

let brand = URL(fileURLWithPath: arguments[1])
let library = URL(fileURLWithPath: arguments[2])
let shots = library.appendingPathComponent("screenshots")
let clips = library.appendingPathComponent("clips")
for folder in ["cards", "brand", "screenshots"] {
    try FileManager.default.createDirectory(at: library.appendingPathComponent(folder), withIntermediateDirectories: true)
}

// Brand colors, from App/Mactivity.icon's fill (as in scripts/brand-images.swift).
let blue = NSColor(displayP3Red: 0.20, green: 0.52, blue: 1.00, alpha: 1)
let violet = NSColor(displayP3Red: 0.28, green: 0.16, blue: 0.78, alpha: 1)
let night = NSColor(displayP3Red: 0.035, green: 0.04, blue: 0.09, alpha: 1)

guard let icon = NSImage(contentsOf: brand.appendingPathComponent("logo-1024.png")) else {
    FileHandle.standardError.write(Data("No logo-1024.png in \(brand.path); run make brand.\n".utf8))
    exit(1)
}

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

func save(_ data: Data?, _ path: String) {
    guard let data, (try? data.write(to: library.appendingPathComponent(path))) != nil else {
        print("  ✗ \(path)")
        return
    }
    print("  ✓ \(path)")
}

func background(_ rect: CGRect) {
    night.setFill()
    rect.fill()
    // Two soft pools of the icon's colors, like light behind glass.
    for (center, color, radius) in [
        (CGPoint(x: rect.width * 0.18, y: rect.height * 0.85), blue.withAlphaComponent(0.40), rect.width * 0.55),
        (CGPoint(x: rect.width * 0.88, y: rect.height * 0.12), violet.withAlphaComponent(0.46), rect.width * 0.52),
    ] {
        NSGradient(colors: [color, color.withAlphaComponent(0)])?
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
}

func font(_ size: CGFloat, _ weight: NSFont.Weight, rounded: Bool = false) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else {
        return base
    }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

/// Draws centered text whose top edge is at `top`; returns its height.
@discardableResult
func text(_ string: String, _ font: NSFont, _ color: NSColor, in rect: CGRect, top: CGFloat, align: NSTextAlignment = .center) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineHeightMultiple = 1.04
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    let height = ceil(attributed.boundingRect(with: CGSize(width: rect.width, height: 2000), options: [.usesLineFragmentOrigin]).height)
    attributed.draw(with: CGRect(x: rect.minX, y: top - height, width: rect.width, height: height), options: [.usesLineFragmentOrigin])
    return height
}

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

/// The small signature every card carries: the icon and the address.
func signature(_ rect: CGRect) {
    drawIcon(in: CGRect(x: 64, y: 48, width: 52, height: 52), glow: false)
    text("Mactivity", font(28, .bold, rounded: true), .white, in: CGRect(x: 128, y: 0, width: 400, height: 0), top: 92, align: .left)
    text(
        "mactivity.app",
        font(26, .medium),
        NSColor(white: 1, alpha: 0.6),
        in: CGRect(x: rect.width - 464, y: 0, width: 400, height: 0),
        top: 90,
        align: .right
    )
}

/// A screenshot on a card, its bottom running off the edge, with rounded top corners.
func drawShot(_ shot: NSImage, in rect: CGRect, top: CGFloat, width: CGFloat) {
    let height = width * shot.size.height / shot.size.width
    let frame = CGRect(x: (rect.width - width) / 2, y: top - height, width: width, height: height)
    let shape = NSBezierPath(roundedRect: frame, xRadius: 20, yRadius: 20)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.65)
    shadow.shadowBlurRadius = 60
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    night.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    shot.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

// 1. Brand: the icon, an avatar that survives a circle crop, and an X header.
if let data = try? Data(contentsOf: brand.appendingPathComponent("logo-1024.png")) {
    save(data, "brand/icon-1024.png")
}

if let data = try? Data(contentsOf: brand.appendingPathComponent("avatar-512.png")) {
    save(data, "brand/avatar-512.png")
}

// X crops the header differently on phones and computers and puts the avatar over its lower
// left, so everything sits in the middle band, right of center.
save(render(width: 1500, height: 500) { rect in
    background(rect)
    drawIcon(in: CGRect(x: 560, y: 150, width: 200, height: 200), glow: true)
    text("Mactivity", font(84, .bold, rounded: true), .white, in: CGRect(x: 800, y: 0, width: 640, height: 0), top: 345, align: .left)
    text(
        "Your whole Mac, in one light app.",
        font(34, .medium),
        NSColor(white: 1, alpha: 0.8),
        in: CGRect(x: 800, y: 0, width: 640, height: 0),
        top: 240,
        align: .left
    )
    text(
        "mactivity.app",
        font(26, .regular),
        NSColor(white: 1, alpha: 0.55),
        in: CGRect(x: 800, y: 0, width: 640, height: 0),
        top: 188,
        align: .left
    )
}, "brand/x-header-1500x500.png")

/// 2. "Why is my Mac slow?": a still from its clip, near the end, where the answer is showing
/// (the sheet closes about 2.5 s before the clip ends).
let slowClip = clips.appendingPathComponent("why-slow.mp4")
if FileManager.default.fileExists(atPath: slowClip.path) {
    let asset = AVURLAsset(url: slowClip)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        guard let duration = try? await asset.load(.duration) else {
            return
        }
        let at = CMTime(seconds: max(0, duration.seconds - 3.5), preferredTimescale: 600)
        if let frame = try? await generator.image(at: at).image {
            let rep = NSBitmapImageRep(cgImage: frame)
            save(rep.representation(using: .png, properties: [:]), "screenshots/why-slow-dark.png")
        }
    }
    semaphore.wait()
}

/// 3. Feature cards: a headline, a line, and the page itself.
let features: [(shot: String, headline: String, line: String)] = [
    ("why-slow-dark", "Why is my Mac slow?", "Mactivity watches for a few seconds and names the cause in plain words, with the fix."),
    ("overview-dark", "Your whole Mac, at a glance.", "Processor, memory, disk, network, battery and heat, live and in history."),
    ("cpu-dark", "Every app, with what it really costs.", "Helpers and background processes add up under the app that runs them."),
    ("memory-dark", "Memory, app by app.", "Each app's memory with its helpers, and how much room your Mac has left."),
    ("network-dark", "Who's using your connection.", "Data in and out for each app, live and over time."),
    ("battery-dark", "What used your battery.", "Battery use by app while unplugged, the way iPhone breaks it down."),
    ("history-dark", "A year of history, on your Mac.", "What used your Mac yesterday, last week or last spring."),
    ("checkup-dark", "What's worth doing.", "A short list from everything Mactivity knows, each with a button to the fix."),
    (
        "storage-dark",
        "Space, and what you can get back.",
        "A map of your disk and what you could free. Everything goes to the Trash after you confirm."
    ),
    ("projects-dark", "Every dev server, and what it costs.", "Servers grouped by project folder, with the ones you forgot about."),
    ("agents-dark", "What your coding agents did.", "Claude Code, Codex and the rest: time, processor and memory, project by project."),
    ("startup-dark", "What starts with your Mac.", "Login items, launch agents and daemons, by the app that installed them."),
    ("devices-dark", "Everything on your desk.", "Each display, its resolution and scaling, and every port with what's on it."),
    ("alerts-dark", "It tells you when something's off.", "Runaway apps, growing memory, crashes and new startup items, day by day."),
    ("overview-light", "Your whole Mac, at a glance.", "Processor, memory, disk, network, battery and heat, live and in history."),
    ("cpu-light", "Every app, with what it really costs.", "Helpers and background processes add up under the app that runs them."),
    ("battery-light", "What used your battery.", "Battery use by app while unplugged, the way iPhone breaks it down."),
    ("history-light", "A year of history, on your Mac.", "What used your Mac yesterday, last week or last spring."),
]
for feature in features {
    guard let shot = NSImage(contentsOf: shots.appendingPathComponent("\(feature.shot).png")) else {
        print("  – no screenshots/\(feature.shot).png; skipped its card")
        continue
    }
    save(render(width: 1600, height: 900) { rect in
        background(rect)
        let column = CGRect(x: 120, y: 0, width: rect.width - 240, height: 0)
        let headline = text(feature.headline, font(62, .bold, rounded: true), .white, in: column, top: 840)
        text(feature.line, font(28, .regular), NSColor(white: 1, alpha: 0.72), in: column, top: 840 - headline - 14)
        drawShot(shot, in: rect, top: 690, width: 1240)
    }, "cards/feature-\(feature.shot.replacingOccurrences(of: "-dark", with: "")).png")
}

/// 4. Fact cards: one true thing, large.
let facts: [(name: String, headline: String, line: String)] = [
    ("price", "Free.", "No license key, no account, no subscription. The source is open."),
    ("light", "Under 0.2% of one core.", "Mactivity idle in your menu bar, with under 30 MB of memory."),
    ("apps", "About 60 apps,\nnot 1,000 processes.", "Every helper adds up under the app it belongs to."),
    ("history", "A year of history.", "Kept on your Mac, and only there."),
    ("privacy", "Nothing leaves your Mac.", "No analytics and no accounts. Only the update check goes out."),
    ("asks-first", "It asks first.", "Nothing is quit, stopped or moved to the Trash without your OK."),
    (
        "languages",
        "In 11 languages.",
        "English, German, French, Spanish, Italian, Dutch, Portuguese,\nJapanese, Korean, and Chinese (Simplified and Traditional)."
    ),
    ("requirements", "Made for Apple silicon.", "Native on macOS 26 Tahoe and later. Signed and notarized by Apple."),
]
for fact in facts {
    save(render(width: 1600, height: 900) { rect in
        background(rect)
        drawIcon(in: CGRect(x: 740, y: 640, width: 120, height: 120), glow: true)
        let column = CGRect(x: 100, y: 0, width: rect.width - 200, height: 0)
        let headline = text(fact.headline, font(fact.headline.contains("\n") ? 84 : 96, .bold, rounded: true), .white, in: column, top: 580)
        text(fact.line, font(34, .regular), NSColor(white: 1, alpha: 0.72), in: column, top: 580 - headline - 26)
        signature(rect)
    }, "cards/fact-\(fact.name).png")
}
