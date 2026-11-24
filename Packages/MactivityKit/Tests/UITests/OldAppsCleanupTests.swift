import Core
import Foundation
import Storage
import Testing
@testable import UI

private actor OldAppsMoveRecorder: StorageTrashing {
    private(set) var moved: [String] = []

    func paths() -> [String] {
        moved
    }

    func moveToTrash(_ confirmation: TrashConfirmation) async throws -> URL? {
        moved.append(confirmation.path)
        return URL(fileURLWithPath: "/Trash")
    }
}

@MainActor
@Suite("Old app versions and leftovers: the sheet (D-282)")
struct OldAppsCleanupTests {
    private let copy = OldAppCopy(
        path: "/Applications/Writer Old.app", bundleID: "com.acme.Writer", name: "Writer", version: "1.0",
        keptPath: "/Applications/Writer.app", keptVersion: "2.0", size: 100
    )
    private let leftover = AppSupportLeftover(
        path: "/Users/me/Library/Caches/com.gone.App", kind: .caches, owner: "com.gone.App", appName: "Gone", matchedByName: false,
        size: 50,
        lastChanged: Date(timeIntervalSince1970: 1_700_000_000), fileCount: 12, contents: ["Cache.db", "fsCachedData"]
    )

    @Test("Nothing starts ticked, and each row says why it's listed and what's in it")
    func rows() {
        #expect(!FileCleanupSource.row(copy).startsTicked)
        #expect(FileCleanupSource.row(copy).keptApp == copy.keptPath)
        #expect(FileCleanupSource.row(copy).detail.contains("2.0"))
        let row = FileCleanupSource.row(leftover)
        #expect(!row.startsTicked)
        #expect(row.keptApp == nil)
        #expect(row.detail.contains("com.gone.App"))
        #expect(row.detail.contains("Cache.db"))
        #expect(row.detail.contains("12"))
    }

    @Test("A row that no longer qualifies right before the Trash stays, even ticked and in scope")
    func recheckRefuses() async {
        let source = FileCleanupSource(
            title: "Test", intro: "", symbol: "doc", tint: .blue, emptyTitle: "", noAccessTitle: "", noAccessDetail: "",
            settingsURL: nil, scope: { CleanupScope.oldApps(home: "/Users/me") }, rows: { [] },
            stillValid: { $0.path != "/Users/me/Library/Caches/com.back.App" }
        )
        let model = FileCleanupModel(source, loaded: [
            FileCleanupRow(path: "/Users/me/Library/Caches/com.gone.App", detail: "", size: 1, startsTicked: true),
            FileCleanupRow(path: "/Users/me/Library/Caches/com.back.App", detail: "", size: 1, startsTicked: true),
            FileCleanupRow(path: "/Users/me/Library/Caches/com.notpicked.App", detail: "", size: 1, startsTicked: false),
            FileCleanupRow(path: "/Users/me/Library/Containers/com.gone.App", detail: "", size: 1, startsTicked: true),
        ])
        var message = ""
        let trasher = OldAppsMoveRecorder()
        await model.perform(using: trasher) { message = $0 }
        #expect(await trasher.paths() == ["/Users/me/Library/Caches/com.gone.App"])
        #expect(message.contains("2"), "both refused rows are reported: \(message)")
    }
}
