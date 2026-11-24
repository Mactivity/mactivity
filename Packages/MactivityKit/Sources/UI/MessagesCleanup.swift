import AppKit
import Core
import Observation
import Storage
import SwiftUI

/// Messages attachments (D-116): this Mac's copies of photos, videos and files from Messages,
/// filtered by age, kind and size, moved to the Trash after one confirmation. The messages stay,
/// and so does every other device's copy. Nothing is deleted; everything can be put back.
@MainActor
@Observable
final class MessagesCleanupModel {
    enum State: Equatable {
        case idle, loading, loaded, noAccess, notFound
    }

    var isPresented = false
    var confirming = false
    /// Where moves are allowed from (D-123); a test's folder in tests.
    var scope = CleanupScope.messages()
    /// Called after files were moved, so the Trash and Reclaimable refresh (D-119).
    var onMoved: () -> Void = {}
    private(set) var state = State.idle
    private(set) var all: [MessageAttachment] = []
    /// What the filter picks, largest first; worked out when the filter or the list changes, not
    /// on every redraw.
    private(set) var matching: [MessageAttachment] = []
    private(set) var matchingBytes: UInt64 = 0
    private(set) var moving: (done: Int, total: Int)?
    var filter = MessageAttachmentFilter() {
        didSet { refilter() }
    }

    init() {}

    /// Already loaded: render tests.
    init(loaded attachments: [MessageAttachment]) {
        all = attachments
        state = .loaded
        refilter()
    }

    func open() {
        isPresented = true
        Task { await load() }
    }

    func load() async {
        state = .loading
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[MessageAttachment], MessagesAttachmentsError> in
            do throws(MessagesAttachmentsError) {
                return try .success(MessagesAttachments.scan())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(found):
            all = found
            state = .loaded
        case .failure(.noAccess):
            all = []
            state = .noAccess
        case .failure(.notFound):
            all = []
            state = .notFound
        }
        refilter()
    }

    private func refilter() {
        matching = MessagesAttachments.matching(all, filter, now: Date())
        matchingBytes = matching.reduce(0) { $0 + $1.size }
    }

    var totalBytes: UInt64 {
        all.reduce(0) { $0 + $1.size }
    }

    /// "Move 8.4 GB of attachments to the Trash?"
    var confirmationTitle: String {
        String(
            localized: "Move \(Formatters.bytes(matchingBytes)) of attachments to the Trash?",
            bundle: .strings,
            comment: "Messages cleanup confirmation, e.g. Move 8.4 GB of attachments to the Trash?"
        )
    }

    /// The user confirmed: moves each matching attachment. Creating the `TrashConfirmation`s here,
    /// right after the dialog's Move to Trash, is this flow's confirm step (as in `UninstallModel`).
    func perform(using trasher: any StorageTrashing, toast: @escaping (String) -> Void) async {
        guard moving == nil, !matching.isEmpty else {
            return
        }
        let batch = matching
        var moved = 0
        var movedBytes: UInt64 = 0
        moving = (0, batch.count)
        for (index, attachment) in batch.enumerated() {
            if await CleanupMove.move(attachment.path, scope: scope, using: trasher) {
                moved += 1
                movedBytes += attachment.size
            }
            moving = (index + 1, batch.count)
        }
        moving = nil
        await load()
        onMoved()
        let size = Formatters.bytes(movedBytes)
        toast(moved == batch.count
            ? String(
                localized: "Moved \(size) of attachments to the Trash. Empty the Trash to free the space.",
                bundle: .strings
            )
            : String(
                localized: "Moved \(size) of attachments to the Trash. Couldn't move: \(batch.count - moved).",
                bundle: .strings
            ))
    }
}

struct MessagesCleanupSheet: View {
    @Bindable var model: MessagesCleanupModel
    let trasher: any StorageTrashing
    let toast: (String) -> Void

    private static let shownRows = 300

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                Image(systemName: "message.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text("Messages Attachments", bundle: .strings)
                        .font(Tokens.Typography.headline)
                    Text(
                        """
                        These are this Mac's copies of photos, videos and files from Messages. Moving them to the Trash \
                        leaves the messages alone, and everything on your iPhone.
                        """,
                        bundle: .strings
                    )
                    .foregroundStyle(.secondary)
                    Text(
                        """
                        With Messages in iCloud, Messages may download one again when you open its conversation. Without it, \
                        this Mac's copy may be the only one: check before you empty the Trash.
                        """,
                        bundle: .strings
                    )
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            content
            footer
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 640)
        .confirmationDialog(model.confirmationTitle, isPresented: $model.confirming, titleVisibility: .visible) {
            Button(String(localized: "Move to Trash", bundle: .strings), role: .destructive) {
                Task { await model.perform(using: trasher, toast: toast) }
            }
            Button(String(localized: "Cancel", bundle: .strings), role: .cancel) {}
        } message: {
            Text("The messages stay, and so does everything on your iPhone. The space is freed when you empty the Trash.", bundle: .strings)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 280)
        case .noAccess:
            ContentUnavailableView {
                Label(String(localized: "Mactivity needs Full Disk Access", bundle: .strings), systemImage: "lock")
            } description: {
                Text(
                    "macOS protects Messages' folder. Turn on Mactivity in Privacy & Security → Full Disk Access, then check again.",
                    bundle: .strings
                )
            } actions: {
                Button(String(localized: "Open Privacy & Security…", bundle: .strings)) {
                    if let url = VolumeInfo.fullDiskAccessSettingsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(String(localized: "Check Again", bundle: .strings)) { Task { await model.load() } }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        case .notFound:
            ContentUnavailableView(
                String(localized: "No Messages attachments on this Mac", bundle: .strings),
                systemImage: "message"
            )
            .frame(maxWidth: .infinity, minHeight: 280)
        case .loaded:
            loaded
        }
    }

    private var loaded: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(Self.summary(model.all, total: model.totalBytes))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack(spacing: Tokens.Spacing.m) {
                Picker(
                    String(localized: "Age", bundle: .strings, comment: "Messages cleanup: how old"),
                    selection: $model.filter.olderThanDays
                ) {
                    Text("Any age", bundle: .strings).tag(Int?.none)
                    ForEach([30, 182, 365, 730], id: \.self) { days in
                        Text(Self.ageTitle(days)).tag(Int?.some(days))
                    }
                }
                Picker(String(localized: "Kind", bundle: .strings), selection: $model.filter.kind) {
                    Text("All kinds", bundle: .strings).tag(MessageAttachment.Kind?.none)
                    ForEach(MessageAttachment.Kind.allCases, id: \.self) { kind in
                        Text(Self.kindTitle(kind)).tag(MessageAttachment.Kind?.some(kind))
                    }
                }
                Picker(String(localized: "Size", bundle: .strings), selection: $model.filter.minimumBytes) {
                    Text("Any size", bundle: .strings).tag(UInt64(0))
                    ForEach([UInt64(1_000_000), 10_000_000, 100_000_000], id: \.self) { bytes in
                        Text("\(Formatters.bytes(bytes)) or more", bundle: .strings, comment: "Messages cleanup: minimum size")
                            .tag(bytes)
                    }
                }
            }
            .fixedSize()
            Table(Array(model.matching.prefix(Self.shownRows))) {
                TableColumn(String(localized: "Name", bundle: .strings)) { attachment in
                    Text(attachment.name).lineLimit(1).truncationMode(.middle)
                }
                TableColumn(String(localized: "Kind", bundle: .strings)) { attachment in
                    Text(Self.rowKind(attachment.kind)).foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn(String(localized: "Received", bundle: .strings, comment: "Messages cleanup column: when")) { attachment in
                    Text(attachment.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                }
                .width(110)
                TableColumn(String(localized: "Size", bundle: .strings)) { attachment in
                    Text(Formatters.bytes(attachment.size)).monospacedDigit()
                }
                .width(80)
                .alignment(.numeric)
            }
            .frame(minHeight: 260)
            .contextMenu(forSelectionType: MessageAttachment.ID.self) { ids in
                if let id = ids.first {
                    Button(String(localized: "Show in Finder", bundle: .strings)) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)])
                    }
                }
            }
            if model.matching.count > Self.shownRows {
                Text("Showing the largest \(Self.shownRows). All \(model.matching.count) that match are moved.", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let moving = model.moving {
                ProgressView(value: Double(moving.done), total: Double(max(1, moving.total)))
                    .frame(width: 200)
            } else if model.state == .loaded {
                Text("Matching: \(model.matching.count) · \(Formatters.bytes(model.matchingBytes))", bundle: .strings)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button(String(localized: "Done", bundle: .strings)) { model.isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Move to Trash…", bundle: .strings), role: .destructive) { model.confirming = true }
                .disabled(model.matching.isEmpty || model.moving != nil)
        }
    }

    /// "Attachments on this Mac: 12,345 · 8.4 GB · Photos 5.2 GB · Videos 2.9 GB".
    nonisolated static func summary(_ all: [MessageAttachment], total: UInt64) -> String {
        let totals = MessagesAttachments.totals(all)
        let kinds = MessageAttachment.Kind.allCases
            .compactMap { kind in totals[kind].map { (kind, $0.bytes) } }
            .sorted { $0.1 > $1.1 }
            .map { "\(kindTitle($0.0)) \(Formatters.bytes($0.1))" }
        let head = String(
            // A dot, not a comma: "9, 999 MB" read as one number.
            localized: "Attachments on this Mac: \(all.count) · \(Formatters.bytes(total))",
            bundle: .strings, comment: "Messages cleanup summary"
        )
        return ([head] + kinds).joined(separator: " · ")
    }

    nonisolated static func ageTitle(_ days: Int) -> String {
        switch days {
        case 30: String(localized: "Older than 30 days", bundle: .strings)
        case 182: String(localized: "Older than 6 months", bundle: .strings)
        case 365: String(localized: "Older than a year", bundle: .strings)
        default: String(localized: "Older than 2 years", bundle: .strings)
        }
    }

    /// One file's kind, in the table: "Video", where the filter says "Videos".
    nonisolated static func rowKind(_ kind: MessageAttachment.Kind) -> String {
        switch kind {
        case .photo: String(localized: "Photo", bundle: .strings, comment: "Messages cleanup: one attachment's kind")
        case .video: String(localized: "Video", bundle: .strings, comment: "Messages cleanup: one attachment's kind")
        case .audio: String(localized: "Audio", bundle: .strings)
        case .document: String(localized: "Document", bundle: .strings, comment: "Messages cleanup: one attachment's kind")
        case .other: String(localized: "Other", bundle: .strings)
        }
    }

    nonisolated static func kindTitle(_ kind: MessageAttachment.Kind) -> String {
        switch kind {
        case .photo: String(localized: "Photos", bundle: .strings)
        case .video: String(localized: "Videos", bundle: .strings)
        case .audio: String(localized: "Audio", bundle: .strings)
        case .document: String(localized: "Documents", bundle: .strings)
        case .other: String(localized: "Other", bundle: .strings)
        }
    }
}
