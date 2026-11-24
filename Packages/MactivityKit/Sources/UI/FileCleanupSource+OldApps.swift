import AppKit
import Core
import Foundation
import os
import Storage
import SwiftUI

/// The apps history has seen, for the next scan (D-282). Filled when Storage shows; empty only
/// means fewer rows, since anything needing it then isn't listed.
final class RecordedAppsBox: Sendable {
    private let apps = OSAllocatedUnfairLock<[RecordedApp]>(initialState: [])

    var value: [RecordedApp] {
        get { apps.withLock { $0 } }
        set { apps.withLock { $0 = newValue } }
    }
}

extension FileCleanupSource {
    /// Old app versions and leftovers (D-282). Nothing starts ticked: a wrong row here is someone's
    /// working data, so each is the person's call, with why it's listed and what's in it.
    static func oldApps(recorded: RecordedAppsBox) -> FileCleanupSource {
        let environment: @Sendable () -> OldAppsEnvironment = {
            OldAppsEnvironment.live(recordedApps: recorded.value) { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
        }
        return FileCleanupSource(
            title: String(localized: "Old App Versions and Leftovers", bundle: .strings),
            intro: String(
                localized: """
                Second copies of apps, and support files of apps that are gone. Support files are listed only if no \
                installed app or running program claims them, nothing in them has changed for six months, and there's a \
                sign they were an app's. Apple's items and shared or sandbox containers never are. Nothing is ticked; tick \
                what you're sure about.
                """,
                bundle: .strings
            ),
            symbol: "app.badge.checkmark.fill", tint: .indigo,
            emptyTitle: String(localized: "No old app copies or leftovers found", bundle: .strings),
            noAccessTitle: String(localized: "Mactivity can't read your Library", bundle: .strings),
            noAccessDetail: String(
                localized: "Turn on Mactivity in Privacy & Security → Full Disk Access, then check again.",
                bundle: .strings
            ),
            settingsURL: VolumeInfo.fullDiskAccessSettingsURL,
            scope: { CleanupScope.oldApps() },
            rows: { () throws(ProtectedFolderError) in
                let env = environment()
                return (OldApps.copies(env).map(row) + OldApps.leftovers(env).map(row)).sorted { $0.size > $1.size }
            },
            stillValid: { row in
                let env = environment()
                if let kept = row.keptApp {
                    return OldApps.stillCopy(row.path, keeping: kept, env: env)
                }
                return OldApps.stillLeftover(row.path, env: env)
            },
            usesFinderForApps: true
        )
    }

    static func row(_ copy: OldAppCopy) -> FileCleanupRow {
        FileCleanupRow(
            path: copy.path, detail: detail(copy), size: copy.size, startsTicked: false,
            title: copy.version.map { "\(copy.name) \($0)" } ?? copy.name, keptApp: copy.keptPath
        )
    }

    static func row(_ item: AppSupportLeftover) -> FileCleanupRow {
        FileCleanupRow(
            path: item.path, detail: detail(item), size: item.size, startsTicked: false,
            title: (item.path as NSString).lastPathComponent
        )
    }

    /// "~/Downloads/Foo.app. Second copy: the one in /Applications is newer, version 3.2."
    static func detail(_ copy: OldAppCopy) -> String {
        let here = (copy.path as NSString).abbreviatingWithTildeInPath
        let kept = ((copy.keptPath as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        if copy.isSameVersion {
            return String(
                localized: "\(here)\nSecond copy of the same version as the one in \(kept), which stays.",
                bundle: .strings,
                comment: "Old app versions, a row: its path, then why it's listed; the folder of the copy that stays"
            )
        }
        let newer = copy.keptVersion ?? "?"
        return String(
            localized: "\(here)\nOlder copy: the one in \(kept), version \(newer), stays.",
            bundle: .strings,
            comment: "Old app versions, a row: its path, then why it's listed; the folder and version of the copy that stays"
        )
    }

    /// Where it is and whose it's thought to be, why it's listed, and what's in it.
    static func detail(_ item: AppSupportLeftover) -> String {
        let kind = UninstallSheet.title(item.kind)
        let folder = ((item.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        let changed = item.lastChanged.formatted(.dateTime.month(.wide).year())
        let why = if item.matchedByName {
            String(
                localized: """
                Named exactly like \(item.owner), an app Mactivity saw run that's no longer installed. Found by name: check it's that app's.
                """,
                bundle: .strings
            )
        } else if let name = item.appName {
            String(
                localized: "\(name) used this ID (\(item.owner)), and no app with it is installed now.",
                bundle: .strings,
                comment: "Leftovers, a row: an app's name and bundle ID"
            )
        } else {
            String(
                localized: "An app with windows used this ID (\(item.owner)), and none with it is installed now.",
                bundle: .strings,
                comment: "Leftovers, a row: a bundle ID"
            )
        }
        var lines = [
            String(
                localized: "\(kind) in \(folder) · last changed \(changed)",
                bundle: .strings,
                comment: "Leftovers, a row: what kind of item, its folder, the month it last changed"
            ),
            why,
        ]
        if !item.contents.isEmpty {
            let names = item.contents.formatted(.list(type: .and))
            let files = item.fileCount.formatted()
            lines.append(String(
                localized: "Files inside: \(files). Among them: \(names).",
                bundle: .strings,
                comment: "Leftovers, a row: the number of files in a folder, then a few of the names at its top"
            ))
        }
        return lines.joined(separator: "\n")
    }
}
