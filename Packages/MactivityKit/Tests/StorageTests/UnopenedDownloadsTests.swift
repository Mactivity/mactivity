import Foundation
@testable import Storage
import Testing

@Suite("Downloads you never opened (D-260)")
struct UnopenedDownloadsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func days(_ count: Double) -> Date {
        now.addingTimeInterval(-count * 86400)
    }

    @Test("Listed: indexed, never opened, a week old, not an app or an installer")
    func listed() {
        #expect(UnopenedDownloads.isUnopened(name: "Report.pdf", indexed: true, lastUsed: nil, added: days(10), now: now))
        // Opened once: not listed.
        #expect(!UnopenedDownloads.isUnopened(name: "Report.pdf", indexed: true, lastUsed: days(9), added: days(10), now: now))
        // Spotlight has no record: can't tell, so not listed.
        #expect(!UnopenedDownloads.isUnopened(name: "Report.pdf", indexed: false, lastUsed: nil, added: days(10), now: now))
        // Arrived this week: you may still get to it.
        #expect(!UnopenedDownloads.isUnopened(name: "Report.pdf", indexed: true, lastUsed: nil, added: days(3), now: now))
        // Their own cleanups, or something someone may run.
        for name in ["Setup.dmg", "Tool.pkg", "Photos.zip", "Movie.crdownload", "Thing.app"] {
            #expect(!UnopenedDownloads.isUnopened(name: name, indexed: true, lastUsed: nil, added: days(100), now: now))
        }
    }

    @Test("Ticked after 90 days")
    func ticked() {
        #expect(UnopenedDownloads.startsTicked(UnopenedDownload(path: "/a", size: 1, added: days(91)), now: now))
        #expect(!UnopenedDownloads.startsTicked(UnopenedDownload(path: "/a", size: 1, added: days(30)), now: now))
    }

    @Test("A missing folder is an empty list")
    func missing() throws {
        #expect(try UnopenedDownloads.scan(URL(fileURLWithPath: "/nonexistent/Downloads")).isEmpty)
    }
}
