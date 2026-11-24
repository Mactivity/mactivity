import Darwin
import Foundation
@testable import Storage
import Testing

@Suite("Screenshots and screen recordings (D-122)")
struct ScreenCapturesTests {
    private func mark(_ url: URL) {
        let value: [UInt8] = Array("bplist00\u{09}".utf8)
        _ = value.withUnsafeBytes { setxattr(url.path, ScreenCaptures.attribute, $0.baseAddress, $0.count, 0, 0) }
    }

    @Test("Captures by macOS's attribute, whatever their names; other files left alone")
    func scan() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shot = folder.appendingPathComponent("Bildschirmfoto 2026-09-28 um 17.11.52.png")
        let recording = folder.appendingPathComponent("Screen Recording 2026-09-01.mov")
        let photo = folder.appendingPathComponent("Holiday.png")
        try Data(count: 3000).write(to: shot)
        try Data(count: 90000).write(to: recording)
        try Data(count: 5000).write(to: photo)
        mark(shot)
        mark(recording)
        let found = try ScreenCaptures.scan([folder, folder.appendingPathComponent("missing")])
        #expect(found.map { ($0.path as NSString).lastPathComponent } == [
            "Screen Recording 2026-09-01.mov",
            "Bildschirmfoto 2026-09-28 um 17.11.52.png",
        ])
        #expect(found.map(\.isRecording) == [true, false])
    }

    @Test("The screenshot folder from the setting, plus the Desktop when it's elsewhere")
    func folders() {
        #expect(ScreenCaptures.folders(home: "/Users/me", setting: nil).map(\.path) == ["/Users/me/Desktop"])
        #expect(ScreenCaptures.folders(home: "/Users/me", setting: "/Users/me/Desktop").map(\.path) == ["/Users/me/Desktop"])
        #expect(ScreenCaptures.folders(home: "/Users/me", setting: "/Users/me/Pictures/Shots").map(\.path)
            == ["/Users/me/Pictures/Shots", "/Users/me/Desktop"])
    }
}
