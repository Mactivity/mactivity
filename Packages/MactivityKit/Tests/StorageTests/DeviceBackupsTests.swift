import Foundation
@testable import Storage
import Testing

@Suite("iPhone and iPad backups (D-117)")
struct DeviceBackupsTests {
    @Test("A backup's name, model, system, date and encryption from its plists")
    func parse() {
        let date = Date(timeIntervalSince1970: 1_710_000_000)
        let backup = DeviceBackups.backup(
            path: "/b/00008120-001A",
            info: ["Display Name": "Kade's iPhone", "Product Name": "iPhone 15 Pro", "Product Version": "18.1", "Last Backup Date": date],
            manifest: ["IsEncrypted": true],
            size: 42
        )
        #expect(backup.deviceName == "Kade's iPhone")
        #expect(backup.productName == "iPhone 15 Pro")
        #expect(backup.systemVersion == "18.1")
        #expect(backup.date == date)
        #expect(backup.isEncrypted)
        // Without an Info.plist, the manifest's lockdown values, then the folder name.
        let bare = DeviceBackups.backup(
            path: "/b/00008030-XYZ", info: [:], manifest: ["Lockdown": ["DeviceName": "iPad", "ProductVersion": "17.5"]], size: 1
        )
        #expect(bare.deviceName == "iPad")
        #expect(bare.systemVersion == "17.5")
        #expect(!bare.isEncrypted)
        #expect(DeviceBackups.backup(path: "/b/00008030-XYZ", info: [:], manifest: [:], size: 1).deviceName == "00008030-XYZ")
    }

    @Test("A home folder: backups with their size, newest first, and downloaded updates")
    func scan() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let backups = DeviceBackups.backupsFolder(home: home.path)
        for (id, name, days) in [("A", "Old iPad", 900.0), ("B", "iPhone", 2.0)] {
            let folder = backups.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("ab"), withIntermediateDirectories: true)
            let info: NSDictionary = ["Device Name": name, "Last Backup Date": Date().addingTimeInterval(-days * 86400)]
            try info.write(to: folder.appendingPathComponent("Info.plist"))
            try Data(count: 100_000).write(to: folder.appendingPathComponent("ab/file"))
        }
        let updates = home.appendingPathComponent("Library/iTunes/iPhone Software Updates")
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        try Data(count: 5000).write(to: updates.appendingPathComponent("iPhone16,1_18.0_Restore.ipsw"))
        let found = try DeviceBackups.scan(home: home.path)
        #expect(found.backups.map(\.deviceName) == ["iPhone", "Old iPad"])
        #expect(found.backups.allSatisfy { $0.size >= 100_000 })
        #expect(found.updates.map(\.name) == ["iPhone16,1_18.0_Restore.ipsw"])
        // No backups at all is an empty list, not an error.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(try DeviceBackups.scan(home: empty.path) == DeviceBackupsScan(backups: [], updates: []))
    }

    @Test("Rebuildable developer locations: caches and DerivedData, never archives (D-120)")
    func rebuildable() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for path in [
            "Library/Developer/Xcode/DerivedData/App-abc",
            "Library/Developer/Xcode/Archives/2026-09-01",
            ".npm/_cacache/content",
        ] {
            let folder = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: 40000).write(to: folder.appendingPathComponent("file"))
        }
        let kinds = Set(DeveloperLens.rebuildableItems(home: home.path).map(\.kind))
        #expect(kinds == [.derivedData, .npmCache])
    }
}
