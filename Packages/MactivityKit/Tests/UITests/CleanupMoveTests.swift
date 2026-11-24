import Core
import Foundation
import Storage
import Testing
@testable import UI

/// Records what a cleanup asks the Trash to move; moves nothing, and reports success.
private actor MoveRecorder: StorageTrashing {
    private(set) var moved: [String] = []

    func paths() -> [String] {
        moved
    }

    func moveToTrash(_ confirmation: TrashConfirmation) async throws -> URL? {
        moved.append(confirmation.path)
        return URL(fileURLWithPath: "/Trash").appendingPathComponent((confirmation.path as NSString).lastPathComponent)
    }
}

@MainActor
@Suite("Cleanups move only what's ticked, only from their folders (D-123)")
struct CleanupMoveTests {
    let home = "/Users/me"

    @Test("A file cleanup: ticked rows inside its folder go; unticked ones and outsiders don't")
    func fileCleanup() async {
        let source = FileCleanupSource(
            title: "Test", intro: "", symbol: "doc", tint: .blue, emptyTitle: "", noAccessTitle: "", noAccessDetail: "",
            settingsURL: nil, scope: { CleanupScope.downloads(home: "/Users/me") }, rows: { [] }
        )
        let rows = [
            FileCleanupRow(path: "/Users/me/Downloads/Old.dmg", detail: "", size: 100, startsTicked: true),
            FileCleanupRow(path: "/Users/me/Downloads/Keep.pkg", detail: "", size: 50, startsTicked: false),
            FileCleanupRow(path: "/Users/me/Documents/Taxes.pdf", detail: "", size: 10, startsTicked: true),
        ]
        let model = FileCleanupModel(source, loaded: rows)
        var refreshed = false
        model.onMoved = { refreshed = true }
        var message = ""
        let trasher = MoveRecorder()
        await model.perform(using: trasher) { message = $0 }
        #expect(await trasher.paths() == ["/Users/me/Downloads/Old.dmg"])
        #expect(refreshed)
        #expect(message.contains("1"), "the refused outsider is reported: \(message)")
    }

    @Test("Messages: only attachments the filter picks, inside Messages' folder")
    func messages() async {
        let old = Date().addingTimeInterval(-400 * 86400)
        let folder = "/Users/me/Library/Messages/Attachments/ab/12/GUID"
        let model = MessagesCleanupModel(loaded: [
            MessageAttachment(path: "\(folder)/Old.MOV", size: 300, date: old, kind: .video),
            MessageAttachment(path: "\(folder)/New.HEIC", size: 3, date: Date(), kind: .photo),
            MessageAttachment(path: "/Users/me/Pictures/Old.MOV", size: 300, date: old, kind: .video),
        ])
        model.scope = .messages(home: home)
        let trasher = MoveRecorder()
        await model.perform(using: trasher) { _ in }
        #expect(await trasher.paths() == ["\(folder)/Old.MOV"])
    }

    @Test("Backups: nothing but the ticked, and a backup folder only as a whole")
    func backups() async {
        let backup = "/Users/me/Library/Application Support/MobileSync/Backup/00008120-001A"
        let update = "/Users/me/Library/iTunes/iPhone Software Updates/iPhone18,1_26.0_Restore.ipsw"
        let model = DeviceBackupsModel(loaded: DeviceBackupsScan(
            backups: [DeviceBackup(
                path: backup, deviceName: "iPhone", productName: nil, systemVersion: nil, date: nil, size: 1, isEncrypted: false
            )],
            updates: [DeviceUpdateFile(path: update, size: 1, date: Date())]
        ))
        model.scope = .backups(home: home)
        // Updates start ticked; backups never do.
        #expect(model.selected == [update])
        let trasher = MoveRecorder()
        await model.perform(using: trasher) { _ in }
        #expect(await trasher.paths() == [update])
        // A "backup" whose path is a file inside one: refused, even ticked.
        let inside = DeviceBackupsModel(loaded: DeviceBackupsScan(
            backups: [DeviceBackup(
                path: "\(backup)/Manifest.db", deviceName: "iPhone", productName: nil, systemVersion: nil, date: nil, size: 1,
                isEncrypted: false
            )],
            updates: []
        ))
        inside.scope = .backups(home: home)
        inside.selected = ["\(backup)/Manifest.db"]
        let second = MoveRecorder()
        await inside.perform(using: second) { _ in }
        #expect(await second.paths().isEmpty)
    }
}
