import Core
import SwiftUI

/// Storage's Clean Up menu (D-117): the flows that move files to the Trash after showing them
/// first. One menu, so the volume card's header doesn't grow a button per cleanup.
struct StorageCleanUpMenu: View {
    let cleanups: StorageCleanups

    @State private var choosingApp = false

    var body: some View {
        Menu(String(
            localized: "Clean Up",
            bundle: .strings,
            comment: "Storage menu: uninstall, Messages attachments, device backups, Downloads, Mail"
        )) {
            Button(String(localized: "Uninstall App…", bundle: .strings)) { choosingApp = true }
                .disabled(cleanups.uninstall.isPreparing)
            Button(String(localized: "Old App Versions and Leftovers…", bundle: .strings)) { cleanups.oldApps.open() }
            Button(String(localized: "Big Files You Forgot…", bundle: .strings)) { cleanups.forgotten.open() }
            Button(String(localized: "Duplicate Files…", bundle: .strings)) { cleanups.duplicates.open() }
            Button(String(localized: "Downloads You Never Opened…", bundle: .strings)) { cleanups.unopened.open() }
            Divider()
            Button(String(localized: "Messages Attachments…", bundle: .strings)) { cleanups.messages.open() }
            Button(String(localized: "iPhone and iPad Backups…", bundle: .strings)) { cleanups.backups.open() }
            Button(String(localized: "Installers and Archives in Downloads…", bundle: .strings)) { cleanups.downloads.open() }
            Button(String(localized: "Screenshots and Screen Recordings…", bundle: .strings)) { cleanups.screenshots.open() }
            Button(String(localized: "Mail Downloads…", bundle: .strings)) { cleanups.mail.open() }
            Button(String(localized: "Developer Caches…", bundle: .strings)) { cleanups.developer.open() }
            Divider()
            Button(String(localized: "Cloud Folders…", bundle: .strings)) { cleanups.cloud.open() }
            Button(String(localized: "Purgeable Space…", bundle: .strings)) { cleanups.purgeable.open() }
        }
        .fixedSize()
        .help(Text("Shows what can go, then moves what you pick to the Trash, after asking", bundle: .strings))
        .fileImporter(isPresented: $choosingApp, allowedContentTypes: [.application]) { result in
            if case let .success(url) = result {
                Task { await cleanups.uninstall.prepare(url) }
            }
        }
        .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications"))
    }
}
