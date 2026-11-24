import Core
import Foundation
import Storage
import SwiftUI

extension FileCleanupSource {
    /// Files in Downloads nobody opened (1.8, D-260). Ticked: waiting over 90 days.
    static let unopened = FileCleanupSource(
        title: String(localized: "Downloads You Never Opened", bundle: .strings),
        intro: String(
            localized: """
            Files at the top of Downloads that macOS has no record of being opened since they arrived, a week \
            ago or more. Installers, archives and apps are left out. Ticked: waiting over 90 days.
            """,
            bundle: .strings
        ),
        symbol: "arrow.down.doc.fill", tint: .blue,
        emptyTitle: String(localized: "Everything in Downloads has been opened", bundle: .strings),
        noAccessTitle: String(localized: "Mactivity can't read Downloads", bundle: .strings),
        noAccessDetail: String(localized: "Allow it in Privacy & Security → Files and Folders, then check again.", bundle: .strings),
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"),
        scope: { CleanupScope.downloads() },
        rows: { () throws(ProtectedFolderError) in
            let now = Date()
            return try UnopenedDownloads.scan(now: now).map { item in
                let date = item.added.formatted(date: .abbreviated, time: .omitted)
                return FileCleanupRow(
                    path: item.path,
                    detail: String(
                        localized: "Added \(date), never opened",
                        bundle: .strings,
                        comment: "Downloads you never opened, a row"
                    ),
                    size: item.size, startsTicked: UnopenedDownloads.startsTicked(item, now: now)
                )
            }
        }
    )
}
