import Core
import Simulated
import Storage
import SwiftUI

/// The Storage tab (expansion E10): a sunburst map of a folder or the startup disk, with
/// categories, a Developer lens, and the largest files. It shows; it doesn't clean (spec 3).
/// Items go to the Trash only through the confirm step, never anywhere else.
public struct StorageView: View {
    /// Owned by `AppServices`, so a scan survives switching tabs.
    private let model: StorageModel
    /// Kept for wiring parity with the other tabs. Trash has its own confirm step
    /// (`StorageTrashConfirmation`) because `ConfirmedAction` carries processes, not files.
    private let confirmedAction: ConfirmedAction
    @State private var cleanups = StorageCleanups()
    /// For Checkup's links into a cleanup (D-196); none in previews.
    private let navigation: AppNavigation?
    /// Apps history has seen, for Old Versions and Leftovers (D-282).
    private let recordedApps: (any RecordedAppsStore)?
    /// What the Photos library takes (D-283); none in previews.
    private let photos: PhotosLibraryModel?

    init(
        model: StorageModel, confirmedAction: ConfirmedAction, navigation: AppNavigation? = nil,
        recordedApps: (any RecordedAppsStore)? = nil, photos: PhotosLibraryModel? = nil
    ) {
        self.model = model
        self.confirmedAction = confirmedAction
        self.navigation = navigation
        self.recordedApps = recordedApps
        self.photos = photos
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            if model.access == .denied {
                FullDiskAccessExplainer(model: model)
            }
            StorageVolumeCard(model: model, cleanups: cleanups)
            ReclaimableCard(cleanups: cleanups)
            if let photos {
                PhotosLibraryCard(model: photos)
            }
            content
        }
        .padding(Tokens.Spacing.l)
        // Exactly the window's height: if the page ever needs more (the cleanups card open in a
        // minimum-size window), the bottom runs off, rather than the page sliding up under the
        // toolbar and the window growing (D-172).
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Checkup's Show for old Messages attachments or backups opens that cleanup (D-196).
        .onChange(of: navigation?.storageCleanup, initial: true) { _, target in
            switch target {
            case .messages: cleanups.messages.open()
            case .backups: cleanups.backups.open()
            case nil: return
            }
            navigation?.storageCleanup = nil
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(text: toast)
            }
        }
        .animation(Tokens.Motion.figure, value: model.toast)
        .storageTrashDialog(model.trashStep, trasher: model.trasher)
        .sheet(isPresented: Binding(get: { cleanups.uninstall.plan != nil }, set: {
            if !$0 {
                cleanups.uninstall.dismiss()
            }
        })) {
            UninstallSheet(model: cleanups.uninstall, trasher: model.trasher) { model.show(toast: $0) }
        }
        .sheet(isPresented: Bindable(cleanups.messages).isPresented) {
            MessagesCleanupSheet(model: cleanups.messages, trasher: model.trasher) { model.show(toast: $0) }
        }
        .sheet(isPresented: Bindable(cleanups.backups).isPresented) {
            DeviceBackupsSheet(model: cleanups.backups, trasher: model.trasher) { model.show(toast: $0) }
        }
        .sheet(isPresented: Bindable(cleanups.downloads).isPresented) {
            FileCleanupSheet(model: cleanups.downloads, trasher: model.trasher) { model.show(toast: $0) }
        }
        .sheet(isPresented: Bindable(cleanups.unopened).isPresented) {
            FileCleanupSheet(model: cleanups.unopened, trasher: model.trasher) { model.show(toast: $0) }
        }
        .sheet(isPresented: Bindable(cleanups.mail).isPresented) {
            FileCleanupSheet(model: cleanups.mail, trasher: model.trasher) { model.show(toast: $0) }
        }
        .sheet(isPresented: Bindable(cleanups.developer).isPresented) {
            FileCleanupSheet(model: cleanups.developer, trasher: model.trasher) { model.show(toast: $0) }
        }
        .sheet(isPresented: Bindable(cleanups.screenshots).isPresented) {
            FileCleanupSheet(model: cleanups.screenshots, trasher: model.trasher) { model.show(toast: $0) }
        }
        .sheet(isPresented: Bindable(cleanups.forgotten).isPresented) {
            FileCleanupSheet(model: cleanups.forgotten, trasher: model.trasher) { model.show(toast: $0) }
        }
        .sheet(isPresented: Bindable(cleanups.duplicates).isPresented) {
            FileCleanupSheet(model: cleanups.duplicates, trasher: model.trasher) { model.show(toast: $0) }
        }
        .sheet(isPresented: Bindable(cleanups.oldApps).isPresented) {
            FileCleanupSheet(model: cleanups.oldApps, trasher: model.trasher) { model.show(toast: $0) }
        }
        .sheet(isPresented: Bindable(cleanups.cloud).isPresented) {
            CloudFoldersSheet(model: cleanups.cloud) { model.show(toast: $0) }
        }
        .sheet(isPresented: Bindable(cleanups.purgeable).isPresented) {
            PurgeableSheet(model: cleanups.purgeable, purgeable: model.volume?.purgeable) { model.show(toast: $0) }
        }
        .task { await cleanups.refresh() }
        .task { cleanups.recordedApps.value = await (try? recordedApps?.recordedApps()) ?? [] }
        .alert(
            cleanups.uninstall.problem ?? "",
            isPresented: Binding(get: { cleanups.uninstall.problem != nil }, set: {
                if !$0 {
                    cleanups.uninstall.clearProblem()
                }
            })
        ) {
            Button(String(localized: "OK", bundle: .strings)) {}
        }
        .onAppear {
            model.appeared()
            // The website's screenshots (scripts/site-shots.sh) show a map, not the empty state. The
            // script always pairs this hook with simulated data, whose scanner makes one up.
            if LaunchOverrides.isScreenshotMode, model.scan == nil, model.phase == .idle {
                model.start(.home)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let scan = model.scan {
            StorageResults(model: model, scan: scan)
        } else {
            switch model.phase {
            case .scanning:
                ContentUnavailableView {
                    Label(scanningTitle, systemImage: "chart.pie")
                } description: {
                    Text("Folders appear here as soon as the scan finishes.", bundle: .strings)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label(String(localized: "Couldn't scan", bundle: .strings), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(String(localized: "Try Again", bundle: .strings)) { model.start() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .idle:
                ContentUnavailableView {
                    Label(String(localized: "See what's using your disk", bundle: .strings), systemImage: "chart.pie")
                } description: {
                    Text(
                        "Scan your home folder to map every folder by size, see what's safe to rebuild, and find the largest files.",
                        bundle: .strings
                    )
                } actions: {
                    Button(String(localized: "Scan Home Folder", bundle: .strings)) { model.start(.home) }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// "Mapping your home folder…", one sentence per target so each translates whole.
    private var scanningTitle: String {
        let name: String
        switch model.target {
        case .home:
            return String(localized: "Mapping your home folder…", bundle: .strings)
        case .startupDisk:
            guard let volume = model.volume?.name else {
                return String(localized: "Mapping the startup disk…", bundle: .strings)
            }
            name = volume
        case let .folder(url):
            name = url.lastPathComponent
        }
        return String(localized: "Mapping \(name)…", bundle: .strings, comment: "Storage scan in progress; a volume's or folder's name")
    }
}

/// Tabs and their content once a scan exists.
struct StorageResults: View {
    let model: StorageModel
    let scan: StorageScan

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            Text(summary)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            if let growth = model.growth {
                FolderGrowthLine(since: growth.since, folders: growth.folders) { folder in
                    if let node = scan.root.node(atPath: folder.path) {
                        model.tab = .map
                        model.zoom(to: node)
                    }
                }
            }
            switch model.tab {
            case .map:
                StorageMapTab(model: model, scan: scan)
            case .categories:
                StorageCategoriesTab(model: model, scan: scan)
            case .developer:
                DeveloperLensTab(model: model)
            case .largest:
                LargestFilesTab(model: model, scan: scan)
            }
        }
        // Switching views is navigation, so it lives in the toolbar, and only while a scan
        // exists to switch between.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(
                    String(localized: "View", bundle: .strings, comment: "Storage tab picker: how the scan is shown (map or lists)"),
                    selection: Binding(get: { model.tab }, set: { model.tab = $0 })
                ) {
                    ForEach(StorageModel.Tab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(Text("Storage view", bundle: .strings))
            }
        }
    }

    private var summary: String {
        let place = StorageText.place(scan.root.path, home: scan.home)
        let size = Formatters.bytes(scan.root.size)
        let scanned = String(
            localized: "scanned in \(StorageText.duration(scan.duration))",
            bundle: .strings,
            comment: "Storage summary segment: how long the scan took"
        )
        return [place, size, StorageText.files(scan.fileCount), scanned].joined(separator: " · ")
    }
}

#Preview("Storage") {
    let scanner = SimulatedStorageScanner(fullDiskAccess: .denied)
    let model = StorageModel(scanner: scanner)
    model.finish(scanner.makeScan())
    return StorageView(model: model, confirmedAction: ConfirmedAction(terminator: SimulatedDevServers()))
        .frame(width: 960, height: 760)
}
