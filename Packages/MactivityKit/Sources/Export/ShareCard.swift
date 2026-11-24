import AppKit
import Foundation
import os
import SwiftUI
import UniformTypeIdentifiers

enum Log {
    static let export = Logger(subsystem: "app.mactivity.export", category: "export")
}

public enum ShareCardError: Error, Equatable {
    /// The user's Downloads folder couldn't be located.
    case noDownloadsDirectory
    /// Every candidate name up to the limit was taken.
    case noFreeName
}

/// The shared image as a file: name and save (spec 5.9, 6.15).
public enum ShareCard {
    /// Gives up after "… 999.png"; something is wrong with the folder by then.
    static let maxNameAttempts = 999

    /// "Mactivity 2026-09-25 at 19.42.10.png", in the given time zone. Same shape as a macOS
    /// screenshot's name, so the files sort by time. The words are localized, the date and time aren't.
    public static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH.mm.ss"
        let time = formatter.string(from: date)
        let name = String(
            localized: "Mactivity \(day) at \(time)", bundle: .strings,
            comment: "Share card file name, shaped like a macOS screenshot's: a date (2026-09-25), then a time (19.42.10)."
        )
        return "\(name).png"
    }

    /// Writes into `directory` (default: the user's Downloads). Adds " 2", " 3"… if the name is
    /// taken; never overwrites. Returns the file's URL.
    public static func save(_ png: Data, at date: Date, in directory: URL? = nil) throws -> URL {
        let folder = try directory ?? downloadsDirectory()
        let base = (fileName(for: date) as NSString).deletingPathExtension
        let pathExtension = UTType.png.preferredFilenameExtension ?? "png"
        for attempt in 1 ... maxNameAttempts {
            let name = attempt == 1 ? base : "\(base) \(attempt)"
            let url = folder.appendingPathComponent(name).appendingPathExtension(pathExtension)
            do {
                try png.write(to: url, options: .withoutOverwriting)
                Log.export.info("Saved share card to \(url.path, privacy: .private)")
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        Log.export.error("No free share card name in \(folder.path, privacy: .private)")
        throw ShareCardError.noFreeName
    }

    private static func downloadsDirectory() throws -> URL {
        guard let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw ShareCardError.noDownloadsDirectory
        }
        return url
    }
}

/// Views to images: the Overview image that Share saves, copies and sends (spec 5.9).
public enum ImageExport {
    /// Renders a view `width` points wide at its own height, for layouts whose height depends on
    /// their content (text size, the language). The image is `width × scale` pixels wide.
    @MainActor public static func pngData(
        of view: some View,
        width: CGFloat,
        scale: CGFloat = 2,
        colorScheme: ColorScheme
    ) -> Data? {
        let content = view
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = scale
        return encode(renderer)
    }

    /// Renders any SwiftUI view at a fixed size to PNG. The image is `size × scale` pixels.
    @MainActor public static func pngData(
        of view: some View,
        size: CGSize,
        scale: CGFloat = 2,
        colorScheme: ColorScheme
    ) -> Data? {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        return encode(renderer)
    }

    /// The renderer's image as 8-bit sRGB PNG, sized in points so viewers show it at @`scale`.
    @MainActor private static func encode(_ renderer: ImageRenderer<some View>) -> Data? {
        renderer.colorMode = .nonLinear
        guard let rendered = renderer.cgImage, let image = standardRGB(rendered) else {
            Log.export.error("ImageRenderer produced no image")
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = CGSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            Log.export.error("PNG encoding failed")
            return nil
        }
        return png
    }

    /// Redraws `image` as 8-bit sRGB.
    ///
    /// On macOS 26 and later, app icons from `NSWorkspace` are Icon Services reps that make
    /// ImageRenderer return a 16-bit BT.2100 PQ image even with `colorMode = .nonLinear`. Viewers
    /// and social sites show that grey and washed out, and a plain draw into sRGB tone-maps white
    /// down to about 88%. Reference-white tone mapping keeps SDR white at white.
    static func standardRGB(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if !context.draw(image, in: rect, by: .referenceWhiteBased, options: nil) {
            Log.export.notice("Reference-white tone mapping failed; drawing with the default")
            context.draw(image, in: rect)
        }
        return context.makeImage()
    }

    /// "Copy dashboard": puts the image on the general pasteboard as PNG. Returns false on failure.
    @MainActor @discardableResult public static func copyToPasteboard(_ png: Data) -> Bool {
        copy(png, to: .general)
    }

    /// Replaces the pasteboard's contents with `png`. Tests pass a private pasteboard.
    @MainActor static func copy(_ png: Data, to pasteboard: NSPasteboard) -> Bool {
        guard NSBitmapImageRep(data: png) != nil else {
            Log.export.error("Refusing to copy data that isn't an image")
            return false
        }
        pasteboard.clearContents()
        let copied = pasteboard.setData(png, forType: .png)
        if !copied {
            Log.export.error("Pasteboard rejected the PNG")
        }
        return copied
    }
}
