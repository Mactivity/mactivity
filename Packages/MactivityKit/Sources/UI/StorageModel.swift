import AppKit
import Core
import Foundation
import Observation
import os
import Storage

/// State behind the Storage tab: the volume, the running or finished scan, where the map is
/// zoomed, the Developer lens, and the Move to Trash flow.
@MainActor
@Observable
final class StorageModel {
    enum Tab: String, CaseIterable, Identifiable {
        case map, categories, developer, largest

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .map: String(localized: "Map", bundle: .strings, comment: "Storage view: the sunburst map")
            case .categories: String(localized: "Categories", bundle: .strings, comment: "Storage view: space by file category")
            case .developer: String(localized: "Developer", bundle: .strings, comment: "Storage view: rebuildable developer data")
            case .largest: String(localized: "Largest Files", bundle: .strings)
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case scanning(StorageScanProgress?)
        case failed(String)
    }

    /// What a scan starts from.
    enum Target: Equatable {
        case home
        case startupDisk
        case folder(URL)
    }

    private static let log = Logger(subsystem: "app.mactivity.storage", category: "view")

    let scanner: any StorageScanning
    let trasher: any StorageTrashing
    let trashStep = StorageTrashConfirmation()

    private(set) var volume: VolumeSummary?
    private(set) var access: FullDiskAccessStatus = .unknown
    private(set) var phase: Phase = .idle
    private(set) var scan: StorageScan?
    private(set) var target: Target = .home
    private(set) var developerItems: [DeveloperItem] = []
    private(set) var isLoadingLens = false
    /// The folder the map and the list show; the scan root when nil.
    private(set) var focusPath: String?
    /// Sunburst segments for the focus, laid out once per zoom.
    private(set) var segments: [SunburstSegment] = []
    private(set) var toast: String?
    /// What grew since the last scan of the same place (D-208); nil the first time, or after a
    /// simulated scan.
    private(set) var growth: (since: Date, folders: [FolderGrowth])?
    /// Time Machine's last backup (D-216), read when the tab appears.
    private(set) var timeMachine: TimeMachineStatus?
    var tab: Tab = .map
    /// The sunburst slice under the pointer.
    var hovered: SunburstSegment?
    /// The selected row (its node ID) in the map's list or the Largest Files table: what ⌘⌫ and
    /// the space bar act on.
    var selectedID: String?
    /// The file Quick Look shows; nil while it's closed.
    var quickLookURL: URL?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(scanner: any StorageScanning) {
        self.scanner = scanner
        trasher = scanner.trasher
    }

    var home: String {
        scanner.home.path
    }

    var isScanning: Bool {
        if case .scanning = phase {
            return true
        }
        return false
    }

    var focus: StorageNode? {
        guard let scan else {
            return nil
        }
        guard let focusPath else {
            return scan.root
        }
        return scan.root.node(atPath: focusPath) ?? scan.root
    }

    /// Scan root first, focus last.
    /// Ring-1 color index of each child of the focus that has its own slice.
    var branchOfChild: [String: Int] {
        var branches: [String: Int] = [:]
        for segment in segments where segment.ring == 1 {
            if let node = segment.node {
                branches[node.id] = segment.branch
            }
        }
        return branches
    }

    var breadcrumb: [StorageNode] {
        guard let scan, let focus else {
            return []
        }
        var trail: [StorageNode] = [scan.root]
        var node = scan.root
        while node !== focus, let next = node.children.first(where: {
            $0.isDirectory && (focus.path == $0.path || focus.path.hasPrefix($0.path + "/"))
        }) {
            trail.append(next)
            node = next
        }
        return trail
    }

    func appeared() {
        volume = scanner.volumeSummary(for: URL(fileURLWithPath: "/"))
        access = scanner.fullDiskAccess()
        timeMachine = scanner.timeMachine()
    }

    // MARK: Scanning

    func start(_ target: Target? = nil) {
        if let target {
            self.target = target
        }
        let root: URL = switch self.target {
        case .home: scanner.home
        case .startupDisk: URL(fileURLWithPath: "/")
        case let .folder(url): url
        }
        scanTask?.cancel()
        phase = .scanning(nil)
        access = scanner.fullDiskAccess()
        let scanner = scanner
        scanTask = Task { [weak self] in
            do {
                for try await event in scanner.scan(root) {
                    guard let self else {
                        return
                    }
                    switch event {
                    case let .progress(progress):
                        phase = .scanning(progress)
                    case let .finished(result):
                        finish(result)
                        compareWithLastScan(result)
                    }
                }
            } catch is CancellationError {
                self?.phase = .idle
            } catch StorageScanError.cancelled {
                self?.phase = .idle
            } catch {
                Self.log.error("Scan failed: \(String(describing: error))")
                self?.phase = .failed(Self.describe(error))
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        phase = .idle
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Scan", bundle: .strings, comment: "Button: starts a storage scan")
        panel.message = String(localized: "Choose a folder or a volume to map.", bundle: .strings)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        start(.folder(url))
    }

    /// Shows a finished scan. Used by `start` and by previews and renders.
    func finish(_ result: StorageScan) {
        growth = nil
        scan = result
        phase = .idle
        focusPath = nil
        volume = scanner.volumeSummary(for: URL(fileURLWithPath: result.root.path))
        relayout()
        loadLens()
    }

    private func loadLens() {
        isLoadingLens = true
        let scanner = scanner
        let scan = scan
        Task { [weak self] in
            let items = await scanner.developerLens(for: scan)
            self?.developerItems = items
            self?.isLoadingLens = false
        }
    }

    private static func describe(_ error: any Error) -> String {
        if case let StorageScanError.unreadableRoot(path, code) = error {
            let name = (path as NSString).lastPathComponent
            return code == EPERM || code == EACCES
                ? String(localized: "Mactivity can't read \(name). Full Disk Access may be off.", bundle: .strings)
                : String(
                    localized: "Couldn't open \(name) (\(String(cString: strerror(code)))).",
                    bundle: .strings,
                    comment: "Scan error: the folder's name, then the system's error description"
                )
        }
        return error.localizedDescription
    }

    // MARK: Zoom

    func zoom(to node: StorageNode) {
        guard node.isDirectory, !node.children.isEmpty else {
            return
        }
        focusPath = node.path == scan?.root.path ? nil : node.path
        relayout()
    }

    func zoomOut() {
        let trail = breadcrumb
        guard trail.count > 1 else {
            return
        }
        zoom(to: trail[trail.count - 2])
    }

    private func relayout() {
        hovered = nil
        segments = focus.map {
            SunburstLayout.segments(for: $0, rings: StorageTokens.Sunburst.rings, minimumAngle: StorageTokens.Sunburst.minimumAngle)
        } ?? []
    }

    // MARK: Finder and Trash

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    func openFullDiskAccessSettings() {
        if let url = VolumeInfo.fullDiskAccessSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// The selected row among the rows a list shows, when it's still there.
    func selectedNode(in rows: [StorageNode]) -> StorageNode? {
        guard let selectedID else {
            return nil
        }
        return rows.first { $0.id == selectedID }
    }

    /// ⌘⌫: asks to move the selected row to the Trash, through the same confirmation as the menu
    /// item. Nothing moves until the person confirms.
    func trashSelection(in rows: [StorageNode]) {
        guard let node = selectedNode(in: rows), node.isItem else {
            return
        }
        askToTrash(path: node.path, name: node.name, size: node.size)
    }

    /// Space: Quick Look the selected row, or else the one under the pointer. Space again closes it.
    func toggleQuickLook(in rows: [StorageNode], hovered: StorageNode? = nil) {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        guard let node = selectedNode(in: rows) ?? hovered, node.isItem else {
            return
        }
        quickLookURL = URL(fileURLWithPath: node.path)
    }

    /// Asks to move an item to the Trash. Only the confirm step moves it.
    func askToTrash(path: String, name: String, size: UInt64, note: String? = nil) {
        trashStep.ask(path: path, name: name, size: size, note: note) { [weak self] result in
            self?.trashFinished(path: path, name: name, result: result)
        }
    }

    private func trashFinished(path: String, name: String, result: Result<URL?, any Error>) {
        switch result {
        case .success:
            if let scan {
                self.scan = scan.removing(path: path)
                if let focusPath, focusPath == path || focusPath.hasPrefix(path + "/") {
                    self.focusPath = (path as NSString).deletingLastPathComponent
                }
            }
            developerItems.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
            volume = scanner.volumeSummary(for: URL(fileURLWithPath: "/"))
            relayout()
            // Free space only changes once the Trash is emptied; say so, or it looks like nothing happened.
            show(toast: String(
                localized: "Moved “\(name)” to the Trash. Empty the Trash to get the space back.",
                bundle: .strings,
                comment: "Toast after Move to Trash: the item's name"
            ))
        case let .failure(error):
            let reason = if case let StorageTrashError.failed(message) = error {
                message
            } else if case StorageTrashError.protectedLocation = error {
                String(localized: "Mactivity doesn't move that folder.", bundle: .strings)
            } else {
                error.localizedDescription
            }
            show(toast: String(
                localized: "Couldn't move “\(name)” to the Trash. \(reason)",
                bundle: .strings,
                comment: "Toast: the item's name, then why it couldn't be moved"
            ))
        }
    }

    func show(toast text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else {
                return
            }
            self?.toast = nil
        }
    }
}

// MARK: - What grew (D-208)

extension StorageModel {
    /// Keeps this scan's folder sizes and compares them with the last scan of the same place,
    /// off the main thread: a walk of the big folders and a small file.
    func compareWithLastScan(_ result: StorageScan) {
        guard let url = scanner.folderSizesURL else {
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let new = FolderGrowthLog.sizes(result)
            let old = FolderGrowthLog.exchange(new, at: url)
            let folders = old.map { FolderGrowthLog.growth(from: $0, to: new) }
            await MainActor.run {
                guard let self, self.scan?.root.path == result.root.path else {
                    return
                }
                self.growth = old.map { ($0.scannedAt, folders ?? []) }
            }
        }
    }

    /// Render tests and previews: a growth line without a file.
    func show(growth: [FolderGrowth], since: Date) {
        self.growth = (since, growth)
    }
}
