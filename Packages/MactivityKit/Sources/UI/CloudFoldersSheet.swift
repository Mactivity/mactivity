import AppKit
import Core
import Observation
import Storage
import SwiftUI

/// Cloud folders, sized (1.6): what iCloud Drive, Dropbox, Google Drive, OneDrive and the rest
/// keep on this Mac, and the downloads that can go while the files stay in the cloud.
@MainActor
@Observable
final class CloudFoldersModel {
    enum State: Equatable {
        case idle, loading, loaded
    }

    var isPresented = false
    var confirming = false
    private(set) var state = State.idle
    private(set) var usages: [CloudFolderUsage] = []
    /// Folders Mactivity couldn't read: macOS asks for Full Disk Access for some.
    private(set) var unreadable: [CloudFolder] = []
    var selected: Set<String> = []
    private(set) var isRemoving = false
    var onRemoved: () -> Void = {}

    init() {}

    /// Already measured: render tests.
    init(usages: [CloudFolderUsage]) {
        self.usages = usages
        state = .loaded
    }

    func open() {
        isPresented = true
        Task { await load() }
    }

    /// Each folder's size and downloads, off the main thread.
    func load() async {
        if state == .idle {
            state = .loading
        }
        let iCloudDrive = String(localized: "iCloud Drive", bundle: .strings)
        let (found, failed) = await Task.detached(priority: .utility) { () -> ([CloudFolderUsage], [CloudFolder]) in
            var found: [CloudFolderUsage] = []
            var failed: [CloudFolder] = []
            for folder in CloudFolders.folders(iCloudDrive: iCloudDrive) {
                do throws(ProtectedFolderError) {
                    try found.append(CloudFolders.usage(of: folder, iCloudDrive: iCloudDrive))
                } catch {
                    failed.append(folder)
                }
            }
            return (found, failed)
        }.value
        usages = found
        unreadable = failed
        state = .loaded
        let paths = Set(found.flatMap { $0.downloads.map(\.path) })
        selected = selected.filter(paths.contains)
    }

    /// What the downloads come to, in every folder.
    var removableBytes: UInt64 {
        usages.reduce(0) { $0 + $1.downloads.reduce(0) { $0 + $1.size } }
    }

    var selectedBytes: UInt64 {
        usages.flatMap(\.downloads).filter { selected.contains($0.path) }.reduce(0) { $0 + $1.size }
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

    /// The user confirmed: removes each ticked download. The files stay in the cloud.
    func perform(toast: @escaping (String) -> Void) async {
        guard !isRemoving else {
            return
        }
        isRemoving = true
        let paths = usages.flatMap(\.downloads).map(\.path).filter(selected.contains)
        let bytes = selectedBytes
        let failed = await Task.detached(priority: .userInitiated) {
            paths.reduce(0) { count, path in
                (try? ICloudDownloads.removeCloudDownload(path)) == nil ? count + 1 : count
            }
        }.value
        isRemoving = false
        selected = []
        await load()
        onRemoved()
        let size = Formatters.bytes(bytes)
        toast(failed == 0
            ? String(localized: "Removed \(size) of downloads. The files are still in the cloud.", bundle: .strings)
            : String(localized: "Removed downloads, but some couldn't be removed: \(failed).", bundle: .strings))
    }
}

struct CloudFoldersSheet: View {
    @Bindable var model: CloudFoldersModel
    let toast: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                SymbolBadge(symbol: "icloud.fill", tint: .blue, size: 40)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text("Cloud Folders", bundle: .strings).font(Tokens.Typography.headline)
                    Text(
                        """
                        What each cloud folder keeps on this Mac. Remove a download, as Finder does: the file stays \
                        in the cloud and on your other devices, and downloads again when you open it.
                        """,
                        bundle: .strings
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            content
            HStack {
                if model.isRemoving {
                    ProgressView().controlSize(.small)
                } else if !model.selected.isEmpty {
                    Text("Selected: \(Formatters.bytes(model.selectedBytes))", bundle: .strings)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button(String(localized: "Done", bundle: .strings)) { model.isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Remove Downloads…", bundle: .strings)) { model.confirming = true }
                    .disabled(model.selected.isEmpty || model.isRemoving)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 620)
        .confirmationDialog(
            String(localized: "Remove \(Formatters.bytes(model.selectedBytes)) of downloads from this Mac?", bundle: .strings),
            isPresented: $model.confirming, titleVisibility: .visible
        ) {
            Button(String(localized: "Remove Downloads", bundle: .strings)) {
                Task { await model.perform(toast: toast) }
            }
            Button(String(localized: "Cancel", bundle: .strings), role: .cancel) {}
        } message: {
            Text("The files stay in the cloud and on your other devices, and download again when you open them.", bundle: .strings)
        }
    }

    @ViewBuilder private var content: some View {
        if model.state != .loaded {
            ProgressView().frame(maxWidth: .infinity, minHeight: 280)
        } else if model.usages.isEmpty, model.unreadable.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No cloud folders on this Mac", bundle: .strings), systemImage: "icloud.slash")
            } description: {
                Text("iCloud Drive, Dropbox, Google Drive and OneDrive show up here once they're set up.", bundle: .strings)
            }
            .frame(minHeight: 280)
        } else {
            Form {
                ForEach(model.usages) { usage in
                    section(usage)
                }
                if !model.unreadable.isEmpty {
                    Section {
                        Text(
                            "Mactivity can't read \(model.unreadable.map(\.name).formatted(.list(type: .and))). Full Disk Access lets it.",
                            bundle: .strings
                        )
                        .foregroundStyle(.secondary)
                        Button(String(localized: "Open Privacy & Security…", bundle: .strings)) {
                            if let url = VolumeInfo.fullDiskAccessSettingsURL {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 340)
        }
    }

    private func section(_ usage: CloudFolderUsage) -> some View {
        Section {
            if usage.downloads.isEmpty {
                Text("No downloads of 1 MB or more to remove.", bundle: .strings)
                    .foregroundStyle(.secondary)
            }
            ForEach(usage.downloads) { item in
                Toggle(isOn: model.binding(item.path)) {
                    HStack {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Text(((item.path as NSString).deletingLastPathComponent as NSString).lastPathComponent)
                                .font(Tokens.Typography.secondary)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Formatters.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(usage.folder.name)
                Text("\(Formatters.bytes(usage.localBytes)) on this Mac", bundle: .strings, comment: "Cloud folders: local size")
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                Spacer()
                if !usage.downloads.isEmpty {
                    Button(String(localized: "Select All", bundle: .strings)) {
                        model.selected.formUnion(usage.downloads.map(\.path))
                    }
                    .buttonStyle(.link)
                    .font(Tokens.Typography.secondary)
                }
            }
        }
    }
}
