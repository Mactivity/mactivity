import AppKit
import Core
import Docker
import Foundation
import Observation
import Storage

/// Space per project's state (D-223): one scan when the tab first shows, kept while the app
/// runs, again on Rescan. Trashing goes through the storage confirm step, never anywhere else.
@MainActor
@Observable
final class ProjectSpaceModel {
    enum Phase: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case done
    }

    private let scanner: any ProjectSpaceScanning
    /// Docker's engine, read when the scan runs (D-224); nil without Docker.
    @ObservationIgnored private let dockerEngine: @MainActor () -> (any DockerDiskSource)?
    let trasher: any StorageTrashing
    let trashStep = StorageTrashConfirmation()

    private(set) var spaces: [ProjectSpace] = []
    /// Nil until read, or when no engine runs.
    private(set) var docker: DockerDiskUsage?
    private(set) var phase = Phase.idle
    private(set) var scannedAt: Date?
    private(set) var toast: String?
    /// Only the projects untouched for two months.
    var staleOnly = false

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(
        scanner: any ProjectSpaceScanning,
        trasher: any StorageTrashing,
        docker: @escaping @MainActor () -> (any DockerDiskSource)? = { nil }
    ) {
        self.scanner = scanner
        self.trasher = trasher
        dockerEngine = docker
    }

    var isScanning: Bool {
        if case .scanning = phase {
            return true
        }
        return false
    }

    func shown(now: Date = Date()) -> [ProjectSpace] {
        staleOnly ? spaces.filter { $0.isStale(now: now) } : spaces
    }

    /// The tab showed: scans once, the first time.
    func appeared() {
        if phase == .idle {
            rescan()
        }
    }

    func rescan() {
        guard !isScanning else {
            return
        }
        phase = .scanning(done: 0, total: 0)
        let scanner = scanner
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            guard let self else {
                return
            }
            Task { @MainActor in
                if self.isScanning {
                    self.phase = .scanning(done: done, total: total)
                }
            }
        }
        // The first scan shows projects as they're sized; a rescan keeps the old list until done.
        let firstScan = spaces.isEmpty
        let report: @Sendable (ProjectSpace) -> Void = { [weak self] space in
            guard let self, firstScan else {
                return
            }
            Task { @MainActor in
                if self.isScanning {
                    self.spaces = (self.spaces + [space]).sorted { $0.totalBytes > $1.totalBytes }
                }
            }
        }
        let engine = dockerEngine()
        scanTask = Task { [weak self] in
            async let usage = try? engine?.diskUsage()
            let found = await scanner.scan(progress: progress, found: report)
            let dockerUsage = await usage
            guard let self, !Task.isCancelled else {
                return
            }
            spaces = found
            docker = dockerUsage
            scannedAt = Date()
            phase = .done
        }
    }

    /// Every folder of every untouched project, in one confirmation (D-229).
    func askToTrashUntouched(now: Date = Date()) {
        let stale = spaces.filter { $0.isStale(now: now) }
        let items = stale.flatMap(\.artifacts)
        guard !items.isEmpty else {
            return
        }
        let total = Formatters.bytes(items.reduce(0) { $0 &+ $1.size })
        var lines = stale.prefix(6).map { "\($0.name): \(Formatters.bytes($0.totalBytes))" }
        if stale.count > 6 {
            lines.append(String(localized: "and \(stale.count - 6) more", bundle: .strings, comment: "After a list of dev servers"))
        }
        let title = String(
            localized: "Move \(total) of build folders from untouched projects to the Trash?",
            bundle: .strings,
            comment: "Confirmation title: the size of every untouched project's build folders"
        )
        let note = String(
            localized: "Each project's tools make them again the next time you work on it.",
            bundle: .strings,
            comment: "Move untouched build folders to the Trash: what it costs"
        )
        var moved: UInt64 = 0
        var failed = 0
        var left = items.count
        trashStep
            .ask(
                items: items.map { ($0.path, $0.size) },
                title: title,
                message: lines.joined(separator: "\n") + "\n\n" + note
            ) { [weak self] path, result in
                guard let self else {
                    return
                }
                switch result {
                case .success:
                    moved &+= items.first { $0.path == path }?.size ?? 0
                    remove(path)
                case .failure:
                    failed += 1
                }
                left -= 1
                if left == 0 {
                    show(toast: failed == 0
                        ? String(
                            localized: "Moved \(Formatters.bytes(moved)) to the Trash. Empty the Trash to get the space back.",
                            bundle: .strings,
                            comment: "Toast after moving several build folders to the Trash: their size"
                        )
                        : String(
                            localized: "Moved \(Formatters.bytes(moved)) to the Trash; \(failed) couldn't be moved.",
                            bundle: .strings,
                            comment: "Toast: size moved, then how many folders failed"
                        ))
                }
            }
    }

    private func remove(_ path: String) {
        spaces = spaces.compactMap { space in
            let kept = space.artifacts.filter { $0.path != path }
            return kept.isEmpty ? nil : ProjectSpace(root: space.root, name: space.name, artifacts: kept, lastTouched: space.lastTouched)
        }
    }

    func askToTrash(_ artifact: ProjectArtifact, in space: ProjectSpace) {
        let name = "\(space.name)/\(artifact.relativePath(in: space.root))"
        trashStep
            .ask(path: artifact.path, name: name, size: artifact.size, note: ProjectSpaceRules.note(artifact.kind)) { [weak self] result in
                self?.trashFinished(artifact, name: name, result: result)
            }
    }

    private func trashFinished(_ artifact: ProjectArtifact, name: String, result: Result<URL?, any Error>) {
        switch result {
        case .success:
            remove(artifact.path)
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

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func show(toast text: String) {
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
