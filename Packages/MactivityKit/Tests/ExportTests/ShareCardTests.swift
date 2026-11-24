import AppKit
import Core
@testable import Export
import Foundation
import Simulated
import SwiftUI
import Testing

// MARK: - Helpers

private func pixelSize(_ png: Data) throws -> (width: Int, height: Int) {
    let bitmap = try #require(NSBitmapImageRep(data: png))
    return (bitmap.pixelsWide, bitmap.pixelsHigh)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ExportTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Files

@Suite("ShareCard files")
struct ShareCardFileTests {
    /// 2026-09-25 19:42:10 UTC.
    private let date = Date(timeIntervalSince1970: 1_790_365_330)

    @Test("File name uses the given time zone")
    func fileName() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(ShareCard.fileName(for: date, timeZone: utc) == "Mactivity 2026-09-25 at 19.42.10.png")
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(ShareCard.fileName(for: date, timeZone: tokyo) == "Mactivity 2026-09-26 at 04.42.10.png")
    }

    @Test("Save numbers collisions instead of overwriting")
    func saveCollisions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = ShareCard.fileName(for: date)
        let base = (name as NSString).deletingPathExtension

        let first = try ShareCard.save(Data([1]), at: date, in: directory)
        let second = try ShareCard.save(Data([2]), at: date, in: directory)
        let third = try ShareCard.save(Data([3]), at: date, in: directory)

        #expect(first.lastPathComponent == name)
        #expect(second.lastPathComponent == "\(base) 2.png")
        #expect(third.lastPathComponent == "\(base) 3.png")
        #expect(try Data(contentsOf: first) == Data([1]))
        #expect(try Data(contentsOf: second) == Data([2]))
        #expect(try Data(contentsOf: third) == Data([3]))
    }

    @Test("Save into a missing folder throws")
    func saveMissingFolder() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ExportTests-missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try ShareCard.save(Data([1]), at: date, in: missing)
        }
    }
}

// MARK: - Rendering

@MainActor
@Suite("Rendering")
struct RenderingTests {
    @Test("A width-only render takes the view's own height")
    func fittedHeight() throws {
        let view = VStack(spacing: 0) {
            Color.red.frame(height: 30)
            Color.blue.frame(height: 50)
        }
        let png = try #require(ImageExport.pngData(of: view, width: 200, scale: 2, colorScheme: .light))
        let size = try pixelSize(png)
        #expect(size.width == 400)
        #expect(size.height == 160)
    }

    @Test("Any view renders at size × scale", arguments: [(CGFloat(1), 320, 200), (2, 640, 400), (3, 960, 600)])
    func imageExportSize(scale: CGFloat, width: Int, height: Int) throws {
        let view = Color.blue.overlay(Text("Dashboard"))
        let png = try #require(ImageExport.pngData(of: view, size: CGSize(width: 320, height: 200), scale: scale, colorScheme: .light))
        let size = try pixelSize(png)
        #expect(size.width == width)
        #expect(size.height == height)
    }

    /// An app icon makes ImageRenderer produce a PQ (HDR) image; the export must bring it back to SDR.
    @Test("PNGs are 8-bit sRGB and white stays white, even with an app icon")
    func standardDynamicRange() throws {
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app")
        let view = ZStack(alignment: .bottomTrailing) {
            Color.white
            Image(nsImage: icon).resizable().frame(width: 4, height: 4)
        }
        let png = try #require(ImageExport.pngData(of: view, size: CGSize(width: 8, height: 8), colorScheme: .light))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.bitsPerSample == 8)
        let pixel = try #require(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        #expect(pixel.redComponent > 0.99)
        #expect(pixel.greenComponent > 0.99)
        #expect(pixel.blueComponent > 0.99)
    }

    @Test("Copy puts the PNG on the pasteboard")
    func copyToPasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.mactivity.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let png = try #require(ImageExport.pngData(of: Color.red, size: CGSize(width: 10, height: 10), colorScheme: .light))
        #expect(ImageExport.copy(png, to: pasteboard))
        #expect(pasteboard.data(forType: .png) == png)
        #expect(!ImageExport.copy(Data([0, 1, 2]), to: pasteboard))
    }
}

// MARK: - Mac model

@Suite("MacModel")
struct MacModelTests {
    @Test("Product names lose the size and chip", arguments: [
        ("MacBook Pro (14-inch, M5 Pro)", "MacBook Pro"),
        ("Mac mini (2024)", "Mac mini"),
        ("iMac", "iMac"),
        ("  Mac Studio  ", "Mac Studio"),
    ])
    func marketingName(productName: String, expected: String) {
        #expect(MacModel.marketingName(fromProductName: productName) == expected)
    }

    @Test("Empty product names are rejected")
    func emptyProductName() {
        #expect(MacModel.marketingName(fromProductName: "") == nil)
        #expect(MacModel.marketingName(fromProductName: " (M5)") == nil)
    }

    @Test("Model identifiers map to families", arguments: [
        ("MacBookPro18,3", "MacBook Pro"),
        ("MacBookAir10,1", "MacBook Air"),
        ("Macmini9,1", "Mac mini"),
        ("iMac21,1", "iMac"),
        ("MacPro7,1", "Mac Pro"),
    ])
    func family(identifier: String, expected: String) {
        #expect(MacModel.family(fromModelIdentifier: identifier) == expected)
    }

    @Test("New-style identifiers name no family")
    func newIdentifiers() {
        #expect(MacModel.family(fromModelIdentifier: "Mac17,9") == nil)
        #expect(MacModel.family(fromModelIdentifier: "") == nil)
    }

    @Test("Live: this Mac has a name and a chip")
    func live() {
        let name = MacModel.name()
        let chip = MacModel.chip()
        #expect(!name.isEmpty)
        #expect(!chip.isEmpty)
        #expect(!name.contains("("))
    }
}
