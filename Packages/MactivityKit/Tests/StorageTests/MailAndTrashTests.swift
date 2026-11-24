import Foundation
@testable import Storage
import Testing

@Suite("Mail downloads and the Trash (D-119)")
struct MailAndTrashTests {
    @Test("Mail's saved attachments, in their folders, largest first; no folder is none")
    func mail() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (inner, name, bytes) in [("A1B2", "Invoice.pdf", 20000), ("C3D4", "Photos.zip", 90000)] {
            let dir = folder.appendingPathComponent(inner)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(count: bytes).write(to: dir.appendingPathComponent(name))
        }
        #expect(try MailDownloads.scan(folder).map(\.name) == ["Photos.zip", "Invoice.pdf"])
        #expect(try MailDownloads.scan(folder.appendingPathComponent("none")).isEmpty)
    }

    @Test("The Trash's size, everything in it")
    func trash() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Old App.app/Contents"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 50000).write(to: folder.appendingPathComponent("Old App.app/Contents/binary"))
        try Data(count: 10000).write(to: folder.appendingPathComponent("movie.mov"))
        #expect((TrashFolder.size(folder) ?? 0) >= 60000)
        #expect(TrashFolder.size(folder.appendingPathComponent("missing")) == nil)
    }
}
