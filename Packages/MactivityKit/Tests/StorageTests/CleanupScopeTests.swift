import Foundation
@testable import Storage
import Testing

@Suite("Each cleanup moves only from its own folders (D-123)")
struct CleanupScopeTests {
    let home = "/Users/me"

    @Test("Downloads: only the folder's top level")
    func downloads() {
        let scope = CleanupScope.downloads(home: home)
        #expect(scope.allows("/Users/me/Downloads/Xcode.xip"))
        #expect(!scope.allows("/Users/me/Downloads/Project/Installer.dmg"))
        #expect(!scope.allows("/Users/me/Downloads"))
        #expect(!scope.allows("/Users/me/Documents/Taxes.pdf"))
    }

    @Test("Climbing out, relative paths and look-alike folders are refused")
    func escapes() {
        let scope = CleanupScope.messages(home: home)
        #expect(scope.allows("/Users/me/Library/Messages/Attachments/ab/12/GUID/IMG_1.HEIC"))
        #expect(!scope.allows("/Users/me/Library/Messages/Attachments/../chat.db"))
        #expect(!scope.allows("/Users/me/Library/Messages/Attachments"))
        #expect(!scope.allows("/Users/me/Library/Messages/AttachmentsOld/IMG_1.HEIC"))
        #expect(!scope.allows("Library/Messages/Attachments/x"))
        #expect(scope.allows("/Users/me/Library/Messages/Attachments//ab/IMG_2.HEIC"))
    }

    @Test("Backups: a device's folder, or an update file, directly inside")
    func backups() {
        let scope = CleanupScope.backups(home: home)
        #expect(scope.allows("/Users/me/Library/Application Support/MobileSync/Backup/00008120-001A"))
        #expect(!scope.allows("/Users/me/Library/Application Support/MobileSync/Backup/00008120-001A/Manifest.db"))
        #expect(scope.allows("/Users/me/Library/iTunes/iPhone Software Updates/iPhone18,1_26.0_Restore.ipsw"))
        #expect(!scope.allows("/Users/me/Library/Application Support/MobileSync"))
    }

    @Test("Developer: the rebuildable locations themselves, never Archives")
    func developer() {
        let scope = CleanupScope.developer(home: home)
        #expect(scope.allows("/Users/me/Library/Developer/Xcode/DerivedData"))
        #expect(scope.allows("/Users/me/.npm/_cacache"))
        #expect(!scope.allows("/Users/me/Library/Developer/Xcode/Archives"))
        #expect(!scope.allows("/Users/me/Library/Developer/Xcode"))
    }

    @Test("Screenshots: the chosen folder and the Desktop, top level only")
    func screenshots() {
        let scope = CleanupScope.screenshots(home: home, setting: "/Users/me/Desktop/Screenshots")
        #expect(scope.allows("/Users/me/Desktop/Screenshots/Screenshot 1.png"))
        #expect(scope.allows("/Users/me/Desktop/Screenshot 2.png"))
        #expect(!scope.allows("/Users/me/Desktop/Work/Screenshot 3.png"))
    }

    @Test("Big files you forgot may move from the home folder's own folders, never Library or hidden ones")
    func forgottenScope() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString)")
        for name in ["Movies", "Library", ".config"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: home) }
        let scope = CleanupScope.forgotten(home: home.path)
        #expect(scope.allows(home.appendingPathComponent("Movies/Old/clip.mov").path))
        #expect(!scope.allows(home.appendingPathComponent("Library/Application Support/x.db").path))
        #expect(!scope.allows(home.appendingPathComponent(".config/big.bin").path))
        #expect(!scope.allows(home.appendingPathComponent("Movies").path))
    }
}
