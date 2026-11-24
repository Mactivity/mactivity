import Foundation
@testable import Storage
import Testing

@Suite("Messages attachments (D-116)")
struct MessagesAttachmentsTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func attachment(_ name: String, mb: UInt64, daysOld: Double) -> MessageAttachment {
        MessageAttachment(
            path: "/a/\(name)", size: mb * 1_000_000, date: now.addingTimeInterval(-daysOld * 86400),
            kind: MessagesAttachments.kind(pathExtension: (name as NSString).pathExtension)
        )
    }

    @Test("Kinds by extension, whatever the case")
    func kinds() {
        #expect(MessagesAttachments.kind(pathExtension: "HEIC") == .photo)
        #expect(MessagesAttachments.kind(pathExtension: "jpeg") == .photo)
        #expect(MessagesAttachments.kind(pathExtension: "MOV") == .video)
        #expect(MessagesAttachments.kind(pathExtension: "mp4") == .video)
        #expect(MessagesAttachments.kind(pathExtension: "caf") == .audio)
        #expect(MessagesAttachments.kind(pathExtension: "pdf") == .document)
        #expect(MessagesAttachments.kind(pathExtension: "pluginPayloadAttachment") == .other)
    }

    @Test("The filter picks by age, kind and size")
    func filter() {
        let all = [
            attachment("old.mov", mb: 300, daysOld: 500), attachment("old.heic", mb: 3, daysOld: 400),
            attachment("new.mov", mb: 200, daysOld: 10), attachment("voice.caf", mb: 1, daysOld: 800),
        ]
        let year = MessagesAttachments.matching(all, MessageAttachmentFilter(olderThanDays: 365), now: now)
        #expect(Set(year.map(\.name)) == ["old.mov", "old.heic", "voice.caf"])
        let videos = MessagesAttachments.matching(all, MessageAttachmentFilter(olderThanDays: nil, kind: .video), now: now)
        #expect(Set(videos.map(\.name)) == ["old.mov", "new.mov"])
        let large = MessagesAttachments.matching(
            all, MessageAttachmentFilter(olderThanDays: 365, minimumBytes: 10_000_000), now: now
        )
        #expect(large.map(\.name) == ["old.mov"])
    }

    @Test("Totals per kind")
    func totals() {
        let totals = MessagesAttachments.totals([
            attachment("a.mov", mb: 300, daysOld: 1), attachment("b.mov", mb: 100, daysOld: 1), attachment("c.heic", mb: 3, daysOld: 1),
        ])
        #expect(totals[.video]?.count == 2)
        #expect(totals[.video]?.bytes == 400_000_000)
        #expect(totals[.photo]?.count == 1)
    }

    @Test("A real folder: files found largest first, missing folder reported")
    func scan() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inner = folder.appendingPathComponent("ab/12/GUID", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 50000).write(to: inner.appendingPathComponent("IMG_1.HEIC"))
        try Data(count: 10).write(to: inner.appendingPathComponent("note.txt"))
        let found = try MessagesAttachments.scan(folder)
        #expect(found.map(\.name) == ["IMG_1.HEIC", "note.txt"])
        #expect(found.first?.kind == .photo)
        #expect(throws: MessagesAttachmentsError.notFound) {
            try MessagesAttachments.scan(folder.appendingPathComponent("missing"))
        }
    }
}
