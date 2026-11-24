import AppKit
import Core
import Observation
import os
import Storage
import SwiftUI

/// One row of a file cleanup: a file, what it is, its size, and whether it starts ticked.
struct FileCleanupRow: Hashable, Sendable, Identifiable {
    var id: String {
        path
    }

    let path: String
    let detail: String
    let size: UInt64
    let startsTicked: Bool
    /// A name for the row when the file's own isn't one ("npm cache", not "_cacache").
    var title: String?
    /// Duplicate files: the copy that stays, checked again right before the Trash (D-251).
    var keeps: String?
    /// Old app versions: the copy of the app that stays, checked again right before the Trash (D-282).
    var keptApp: String?

    var name: String {
        title ?? (path as NSString).lastPathComponent
    }
}

/// What a file cleanup is about: its words, and where to read the files from.
struct FileCleanupSource: Sendable {
    let title: String
    let intro: String
    let symbol: String
    let tint: Color
    let emptyTitle: String
    let noAccessTitle: String
    let noAccessDetail: String
    let settingsURL: URL?
    /// Where this cleanup may move from; checked right before the Trash (D-123).
    let scope: @Sendable () -> CleanupScope
    let rows: @Sendable () throws(ProtectedFolderError) -> [FileCleanupRow]
    /// Asked of each row right before the Trash, beyond the scope: whether it should still go (D-282).
    var stillValid: (@Sendable (FileCleanupRow) -> Bool)?
    /// An app that can't be moved directly (an administrator's) goes through Finder, which asks.
    var usesFinderForApps = false

    /// Installers and archives in Downloads (D-118).
    static let downloads = FileCleanupSource(
        title: String(localized: "Installers and Archives in Downloads", bundle: .strings),
        intro: String(
            localized: """
            Disk images, installers and archives kept after installing, and downloads that never finished. \
            Only the top of the folder; apps are never listed. Ticked: added over 30 days ago.
            """,
            bundle: .strings
        ),
        symbol: "arrow.down.circle.fill", tint: .blue,
        emptyTitle: String(localized: "No installers or archives in Downloads", bundle: .strings),
        noAccessTitle: String(localized: "Mactivity can't read Downloads", bundle: .strings),
        noAccessDetail: String(localized: "Allow it in Privacy & Security → Files and Folders, then check again.", bundle: .strings),
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"),
        scope: { CleanupScope.downloads() },
        rows: { () throws(ProtectedFolderError) in
            let now = Date()
            return try DownloadsLeftovers.scan().map { item in
                FileCleanupRow(
                    path: item.path, detail: downloadDetail(item), size: item.size,
                    startsTicked: DownloadsLeftovers.startsTicked(item, now: now)
                )
            }
        }
    )

    /// Attachments Mail saved to open them (D-119).
    static let mail = FileCleanupSource(
        title: String(localized: "Mail Downloads", bundle: .strings),
        intro: String(
            localized: """
            Copies of attachments Mail saved when you opened them. The messages keep their attachments, and Mail \
            saves a copy again when you open one. Ticked: saved over 30 days ago.
            """,
            bundle: .strings
        ),
        symbol: "envelope.fill", tint: .blue,
        emptyTitle: String(localized: "No Mail downloads on this Mac", bundle: .strings),
        noAccessTitle: String(localized: "Mactivity needs Full Disk Access", bundle: .strings),
        noAccessDetail: String(
            localized: "macOS protects Mail's folder. Turn on Mactivity in Privacy & Security → Full Disk Access, then check again.",
            bundle: .strings
        ),
        settingsURL: VolumeInfo.fullDiskAccessSettingsURL,
        scope: { CleanupScope.mail() },
        rows: { () throws(ProtectedFolderError) in
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            return try MailDownloads.scan().map { file in
                let date = file.date.formatted(date: .abbreviated, time: .omitted)
                return FileCleanupRow(
                    path: file.path,
                    detail: String(localized: "Saved \(date)", bundle: .strings, comment: "Mail downloads row: when Mail saved it"),
                    size: file.size, startsTicked: file.date < cutoff
                )
            }
        }
    )

    /// Screenshots and screen recordings (D-122), ticked when over 30 days old.
    static let screenshots = FileCleanupSource(
        title: String(localized: "Screenshots and Screen Recordings", bundle: .strings),
        intro: String(
            localized: """
            Captures macOS saved to your screenshot folder and the Desktop. Only the ones macOS marked as \
            screenshots or recordings are listed. Ticked: over 30 days old.
            """,
            bundle: .strings
        ),
        symbol: "camera.viewfinder", tint: .purple,
        emptyTitle: String(localized: "No screenshots or screen recordings to clean up", bundle: .strings),
        noAccessTitle: String(localized: "Mactivity can't read your screenshot folder", bundle: .strings),
        noAccessDetail: String(localized: "Allow it in Privacy & Security → Files and Folders, then check again.", bundle: .strings),
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"),
        scope: { CleanupScope.screenshots() },
        rows: { () throws(ProtectedFolderError) in
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            return try ScreenCaptures.scan().map { capture in
                let date = capture.date.formatted(date: .abbreviated, time: .omitted)
                let kind = capture.isRecording
                    ? String(localized: "Screen recording", bundle: .strings)
                    : String(localized: "Screenshot", bundle: .strings)
                return FileCleanupRow(
                    path: capture.path,
                    detail: String(localized: "\(kind) · \(date)", bundle: .strings, comment: "Screenshots cleanup row: kind, then date"),
                    size: capture.size, startsTicked: capture.date < cutoff
                )
            }
        }
    )

    /// Developer caches that come back by themselves (D-120), all ticked.
    static let developer = FileCleanupSource(
        title: String(localized: "Developer Caches", bundle: .strings),
        intro: String(
            localized: """
            Build products and downloads that come back by themselves: Xcode rebuilds, package managers download \
            again. The next build or install is slower. Quit Xcode before moving DerivedData.
            """,
            bundle: .strings
        ),
        symbol: "hammer.fill", tint: .orange,
        emptyTitle: String(localized: "No developer caches on this Mac", bundle: .strings),
        noAccessTitle: String(localized: "Mactivity needs Full Disk Access", bundle: .strings),
        noAccessDetail: String(
            localized: "Turn on Mactivity in Privacy & Security → Full Disk Access, then check again.",
            bundle: .strings
        ),
        settingsURL: VolumeInfo.fullDiskAccessSettingsURL,
        scope: { CleanupScope.developer() },
        rows: { () throws(ProtectedFolderError) in
            DeveloperLens.rebuildableItems().sorted { $0.size > $1.size }.map { item in
                FileCleanupRow(path: item.path, detail: item.note, size: item.size, startsTicked: true, title: item.title)
            }
        }
    )

    /// Big files nothing has touched in a year (1.6). None start ticked: they're the person's own.
    static let forgotten = FileCleanupSource(
        title: String(localized: "Big Files You Forgot", bundle: .strings),
        intro: String(
            localized: """
            Files of 100 MB or more in your home folder that nothing has opened, changed or added in a year. \
            Only files on this Mac: never apps' own data, nothing inside a library like Photos, and not iCloud \
            Drive. Nothing is ticked; tick what you're sure about.
            """,
            bundle: .strings
        ),
        symbol: "clock.badge.questionmark", tint: .indigo,
        emptyTitle: String(localized: "No big files sitting untouched for a year", bundle: .strings),
        noAccessTitle: String(localized: "Mactivity can't read your home folder", bundle: .strings),
        noAccessDetail: String(localized: "Allow it in Privacy & Security → Files and Folders, then check again.", bundle: .strings),
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"),
        scope: { CleanupScope.forgotten() },
        rows: { () throws(ProtectedFolderError) in
            ForgottenFiles.scan().map { file in
                FileCleanupRow(path: file.path, detail: forgottenDetail(file), size: file.size, startsTicked: false)
            }
        }
    )

    /// Exact copies (1.6), each beside the one kept. Ticked: copies in Downloads.
    static let duplicates = FileCleanupSource(
        title: String(localized: "Duplicate Files", bundle: .strings),
        intro: String(
            localized: """
            Exact copies of files of 1 MB or more in your own folders, compared byte for byte. One of each \
            stays; the rest are listed with the file they copy. Copies that share their space with the \
            original free nothing and aren't listed. Ticked: copies in Downloads.
            """,
            bundle: .strings
        ),
        symbol: "doc.on.doc.fill", tint: .teal,
        emptyTitle: String(localized: "No duplicate files in your folders", bundle: .strings),
        noAccessTitle: String(localized: "Mactivity can't read your home folder", bundle: .strings),
        noAccessDetail: String(localized: "Allow it in Privacy & Security → Files and Folders, then check again.", bundle: .strings),
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"),
        scope: { CleanupScope.forgotten() },
        rows: { () throws(ProtectedFolderError) in
            let downloads = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads") + "/"
            return DuplicateFiles.scan().map { copy in
                let original = (copy.original as NSString).abbreviatingWithTildeInPath
                return FileCleanupRow(
                    path: copy.path,
                    detail: String(
                        localized: "Same as \(original)",
                        bundle: .strings,
                        comment: "Duplicate files, a row: the copy that stays"
                    ),
                    size: copy.reclaimable, startsTicked: copy.path.hasPrefix(downloads), keeps: copy.original
                )
            }
        }
    )

    /// "Last used March 2025 · ~/Movies/Exports".
    static func forgottenDetail(_ file: ForgottenFile) -> String {
        let when = file.lastTouched.formatted(.dateTime.month(.wide).year())
        let folder = ((file.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        return String(
            localized: "Last used \(when) · \(folder)",
            bundle: .strings,
            comment: "Big files you forgot, a row: when anything last touched it, then its folder"
        )
    }

    /// "Disk image · added Mar 2".
    static func downloadDetail(_ item: DownloadLeftover) -> String {
        let kind = switch item.kind {
        case .diskImage: String(localized: "Disk image", bundle: .strings)
        case .installer: String(localized: "Installer", bundle: .strings, comment: "A .pkg file")
        case .archive: String(localized: "Archive", bundle: .strings, comment: "A .zip or similar file")
        case .unfinished: String(localized: "Unfinished download", bundle: .strings)
        }
        let date = item.added.formatted(date: .abbreviated, time: .omitted)
        return String(localized: "\(kind) · added \(date)", bundle: .strings, comment: "Downloads cleanup row: kind, then when it arrived")
    }
}

/// A list of files, some ticked, moved to the Trash after one confirmation (D-118, D-119).
@MainActor
@Observable
final class FileCleanupModel {
    enum State: Equatable {
        case idle, loading, loaded, noAccess
    }

    let source: FileCleanupSource
    /// Where moves are allowed from: the source's scope as of now, or a test's. Read at each
    /// move, not once: the screenshot folder is a setting that can change while Storage is
    /// open, and the scan reads it fresh (D-140).
    var scope: CleanupScope {
        get { scopeOverride ?? source.scope() }
        set { scopeOverride = newValue }
    }

    @ObservationIgnored private var scopeOverride: CleanupScope?
    var isPresented = false
    var confirming = false
    private(set) var state = State.idle
    private(set) var rows: [FileCleanupRow] = []
    var selected: Set<String> = []
    private(set) var isMoving = false
    /// Called after files were moved, so totals elsewhere (the Trash, Reclaimable) refresh.
    var onMoved: () -> Void = {}

    init(_ source: FileCleanupSource) {
        self.source = source
    }

    /// Already loaded: render tests.
    init(_ source: FileCleanupSource, loaded rows: [FileCleanupRow]) {
        self.source = source
        self.rows = rows
        state = .loaded
        selected = Set(rows.filter(\.startsTicked).map(\.path))
    }

    func open() {
        isPresented = true
        Task { await load() }
    }

    func load() async {
        state = .loading
        let read = source.rows
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[FileCleanupRow], ProtectedFolderError> in
            do throws(ProtectedFolderError) {
                return try .success(read())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(found):
            rows = found
            selected = Set(found.filter(\.startsTicked).map(\.path))
            state = .loaded
        case .failure:
            rows = []
            selected = []
            state = .noAccess
        }
    }

    var selectedBytes: UInt64 {
        rows.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    func binding(_ path: String) -> Binding<Bool> {
        Binding { self.selected.contains(path) } set: { on in
            if on {
                self.selected.insert(path)
            } else {
                self.selected.remove(path)
            }
        }
    }

    /// The user confirmed: moves each ticked file. The `TrashConfirmation`s made here are this
    /// flow's confirm step (as in `UninstallModel`).
    func perform(using trasher: any StorageTrashing, toast: @escaping (String) -> Void) async {
        guard !isMoving else {
            return
        }
        isMoving = true
        let moving = rows.filter { selected.contains($0.path) }
        let bytes = selectedBytes
        var failed = 0
        let scope = scope
        for row in moving {
            // A duplicate goes only while the copy that stays is still there.
            if let keeps = row.keeps, !DuplicateFiles.stillCopy(row.path, of: keeps) {
                failed += 1
            } else if let stillValid = source.stillValid,
                      await !Task.detached(priority: .userInitiated, operation: { stillValid(row) }).value {
                failed += 1
            } else if await !CleanupMove.move(row.path, scope: scope, using: trasher) {
                if !source.usesFinderForApps || row.keptApp == nil || !scope.allows(row.path) {
                    failed += 1
                } else if await !UninstallModel.recycleWithFinder(row.path) {
                    failed += 1
                }
            }
        }
        isMoving = false
        await load()
        onMoved()
        let size = Formatters.bytes(bytes)
        toast(failed == 0
            ? String(localized: "Moved \(size) to the Trash. Empty the Trash to free the space.", bundle: .strings)
            : String(localized: "Moved to the Trash, but some items couldn't be moved: \(failed).", bundle: .strings))
    }
}

struct FileCleanupSheet: View {
    @Bindable var model: FileCleanupModel
    let trasher: any StorageTrashing
    let toast: (String) -> Void

    private var source: FileCleanupSource {
        model.source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                Image(systemName: source.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(source.tint)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(source.title)
                        .font(Tokens.Typography.headline)
                    Text(source.intro)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            content
            HStack {
                if model.isMoving {
                    ProgressView().controlSize(.small)
                } else if model.state == .loaded {
                    Text("Selected: \(Formatters.bytes(model.selectedBytes))", bundle: .strings)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button(String(localized: "Done", bundle: .strings)) { model.isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Move to Trash…", bundle: .strings), role: .destructive) { model.confirming = true }
                    .disabled(model.selected.isEmpty || model.isMoving)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 600)
        .confirmationDialog(
            String(localized: "Move \(Formatters.bytes(model.selectedBytes)) to the Trash?", bundle: .strings),
            isPresented: $model.confirming, titleVisibility: .visible
        ) {
            Button(String(localized: "Move to Trash", bundle: .strings), role: .destructive) {
                Task { await model.perform(using: trasher, toast: toast) }
            }
            Button(String(localized: "Cancel", bundle: .strings), role: .cancel) {}
        } message: {
            Text("You can put everything back from the Trash.", bundle: .strings)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        case .noAccess:
            ContentUnavailableView {
                Label(source.noAccessTitle, systemImage: "lock")
            } description: {
                Text(source.noAccessDetail)
            } actions: {
                Button(String(localized: "Open Privacy & Security…", bundle: .strings)) {
                    if let url = source.settingsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(String(localized: "Check Again", bundle: .strings)) { Task { await model.load() } }
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        case .loaded where model.rows.isEmpty:
            ContentUnavailableView(source.emptyTitle, systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity, minHeight: 240)
        case .loaded:
            List {
                ForEach(model.rows) { row in
                    Toggle(isOn: model.binding(row.path)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).lineLimit(1).truncationMode(.middle)
                                Text(row.detail)
                                    .font(Tokens.Typography.secondary)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Formatters.bytes(row.size))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button(String(localized: "Show in Finder", bundle: .strings)) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 280)
        }
    }
}

/// One move to the Trash, for every cleanup (D-123): only inside the cleanup's own folders, and
/// the `TrashConfirmation` made here, after the person confirmed.
enum CleanupMove {
    private static let log = Logger(subsystem: "app.mactivity.storage", category: "cleanup")

    /// False when the path is outside `scope`, or the move failed.
    static func move(_ path: String, scope: CleanupScope, using trasher: any StorageTrashing) async -> Bool {
        guard scope.allows(path) else {
            log.fault("Refused to move \(path, privacy: .private) to the Trash: outside its cleanup's folders")
            return false
        }
        return await (try? trasher.moveToTrash(TrashConfirmation(path: path, confirmedAt: Date()))) != nil
    }
}
