import Foundation
@testable import Readouts
import Testing

/// Control Center controls' links (D-210).
struct ControlLinkTests {
    @Test("A control's link round-trips with its token, and does nothing without it")
    func links() throws {
        let clean = try #require(ControlLink.url(.cleanKeyboard, token: "abc"))
        #expect(ControlLink.action(clean, token: "abc") == .cleanKeyboard)
        let on = try #require(ControlLink.url(.stayAwake(true), token: "abc"))
        #expect(ControlLink.action(on, token: "abc") == .stayAwake(true))
        let off = try #require(ControlLink.url(.stayAwake(false), token: "abc"))
        #expect(ControlLink.action(off, token: "abc") == .stayAwake(false))
        #expect(ControlLink.action(clean, token: "other") == nil, "a page can't guess it")
        #expect(ControlLink.action(clean, token: nil) == nil)
        #expect(try ControlLink.action(#require(URL(string: "mactivity://control/clean-keyboard")), token: "abc") == nil)
        #expect(try ControlLink.action(#require(URL(string: "mactivity://activate?key=K")), token: "abc") == nil)
    }

    @Test("The state file sits beside the widget file and round-trips")
    func state() throws {
        let widget = FileManager.default.temporaryDirectory.appendingPathComponent("w-\(UUID().uuidString)/widget.json")
        try FileManager.default.createDirectory(at: widget.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: widget.deletingLastPathComponent()) }
        let url = ControlState.fileURL(widgetFile: widget)
        #expect(url.lastPathComponent == "controls.json")
        try ControlState(token: "t", stayAwake: true).write(url)
        #expect(ControlState.read(url) == ControlState(token: "t", stayAwake: true))
    }

    @Test("The Today widget's Your Day link (1.6): round trip, and nothing with a wrong token")
    func yourDay() throws {
        let url = try #require(ControlLink.url(.yourDay, token: "abc"))
        #expect(url.absoluteString == "mactivity://control/your-day?token=abc")
        #expect(ControlLink.action(url, token: "abc") == .yourDay)
        #expect(ControlLink.action(url, token: "other") == nil)
    }
}
