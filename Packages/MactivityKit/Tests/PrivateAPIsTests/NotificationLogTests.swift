import Core
import Foundation
@testable import PrivateAPIs
import Testing

/// Notifications from usernoted's log lines (D-289). `unified-log-notifications.ndjson` is real
/// output from macOS 27.2, with request IDs, URLs, categories and times replaced.
struct NotificationLogTests {
    private func fixture() throws -> Data {
        try Data(contentsOf: Fixtures.directory.appendingPathComponent("unified-log-notifications.ndjson"))
    }

    private let shown = "Delivering %{public}s to %{public}s: askBeforePresenting: %{bool,public}d"
    private let updated = "Delivering %{public}s to %{public}s without presentation, just updating existing record."
    private let actually = "actually deliver %{public}s: deliveredChanged: %{bool,public}d"

    private func line(_ format: String, _ message: String, second: Int = 0) -> String {
        let entry = [
            "timestamp": String(format: "2026-11-04 10:00:%02d.000000-0700", second), "formatString": format, "eventMessage": message,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func record(_ app: String, _ uuid: String, suffix: String = "to [ .alert ]: askBeforePresenting: true") -> String {
        "Delivering <NotificationRecord app:\"\(app)\" ident:\"A-B\" req:\"R\" uuid:\"\(uuid)\" source:\"S\"> \(suffix)"
    }

    private func reading(_ lines: String...) -> NotificationLogReading {
        NotificationLog.reading(ndjson: Data(lines.joined(separator: "\n").utf8))
    }

    @Test("Real lines: each delivery counts once; updates, silent ones and a shown-again alert don't")
    func realLines() throws {
        guard case let .read(events) = try NotificationLog.reading(ndjson: fixture()) else {
            Issue.record("Should read")
            return
        }
        var counts: [String: Int] = [:]
        for event in events {
            counts[event.app, default: 0] += 1
        }
        #expect(counts == [
            "com.apple.MobileSMS": 3, "com.anthropic.claudefordesktop": 2, "com.apple.iCal": 1, "com.apple.mail": 1,
        ])
        #expect(events == events.sorted { $0.at < $1.at })
    }

    @Test("Senders: macOS's alerts by their ID, every website as one, so no site's name is kept")
    func senders() {
        #expect(NotificationLog.app("_SYSTEM_CENTER_:com.apple.followup.alert") == "com.apple.followup.alert")
        #expect(NotificationLog.app("_WEB_CENTER_:web.claude.ai") == NotificationEvent.website)
        #expect(NotificationLog.app("com.apple.mail") == "com.apple.mail")
        #expect(NotificationLog.app("") == nil)
    }

    @Test("What an app wrote can't change the shape: it's read from the format string")
    func spoofed() {
        let found = reading(
            line(shown, record("com.example", "U1", suffix: "category:\"without presentation, just updating existing record.\" to [ ]: x")),
            line(actually, "actually deliver U1: deliveredChanged: true, alertsChanged: false")
        )
        guard case let .read(events) = found else {
            Issue.record("Should read")
            return
        }
        #expect(events.map(\.app) == ["com.example"])
    }

    @Test("A delivery only counts with deliveredChanged true, and an update's pair doesn't")
    func pairs() {
        let found = reading(
            line(shown, record("com.example.a", "U1")),
            line(actually, "actually deliver U1: deliveredChanged: false, alertsChanged: false"),
            line(updated, record("com.example.b", "U2", suffix: "to [ .alert ] without presentation, just updating existing record.")),
            line(actually, "actually deliver U2: deliveredChanged: false, alertsChanged: true")
        )
        #expect(found == .read([]))
    }

    @Test("A Delivering line of an unknown shape: can't read, rather than a wrong count")
    func unknownShape() {
        #expect(reading(line("Delivering %{public}s to %{public}s in a new way", record("com.example", "U1"))) == .unreadable)
        #expect(reading(line(shown, "Delivering a record with different fields")) == .unreadable)
        #expect(reading(line(actually, "actually deliver U1: changed: yes")) == .unreadable)
    }

    @Test("One of the two lines gone: can't read. A pair cut by the read's start or end is fine")
    func oneWithoutTheOther() {
        let sent = (0 ..< 3).map { line(shown, record("com.example", "U\($0)"), second: $0) }
        #expect(reading(sent[0], sent[1], sent[2]) == .unreadable)
        let outcomes = (0 ..< 3).map { line(actually, "actually deliver U\($0): deliveredChanged: true", second: $0) }
        #expect(reading(outcomes[0], outcomes[1], outcomes[2]) == .unreadable)
        #expect(reading(sent[0]) == .read([]))
        #expect(reading(outcomes[0]) == .read([]))
        // The two lines there, with IDs that no longer match.
        #expect(reading(
            sent[0],
            sent[1],
            sent[2],
            outcomes[0].replacingOccurrences(of: "U0", with: "X0"),
            outcomes[1]
                .replacingOccurrences(of: "U1", with: "X1"),
            outcomes[2].replacingOccurrences(of: "U2", with: "X2")
        ) == .unreadable)
    }

    @Test("A quiet log is no notifications, and lines that aren't JSON are skipped")
    func quiet() {
        #expect(reading() == .read([]))
        #expect(reading("not json", "{\"count\":0}") == .read([]))
    }

    @Test(
        "Live: this Mac's log reads",
        .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil)
    )
    func live() {
        let reading = NotificationLog.read(from: Date().addingTimeInterval(-3600), to: Date())
        #expect(reading != .unreadable)
    }
}
