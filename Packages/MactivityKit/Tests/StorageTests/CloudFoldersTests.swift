import Foundation
@testable import Storage
import Testing

/// Cloud folders, sized (1.6).
struct CloudFoldersTests {
    @Test("Each CloudStorage folder gets its service's name and account")
    func names() {
        #expect(CloudFolders.displayName("Dropbox") == "Dropbox")
        #expect(CloudFolders.displayName("Dropbox-Personal") == "Dropbox (Personal)")
        #expect(CloudFolders.displayName("GoogleDrive-kade@example.com") == "Google Drive (kade@example.com)")
        #expect(CloudFolders.displayName("OneDrive-Personal") == "OneDrive (Personal)")
        #expect(CloudFolders.displayName("Box-Box") == "Box")
        #expect(CloudFolders.displayName("SomeService") == "SomeService")
    }

    @Test("iCloud Drive first, then each CloudStorage folder by name, hidden ones skipped")
    func folders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)")
        for name in [
            "Library/Mobile Documents",
            "Library/CloudStorage/OneDrive-Personal",
            "Library/CloudStorage/Dropbox",
            "Library/CloudStorage/.Trash",
        ] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: home) }
        let found = CloudFolders.folders(home: home.path)
        #expect(found.map(\.name) == ["iCloud Drive", "Dropbox", "OneDrive (Personal)"])
        #expect(found.first?.isICloud == true)
        try Data(count: 2_000_000).write(to: home.appendingPathComponent("Library/CloudStorage/Dropbox/a.bin"))
        let size = try CloudFolders.localSize(home.appendingPathComponent("Library/CloudStorage/Dropbox"))
        #expect(size >= 2_000_000)
    }

    @Test("Remove Download is only allowed inside a cloud folder")
    func removeScope() {
        #expect(throws: CocoaError.self) {
            try ICloudDownloads.removeCloudDownload("/Users/kade/Documents/a.pdf", home: "/Users/kade")
        }
    }
}
