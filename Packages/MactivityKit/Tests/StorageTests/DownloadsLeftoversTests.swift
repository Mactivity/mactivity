import Foundation
@testable import Storage
import Testing

@Suite("Installers and archives in Downloads (D-118)")
struct DownloadsLeftoversTests {
    @Test("Disk images, installers, archives and unfinished downloads; never documents or apps")
    func kinds() {
        #expect(DownloadsLeftovers.kind(name: "Xcode_27.xip") == .archive)
        #expect(DownloadsLeftovers.kind(name: "Zoom.PKG") == .installer)
        #expect(DownloadsLeftovers.kind(name: "Docker.dmg") == .diskImage)
        #expect(DownloadsLeftovers.kind(name: "movie.mp4.crdownload") == .unfinished)
        #expect(DownloadsLeftovers.kind(name: "Tax return.pdf") == nil)
        #expect(DownloadsLeftovers.kind(name: "Some App.app") == nil)
        #expect(DownloadsLeftovers.kind(name: "notes") == nil)
    }

    @Test("Ticked when added over 30 days ago, or unfinished for over a day")
    func ticked() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func item(_ kind: DownloadLeftover.Kind, days: Double) -> DownloadLeftover {
            DownloadLeftover(path: "/d/x", kind: kind, size: 1, added: now.addingTimeInterval(-days * 86400))
        }
        #expect(DownloadsLeftovers.startsTicked(item(.diskImage, days: 45), now: now))
        #expect(!DownloadsLeftovers.startsTicked(item(.diskImage, days: 3), now: now))
        #expect(DownloadsLeftovers.startsTicked(item(.unfinished, days: 2), now: now))
        #expect(!DownloadsLeftovers.startsTicked(item(.unfinished, days: 0.1), now: now))
    }

    @Test("A Downloads folder: top-level leftovers only, largest first")
    func scan() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 90000).write(to: folder.appendingPathComponent("Big.dmg"))
        try Data(count: 1000).write(to: folder.appendingPathComponent("tool.zip"))
        try Data(count: 5000).write(to: folder.appendingPathComponent("Report.pdf"))
        try Data(count: 5000).write(to: folder.appendingPathComponent("Sub/Nested.dmg"))
        let found = try DownloadsLeftovers.scan(folder)
        #expect(found.map(\.name) == ["Big.dmg", "tool.zip"])
        #expect(try DownloadsLeftovers.scan(folder.appendingPathComponent("missing")).isEmpty)
    }
}
