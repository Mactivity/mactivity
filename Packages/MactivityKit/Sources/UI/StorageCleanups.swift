import AppKit
import Core
import Observation
import Storage
import SwiftUI

/// Storage's cleanups (D-104, D-116 to D-119) and what they could give back, in one place: the
/// Clean Up menu opens their sheets, the Reclaimable card totals them, and any move refreshes the
/// totals and the Trash.
@MainActor
@Observable
final class StorageCleanups {
    let uninstall = UninstallModel()
    let messages = MessagesCleanupModel()
    let backups = DeviceBackupsModel()
    let downloads = FileCleanupModel(.downloads)
    let unopened = FileCleanupModel(.unopened)
    let mail = FileCleanupModel(.mail)
    let developer = FileCleanupModel(.developer)
    let screenshots = FileCleanupModel(.screenshots)
    let forgotten = FileCleanupModel(.forgotten)
    let duplicates = FileCleanupModel(.duplicates)
    let recordedApps = RecordedAppsBox()
    let oldApps: FileCleanupModel
    let purgeable = PurgeableModel()
    let cloud = CloudFoldersModel()
    private(set) var reclaimable: Reclaimable?

    /// Already measured: render tests.
    convenience init(measured value: Reclaimable) {
        self.init()
        reclaimable = value
    }

    init() {
        oldApps = FileCleanupModel(.oldApps(recorded: recordedApps))
        let refresh: () -> Void = { [weak self] in
            CleanupSummary.invalidate()
            Task { await self?.refresh() }
        }
        uninstall.onMoved = refresh
        messages.onMoved = refresh
        backups.onMoved = refresh
        downloads.onMoved = refresh
        unopened.onMoved = refresh
        mail.onMoved = refresh
        developer.onMoved = refresh
        screenshots.onMoved = refresh
        forgotten.onMoved = refresh
        duplicates.onMoved = refresh
        oldApps.onMoved = refresh
        purgeable.onMoved = refresh
        cloud.onRemoved = refresh
    }

    /// Ten minutes old at most while Storage shows: fresher than Checkup needs, since this is
    /// where someone acts on it.
    func refresh() async {
        // The website's screenshots and the demo video run in an empty home folder.
        if LaunchOverrides.isScreenshotMode {
            reclaimable = Self.sample
            return
        }
        reclaimable = await CleanupSummary.current(maxAge: 600)
        await cloud.load()
    }

    /// Made-up figures for screenshot mode, the same as the website demo's.
    static let sample = Reclaimable(
        messages: 897_000_000, backups: Reclaimable.Backups(bytes: 23_000_000_000, oldest: Date().addingTimeInterval(-700 * 86400)),
        downloads: 12_000_000_000, mail: 458_000_000, developer: 6_400_000_000, screenshots: 3_300_000_000, trash: 14_000_000_000
    )
}

/// "Space you can get back: 24 GB", a line per cleanup with Review…, and the Trash (D-119).
/// Nothing shows until there's something to say; without Full Disk Access, Storage's own
/// explainer covers it.
struct ReclaimableCard: View {
    let cleanups: StorageCleanups
    /// Collapsed, one line: the minimum window leaves the storage map little room under a
    /// six-line card (D-121). Remembered, so someone who opens it keeps it open.
    @AppStorage(PreferenceKey.reclaimableExpanded) private var expanded = false

    var body: some View {
        let cloud = cleanups.cloud.removableBytes
        if let value = cleanups.reclaimable, value.total > 0 || (value.trash ?? 0) > 0 || cloud > 0 {
            DisclosureGroup(isExpanded: $expanded) {
                // Up to four rows in full; more scroll inside the card, about four rows tall, so the
                // storage map keeps its room in the minimum window.
                Group {
                    if Self.lines(value).count + ((value.trash ?? 0) > 0 ? 1 : 0) + (cloud > 0 ? 1 : 0) > 4 {
                        ScrollView { details(value) }
                            .frame(height: 116)
                    } else {
                        details(value)
                    }
                }
                .padding(.top, Tokens.Spacing.xs)
            } label: {
                Text(Self.summary(value, cloud: cloud))
                    .font(Tokens.Typography.cardTitle)
                    .monospacedDigit()
            }
            .cardStyle()
        }
    }

    private func details(_ value: Reclaimable) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            ForEach(Self.lines(value), id: \.kind) { line in
                HStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: line.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: Tokens.IconSize.row)
                    Text(Self.title(line.kind))
                    Spacer()
                    Text(Formatters.bytes(line.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Review…", bundle: .strings, comment: "Opens a cleanup sheet")) { open(line.kind) }
                        .controlSize(.small)
                }
            }
            // Downloads in cloud folders (1.6): they go, the files stay in the cloud.
            if cleanups.cloud.removableBytes >= 50_000_000 {
                HStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: "icloud")
                        .foregroundStyle(.secondary)
                        .frame(width: Tokens.IconSize.row)
                    Text("Downloads in cloud folders, kept in the cloud", bundle: .strings)
                    Spacer()
                    Text(Formatters.bytes(cleanups.cloud.removableBytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Review…", bundle: .strings, comment: "Opens a cleanup sheet")) { cleanups.cloud.open() }
                        .controlSize(.small)
                }
            }
            if let trash = value.trash, trash > 0 {
                if value.total > 0 || cleanups.cloud.removableBytes > 0 {
                    Divider()
                }
                HStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                        .frame(width: Tokens.IconSize.row)
                    Text("Still using the space until the Trash is emptied.", bundle: .strings)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(String(localized: "Open Trash", bundle: .strings)) {
                        NSWorkspace.shared.open(TrashFolder.folder())
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    /// "Space you can get back: 43 GB · In the Trash: 14 GB". Cloud downloads count: removing
    /// them frees the space as surely as the Trash does.
    nonisolated static func summary(_ value: Reclaimable, cloud: UInt64 = 0) -> String {
        var parts: [String] = []
        let total = value.total + (cloud >= 50_000_000 ? cloud : 0)
        if total > 0 {
            parts.append(String(localized: "Space you can get back: \(Formatters.bytes(total))", bundle: .strings))
        }
        if let trash = value.trash, trash > 0 {
            parts.append(String(localized: "In the Trash: \(Formatters.bytes(trash))", bundle: .strings))
        }
        return parts.joined(separator: " · ")
    }

    enum Kind: Hashable {
        case messages, backups, downloads, mail, developer, screenshots
    }

    struct Line: Hashable {
        let kind: Kind
        let bytes: UInt64
        let symbol: String
    }

    /// Pure: the lines worth showing, largest first.
    nonisolated static func lines(_ value: Reclaimable) -> [Line] {
        [
            Line(kind: .messages, bytes: value.messages ?? 0, symbol: "message"),
            Line(kind: .backups, bytes: value.backups?.bytes ?? 0, symbol: "iphone.gen3"),
            Line(kind: .downloads, bytes: value.downloads ?? 0, symbol: "arrow.down.circle"),
            Line(kind: .mail, bytes: value.mail ?? 0, symbol: "envelope"),
            Line(kind: .developer, bytes: value.developer ?? 0, symbol: "hammer"),
            Line(kind: .screenshots, bytes: value.screenshots ?? 0, symbol: "camera.viewfinder"),
        ]
        .filter { $0.bytes >= 50_000_000 }
        .sorted { $0.bytes > $1.bytes }
    }

    nonisolated static func title(_ kind: Kind) -> String {
        switch kind {
        case .messages: String(localized: "Messages attachments older than a year", bundle: .strings)
        case .backups: String(localized: "iPhone and iPad backups older than six months", bundle: .strings)
        case .downloads: String(localized: "Installers and archives in Downloads", bundle: .strings)
        case .mail: String(localized: "Mail downloads older than 30 days", bundle: .strings)
        case .developer: String(localized: "Developer caches that rebuild themselves", bundle: .strings)
        case .screenshots: String(localized: "Screenshots and recordings over 30 days old", bundle: .strings)
        }
    }

    private func open(_ kind: Kind) {
        switch kind {
        case .messages: cleanups.messages.open()
        case .backups: cleanups.backups.open()
        case .downloads: cleanups.downloads.open()
        case .mail: cleanups.mail.open()
        case .developer: cleanups.developer.open()
        case .screenshots: cleanups.screenshots.open()
        }
    }
}
