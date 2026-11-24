import Foundation
@testable import Storage
import Testing

@Suite("Purgeable space's parts (D-125)")
struct PurgeablePartsTests {
    @Test("Whose iCloud folder a container is")
    func places() {
        #expect(ICloudDownloads.place(container: "com~apple~CloudDocs", iCloudDrive: "iCloud Drive") == "iCloud Drive")
        #expect(ICloudDownloads.place(container: "57T9237FN3~net~whatsapp~WhatsApp", iCloudDrive: "iCloud Drive") == "WhatsApp")
    }

    @Test("Local snapshot dates from tmutil's listing, oldest first")
    func snapshots() {
        let listing = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-09-29-101010.local
        com.apple.TimeMachine.2026-09-28-235959.local
        """
        let dates = LocalSnapshots.dates(fromListing: listing)
        #expect(dates.count == 2)
        #expect(dates == dates.sorted())
        #expect(LocalSnapshots.dates(fromListing: "Snapshots for disk /:\n").isEmpty)
    }

    @Test("Remove Download refuses anything outside iCloud's folder")
    func scope() {
        #expect(throws: (any Error).self) {
            try ICloudDownloads.removeDownload("/Users/me/Documents/Taxes.pdf", home: "/Users/me")
        }
    }

    @Test("Only what Finder's iCloud Drive shows: iCloud Drive, and each app's Documents")
    func visible() {
        let root = URL(fileURLWithPath: "/Users/me/Library/Mobile Documents")
        #expect(ICloudDownloads.visibleFolder(container: "com~apple~CloudDocs", root: root).path
            == "/Users/me/Library/Mobile Documents/com~apple~CloudDocs")
        #expect(ICloudDownloads.visibleFolder(container: "57T9237FN3~net~whatsapp~WhatsApp", root: root).path
            == "/Users/me/Library/Mobile Documents/57T9237FN3~net~whatsapp~WhatsApp/Documents")
    }
}
