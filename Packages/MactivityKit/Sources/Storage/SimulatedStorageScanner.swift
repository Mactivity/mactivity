import Core
import Foundation

/// A made-up home folder for previews, renders, and tests (CLAUDE.md rule 1). Deterministic:
/// the same tree every time, with a DerivedData, a Docker disk, a few `node_modules`, and
/// (when Full Disk Access is off) Mail and Messages as "Not readable".
public struct SimulatedStorageScanner: StorageScanning {
    /// Nothing is kept: a simulated scan has nothing to grow from.
    public var folderSizesURL: URL? {
        nil
    }

    /// Backed up an hour ago to "Backup".
    public func timeMachine() -> TimeMachineStatus? {
        TimeMachineStatus(isAutomatic: true, lastBackup: Date().addingTimeInterval(-3600), destination: "Backup")
    }

    public let home = URL(fileURLWithPath: "/Users/alex")
    private let access: FullDiskAccessStatus
    private let stepDelay: Duration

    /// - Parameters:
    ///   - fullDiskAccess: what the permission probe reports; `.denied` adds unreadable folders.
    ///   - stepDelay: pause between progress events; zero for tests and renders.
    public init(fullDiskAccess: FullDiskAccessStatus = .granted, stepDelay: Duration = .milliseconds(60)) {
        access = fullDiskAccess
        self.stepDelay = stepDelay
    }

    public var trasher: any StorageTrashing {
        SimulatedStorageTrasher()
    }

    public func volumeSummary(for url: URL) -> VolumeSummary? {
        VolumeSummary(
            name: "Macintosh HD",
            mountPath: "/",
            format: "APFS",
            capacity: 994_662_584_320,
            available: 318_204_551_168,
            availableForImportantUsage: 347_918_336_000
        )
    }

    public func fullDiskAccess() -> FullDiskAccessStatus {
        access
    }

    public func scan(_ root: URL) -> AsyncThrowingStream<StorageScanEvent, any Error> {
        let result = makeScan()
        let delay = stepDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                let steps = 12
                for step in 1 ... steps {
                    if Task.isCancelled {
                        continuation.finish(throwing: StorageScanError.cancelled)
                        return
                    }
                    let fraction = Double(step) / Double(steps)
                    continuation.yield(.progress(StorageScanProgress(
                        filesScanned: Int(Double(result.fileCount) * fraction),
                        directoriesScanned: Int(Double(result.directoryCount) * fraction),
                        bytesScanned: UInt64(Double(result.root.size) * fraction),
                        currentPath: result.root.children[step % result.root.children.count].path,
                        elapsed: .milliseconds(step * 60)
                    )))
                    if delay > .zero {
                        try? await Task.sleep(for: delay)
                    }
                }
                continuation.yield(.finished(result))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func developerLens(for scan: StorageScan?) async -> [DeveloperItem] {
        DeveloperLens.discover(home: home.path, scan: scan) { path in
            path == "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime" ? 15_140_000_000 : nil
        }
    }

    /// The finished scan, without the progress events.
    public func makeScan() -> StorageScan {
        let root = SimulatedTree.build(home: home.path, unreadable: access == .denied)
        var totals: [StorageCategory: (UInt64, Int)] = [:]
        var directories = 0
        root.visit { node in
            switch node.kind {
            case .directory:
                directories += 1
            case .file, .smallFiles:
                let category = node.category ?? .other
                let total = totals[category] ?? (0, 0)
                totals[category] = (total.0 + node.size, total.1 + node.fileCount)
            case .unreadable:
                break
            }
            return true
        }
        var unreadable: [String] = []
        root.visit { node in
            if node.kind == .unreadable {
                unreadable.append(node.path)
            }
            return true
        }
        return StorageScan(
            root: root,
            startedAt: Date(timeIntervalSinceReferenceDate: 780_000_000),
            duration: .milliseconds(4200),
            fileCount: root.fileCount,
            directoryCount: directories,
            categories: StorageCategory.allCases.map {
                CategoryTotal(category: $0, bytes: totals[$0]?.0 ?? 0, fileCount: totals[$0]?.1 ?? 0)
            }
            .sorted { $0.bytes > $1.bytes },
            largestFiles: StorageScan.largestFiles(in: root),
            unreadable: unreadable.sorted(),
            skipped: [],
            home: home.path
        )
    }
}

/// Pretends to move to the Trash. Touches nothing.
public struct SimulatedStorageTrasher: StorageTrashing {
    public init() {}

    public func moveToTrash(_ confirmation: TrashConfirmation) async throws -> URL? {
        URL(fileURLWithPath: "/Users/alex/.Trash").appendingPathComponent((confirmation.path as NSString).lastPathComponent)
    }
}

/// The simulated home folder, described as a spec and built into nodes.
private enum SimulatedTree {
    indirect enum Spec {
        case folder(String, [Spec])
        /// Name and size in GB.
        case file(String, Double)
        /// Count, total GB, category.
        case small(Int, Double, StorageCategory)
        case unreadable(String)
    }

    static func build(home: String, unreadable: Bool) -> StorageNode {
        let spec = Spec.folder((home as NSString).lastPathComponent, contents(unreadable: unreadable))
        return make(spec, parent: (home as NSString).deletingLastPathComponent, home: home, context: nil)
    }

    private static func make(_ spec: Spec, parent: String, home: String, context: StorageCategory?) -> StorageNode {
        switch spec {
        case let .folder(name, children):
            let path = parent + "/" + name
            let inner = CategoryRules.context(forFolder: name, path: path, home: home, inherited: context)
            return .directory(name: name, path: path, children: children.map { make($0, parent: path, home: home, context: inner) })
        case let .file(name, gigabytes):
            let fileExtension = (name as NSString).pathExtension
            return StorageNode(
                name: name,
                path: parent + "/" + name,
                kind: .file,
                size: bytes(gigabytes),
                fileCount: 1,
                category: context ?? CategoryRules.category(forExtension: fileExtension)
            )
        case let .small(count, gigabytes, category):
            return StorageNode(
                name: "\(count.formatted()) smaller files",
                path: parent,
                kind: .smallFiles,
                size: bytes(gigabytes),
                fileCount: count,
                category: context ?? category
            )
        case let .unreadable(name):
            return StorageNode(name: name, path: parent + "/" + name, kind: .unreadable, size: 0, fileCount: 0)
        }
    }

    private static func bytes(_ gigabytes: Double) -> UInt64 {
        UInt64(gigabytes * 1_000_000_000)
    }

    private static func contents(unreadable: Bool) -> [Spec] {
        [library(unreadable: unreadable), movies, pictures, music, documents, developer, downloads, applications, desktop, dotfiles]
            .flatMap(\.self)
    }

    private static func library(unreadable: Bool) -> [Spec] {
        let protected: [Spec] = unreadable
            ? [.unreadable("Mail"), .unreadable("Messages"), .unreadable("Safari")]
            : [.folder("Mail", [.small(48210, 4.2, .documents)]), .folder("Messages", [.small(9840, 6.1, .photosAndVideo)])]
        return [.folder("Library", [
            .folder("Developer", [
                .folder("Xcode", [
                    .folder("DerivedData", [
                        .folder("Mactivity-bxkqzhfy", [.small(61200, 7.8, .developer)]),
                        .folder("Storefront-aavdjsle", [.small(42010, 5.9, .developer)]),
                        .folder("Weather-ftquwplr", [.small(18400, 4.5, .developer)]),
                    ]),
                    .folder(
                        "Archives",
                        [.folder("2026-09-12", [.small(412, 3.9, .developer)]), .folder("2026-07-30", [.small(380, 2.5, .developer)])]
                    ),
                    .folder(
                        "iOS DeviceSupport",
                        [
                            .folder("iPhone18,1 27.0 (24A5300)", [.small(2210, 5.6, .developer)]),
                            .folder("iPhone17,2 26.4", [.small(2140, 4.2, .developer)]),
                        ]
                    ),
                ]),
                .folder("CoreSimulator", [
                    .folder("Devices", [.small(210_400, 22.5, .developer)]),
                    .folder("Caches", [.small(3100, 3.1, .developer)]),
                ]),
            ]),
            .folder("Containers", [
                .folder(
                    "com.docker.docker",
                    [.folder("Data", [.folder("vms", [.folder("0", [.folder("data", [.file("Docker.raw", 14.6)])])])])]
                ),
                .folder("com.apple.Notes", [.small(4120, 1.1, .documents)]),
                .small(88300, 5.4, .systemAndLibrary),
            ]),
            .folder("Caches", [
                .folder("Homebrew", [.small(612, 4.2, .archives)]),
                .folder("pip", [.small(3400, 1.3, .developer)]),
                .folder("Yarn", [.small(21000, 0.9, .developer)]),
                .folder("com.apple.Safari", [.small(8800, 0.6, .systemAndLibrary)]),
                .small(51000, 3.8, .systemAndLibrary),
            ]),
            .folder("Application Support", [
                .folder("MobileSync", [.folder("Backup", [.small(40210, 12.8, .systemAndLibrary)])]),
                .folder("Google", [.small(9210, 3.2, .systemAndLibrary)]),
                .folder("Code", [.small(12400, 2.1, .systemAndLibrary)]),
                .folder("Slack", [.small(3300, 1.4, .systemAndLibrary)]),
                .small(30100, 2.6, .systemAndLibrary),
            ]),
        ] + protected + [.small(24000, 1.9, .systemAndLibrary)])]
    }

    private static let movies: [Spec] = [.folder("Movies", [
        .folder("Final Cut Library.fcpbundle", [.small(3400, 52.0, .photosAndVideo)]),
        .file("Trip to Lisbon 2026.mov", 18.4),
        .folder(
            "Screen Recordings",
            [.file("Keynote rehearsal.mov", 4.8), .file("Bug repro 0912.mov", 2.9), .small(64, 3.1, .photosAndVideo)]
        ),
    ])]

    private static let pictures: [Spec] = [.folder("Pictures", [
        .folder(
            "Photos Library.photoslibrary",
            [.folder("originals", [.small(38400, 58.1, .photosAndVideo)]), .folder("resources", [.small(92000, 3.4, .photosAndVideo)])]
        ),
        .folder("Screenshots", [.small(1840, 2.2, .photosAndVideo)]),
    ])]

    private static let music: [Spec] = [.folder(
        "Music",
        [.folder("Music", [.folder("Media.localized", [.small(6210, 21.4, .audio)])]), .folder("Logic", [.small(840, 6.3, .audio)])]
    )]

    private static let documents: [Spec] = [.folder("Documents", [
        .folder("Taxes", [.small(410, 0.8, .documents)]),
        .folder("Design", [.file("App Icon.icon", 1.2), .file("Brand guidelines.pdf", 0.6), .small(1210, 5.4, .documents)]),
        .file("Thesis draft.pages", 0.4),
        .small(9800, 12.6, .documents),
    ])]

    private static let developer: [Spec] = [.folder("Developer", [
        .folder(
            "storefront-web",
            [
                .folder("node_modules", [.small(184_000, 1.8, .developer)]),
                .folder(".git", [.small(4100, 0.6, .developer)]),
                .small(2400, 0.2, .developer),
            ]
        ),
        .folder(
            "ml-playground",
            [
                .folder(".venv", [.small(48200, 5.6, .developer)]),
                .folder("datasets", [.file("imagenet-subset.tar", 9.8), .small(120, 2.3, .archives)]),
            ]
        ),
        .folder("mactivity", [.folder(".build", [.small(21000, 3.2, .developer)]), .small(640, 0.1, .developer)]),
        .folder("api-gateway", [.folder("node_modules", [.small(96000, 0.9, .developer)]), .small(900, 0.1, .developer)]),
    ])]

    private static let downloads: [Spec] = [.folder("Downloads", [
        .file("Xcode_27.xip", 11.2),
        .file("macOS 27 beta.ipsw", 17.9),
        .file("Figma-arm64.dmg", 0.4),
        .small(2310, 3.6, .other),
    ])]

    private static let applications: [Spec] = [.folder("Applications", [
        .folder("Blender.app", [.folder("Contents", [.small(4812, 1.9, .apps)])]),
        .folder("Steam.app", [.folder("Contents", [.small(1020, 0.6, .apps)])]),
        .folder("Chrome Apps.localized", [.small(12, 0.1, .apps)]),
    ])]

    private static let desktop: [Spec] = [.folder("Desktop", [.small(412, 2.8, .documents)])]

    private static let dotfiles: [Spec] = [
        .folder(".npm", [.folder("_cacache", [.small(62000, 2.1, .developer)])]),
        .folder(".gradle", [.folder("caches", [.small(18000, 3.4, .developer)])]),
        .folder(".cargo", [.folder("registry", [.small(31000, 1.2, .developer)])]),
    ]
}
