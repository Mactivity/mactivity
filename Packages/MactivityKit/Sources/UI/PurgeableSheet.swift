import AppKit
import Core
import Observation
import Storage
import SwiftUI

/// Purgeable space (D-125): what it is, and the parts someone can act on sooner than macOS would.
/// iCloud files kept on this Mac can have their downloads removed (they stay in iCloud); local
/// Time Machine snapshots are listed, not deleted; the rest macOS manages itself.
@MainActor
@Observable
final class PurgeableModel {
    enum State: Equatable {
        case idle, loading, loaded, noAccess
    }

    var isPresented = false
    var confirming = false
    private(set) var state = State.idle
    private(set) var downloads: [ICloudDownload] = []
    private(set) var snapshots: [Date] = []
    var selected: Set<String> = []
    private(set) var isRemoving = false
    var onMoved: () -> Void = {}

    init() {}

    /// Already loaded: render tests.
    init(downloads: [ICloudDownload], snapshots: [Date]) {
        self.downloads = downloads
        self.snapshots = snapshots
        state = .loaded
    }

    func open() {
        isPresented = true
        Task { await load() }
    }

    func load() async {
        state = .loading
        let iCloudDrive = String(localized: "iCloud Drive", bundle: .strings)
        let (result, found) = await Task.detached(priority: .userInitiated) {
            () -> (Result<[ICloudDownload], ProtectedFolderError>, [Date]) in
            let snapshots = LocalSnapshots.current()
            do throws(ProtectedFolderError) {
                return try (.success(ICloudDownloads.scan(iCloudDrive: iCloudDrive)), snapshots)
            } catch {
                return (.failure(error), snapshots)
            }
        }.value
        snapshots = found
        switch result {
        case let .success(items):
            downloads = items
            state = .loaded
        case .failure:
            downloads = []
            state = .noAccess
        }
        selected = selected.filter { path in downloads.contains { $0.path == path } }
    }

    var selectedBytes: UInt64 {
        downloads.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.size }
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

    /// The user confirmed: removes each ticked download. The files stay in iCloud.
    func perform(toast: @escaping (String) -> Void) async {
        guard !isRemoving else {
            return
        }
        isRemoving = true
        let paths = downloads.map(\.path).filter(selected.contains)
        let bytes = selectedBytes
        let failed = await Task.detached(priority: .userInitiated) {
            paths.reduce(0) { count, path in
                (try? ICloudDownloads.removeDownload(path)) == nil ? count + 1 : count
            }
        }.value
        isRemoving = false
        selected = []
        await load()
        onMoved()
        let size = Formatters.bytes(bytes)
        toast(failed == 0
            ? String(localized: "Removed \(size) of downloads. The files are still in iCloud.", bundle: .strings)
            : String(localized: "Removed downloads, but some couldn't be removed: \(failed).", bundle: .strings))
    }
}

struct PurgeableSheet: View {
    @Bindable var model: PurgeableModel
    /// The volume's purgeable space, for the heading.
    let purgeable: UInt64?
    let toast: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text("Purgeable Space", bundle: .strings)
                        .font(Tokens.Typography.headline)
                    Text(heading)
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
        .frame(width: 600)
        .confirmationDialog(
            String(localized: "Remove \(Formatters.bytes(model.selectedBytes)) of downloads from this Mac?", bundle: .strings),
            isPresented: $model.confirming, titleVisibility: .visible
        ) {
            Button(String(localized: "Remove Downloads", bundle: .strings)) {
                Task { await model.perform(toast: toast) }
            }
            Button(String(localized: "Cancel", bundle: .strings), role: .cancel) {}
        } message: {
            Text("The files stay in iCloud and on your other devices, and download again when you open them.", bundle: .strings)
        }
    }

    private var heading: String {
        let explanation = String(
            localized: "macOS frees this on its own when it needs room: caches apps marked as purgeable, iCloud copies, and old snapshots.",
            bundle: .strings
        )
        guard let purgeable, purgeable > 0 else {
            return explanation
        }
        return String(localized: "\(Formatters.bytes(purgeable)) purgeable. \(explanation)", bundle: .strings)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        case .noAccess, .loaded:
            List {
                Section {
                    if model.state == .noAccess {
                        Text("Mactivity can't read iCloud's folder. Full Disk Access, in Settings → Privacy, lets it.", bundle: .strings)
                            .foregroundStyle(.secondary)
                        // The way there, as the other cleanups' no-access state has (D-196).
                        HStack {
                            Button(String(localized: "Open Privacy & Security…", bundle: .strings)) {
                                if let url = VolumeInfo.fullDiskAccessSettingsURL {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Button(String(localized: "Check Again", bundle: .strings)) { Task { await model.load() } }
                        }
                    } else if model.downloads.isEmpty {
                        Text("No iCloud downloads of 1 MB or more on this Mac.", bundle: .strings)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.downloads) { item in
                        Toggle(isOn: model.binding(item.path)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).lineLimit(1).truncationMode(.middle)
                                    Text(item.place)
                                        .font(Tokens.Typography.secondary)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Formatters.bytes(item.size))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("iCloud files kept on this Mac", bundle: .strings)
                        Spacer()
                        if !model.downloads.isEmpty {
                            Button(String(localized: "Select All", bundle: .strings)) {
                                model.selected = Set(model.downloads.map(\.path))
                            }
                            .buttonStyle(.link)
                            .font(Tokens.Typography.secondary)
                        }
                    }
                } footer: {
                    Text(
                        "What Finder's iCloud Drive shows. Remove Download, as in Finder: the file stays in iCloud.",
                        bundle: .strings
                    )
                    .foregroundStyle(.secondary)
                }
                Section {
                    if model.snapshots.isEmpty {
                        Text("None on this Mac.", bundle: .strings)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.snapshots, id: \.self) { date in
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .monospacedDigit()
                    }
                } header: {
                    Text("Local Time Machine snapshots", bundle: .strings)
                } footer: {
                    Text("macOS keeps each about a day, and deletes them sooner when it needs the space.", bundle: .strings)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 300)
        }
    }
}
