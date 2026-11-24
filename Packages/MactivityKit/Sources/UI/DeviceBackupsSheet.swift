import AppKit
import Core
import Observation
import Storage
import SwiftUI

/// iPhone and iPad backups (D-117): Finder's backups of your devices and the software updates it
/// downloaded for them, moved to the Trash after one confirmation. A backup may be the only copy
/// of a device you no longer have, so none starts ticked; updates download again when needed,
/// so they do.
@MainActor
@Observable
final class DeviceBackupsModel {
    enum State: Equatable {
        case idle, loading, loaded, noAccess
    }

    var isPresented = false
    var confirming = false
    /// Where moves are allowed from (D-123); a test's folder in tests.
    var scope = CleanupScope.backups()
    /// Called after files were moved, so the Trash and Reclaimable refresh (D-119).
    var onMoved: () -> Void = {}
    private(set) var state = State.idle
    private(set) var scan = DeviceBackupsScan(backups: [], updates: [])
    var selected: Set<String> = []
    private(set) var isMoving = false

    init() {}

    /// Already loaded: render tests.
    init(loaded scan: DeviceBackupsScan) {
        self.scan = scan
        state = .loaded
        selected = Set(scan.updates.map(\.path))
    }

    func open() {
        isPresented = true
        Task { await load() }
    }

    func load() async {
        state = .loading
        let result = await Task.detached(priority: .userInitiated) { () -> Result<DeviceBackupsScan, ProtectedFolderError> in
            do throws(ProtectedFolderError) {
                return try .success(DeviceBackups.scan())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(found):
            scan = found
            selected = Set(found.updates.map(\.path))
            state = .loaded
        case .failure:
            scan = DeviceBackupsScan(backups: [], updates: [])
            selected = []
            state = .noAccess
        }
    }

    var selectedBytes: UInt64 {
        scan.backups.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.size }
            + scan.updates.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.size }
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

    /// The user confirmed: moves each ticked item. The `TrashConfirmation`s made here are this
    /// flow's confirm step (as in `UninstallModel`).
    func perform(using trasher: any StorageTrashing, toast: @escaping (String) -> Void) async {
        guard !isMoving else {
            return
        }
        isMoving = true
        let paths = scan.backups.map(\.path).filter(selected.contains) + scan.updates.map(\.path).filter(selected.contains)
        let bytes = selectedBytes
        var failed = 0
        for path in paths where await !CleanupMove.move(path, scope: scope, using: trasher) {
            failed += 1
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

struct DeviceBackupsSheet: View {
    @Bindable var model: DeviceBackupsModel
    let trasher: any StorageTrashing
    let toast: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                Image(systemName: "iphone.gen3")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text("iPhone and iPad Backups", bundle: .strings)
                        .font(Tokens.Typography.headline)
                    Text(
                        """
                        Backups Finder made of your devices: the same list as Finder's Manage Backups. A backup may be \
                        the only copy of a device you no longer have, so none is ticked until you tick it.
                        """,
                        bundle: .strings
                    )
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
            Text("A backup in the Trash can still be put back. Once the Trash is emptied, it's gone.", bundle: .strings)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        case .noAccess:
            ContentUnavailableView {
                Label(String(localized: "Mactivity needs Full Disk Access", bundle: .strings), systemImage: "lock")
            } description: {
                Text(
                    "macOS protects the backups folder. Turn on Mactivity in Privacy & Security → Full Disk Access, then check again.",
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
            .frame(maxWidth: .infinity, minHeight: 240)
        case .loaded:
            List {
                Section(String(localized: "Backups", bundle: .strings)) {
                    if model.scan.backups.isEmpty {
                        Text("No iPhone or iPad backups on this Mac.", bundle: .strings)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.scan.backups) { backup in
                        Toggle(isOn: model.binding(backup.path)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(backup.deviceName)
                                    Text(Self.details(backup))
                                        .font(Tokens.Typography.secondary)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Formatters.bytes(backup.size))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !model.scan.updates.isEmpty {
                    Section {
                        ForEach(model.scan.updates) { update in
                            Toggle(isOn: model.binding(update.path)) {
                                HStack {
                                    Text(update.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Formatters.bytes(update.size))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Downloaded software updates", bundle: .strings)
                    } footer: {
                        Text("Finder downloads an update again when a device needs it.", bundle: .strings)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 260)
        }
    }

    /// "iPhone 15 Pro · iOS 18.1 · Mar 2, 2024 · Encrypted".
    nonisolated static func details(_ backup: DeviceBackup) -> String {
        var parts: [String] = []
        if let product = backup.productName {
            parts.append(product)
        }
        if let version = backup.systemVersion {
            let system = (backup.productName ?? backup.deviceName).hasPrefix("iPad") ? "iPadOS" : "iOS"
            parts.append("\(system) \(version)")
        }
        if let date = backup.date {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if backup.isEncrypted {
            parts.append(String(localized: "Encrypted", bundle: .strings, comment: "An encrypted device backup"))
        }
        return parts.joined(separator: " · ")
    }
}
