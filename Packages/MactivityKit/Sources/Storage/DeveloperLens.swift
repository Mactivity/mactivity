import Foundation

/// Known developer locations that can be rebuilt or re-downloaded, with their sizes (spec E10).
/// Showing, not cleaning (spec 3): each entry says what getting it back costs, and nothing is
/// removed unless the user moves it to the Trash through the confirm step.
public enum DeveloperLens {
    /// A known location, relative to a home folder or absolute.
    struct Location {
        let kind: DeveloperItem.Kind
        let title: String
        /// Relative to the home folder unless it starts with "/".
        let path: String
        let note: String
        let symbol: String
    }

    static let locations: [Location] = [
        Location(
            kind: .derivedData,
            title: String(localized: "Xcode DerivedData", bundle: .strings, comment: "Developer lens row; DerivedData is a folder name"),
            path: "Library/Developer/Xcode/DerivedData",
            note: String(
                localized: "Build products and indexes. Xcode rebuilds them; the next build and indexing of each project are slower.",
                bundle: .strings,
                comment: "Developer lens: what deleting it costs. Keep text in backticks (commands) as is."
            ),
            symbol: "hammer"
        ),
        Location(
            kind: .archives,
            title: String(localized: "Xcode Archives", bundle: .strings, comment: "Developer lens row: Xcode’s archived builds"),
            path: "Library/Developer/Xcode/Archives",
            note: String(
                localized: "Not rebuildable: your shipped builds and their dSYMs. Keep any you may need to symbolicate crash reports.",
                bundle: .strings,
                comment: "Developer lens: what deleting it costs. Keep text in backticks (commands) as is."
            ),
            symbol: "archivebox"
        ),
        Location(
            kind: .deviceSupport,
            title: String(localized: "iOS DeviceSupport", bundle: .strings, comment: "Developer lens row; a folder name"),
            path: "Library/Developer/Xcode/iOS DeviceSupport",
            note: deviceSupportNote,
            symbol: "iphone"
        ),
        Location(
            kind: .simulatorDevices,
            title: String(localized: "Simulator devices", bundle: .strings, comment: "Developer lens row"),
            path: "Library/Developer/CoreSimulator/Devices",
            note: String(
                localized: "Apps and data inside each simulator are lost. `xcrun simctl delete unavailable` removes only stale ones.",
                bundle: .strings,
                comment: "Developer lens: what deleting it costs. Keep text in backticks (commands) as is."
            ),
            symbol: "ipad.and.iphone"
        ),
    ] + simulatorRuntimes + [
        Location(
            kind: .homebrewCache,
            title: String(localized: "Homebrew cache", bundle: .strings, comment: "Developer lens row"),
            path: "Library/Caches/Homebrew",
            note: String(
                localized: "Downloaded bottles. Homebrew downloads them again when needed; `brew cleanup` trims it too.",
                bundle: .strings,
                comment: "Developer lens: what deleting it costs. Keep text in backticks (commands) as is."
            ),
            symbol: "mug"
        ),
        Location(
            kind: .pipCache,
            title: String(localized: "pip cache", bundle: .strings, comment: "Developer lens row; pip is a tool name"),
            path: "Library/Caches/pip",
            note: String(
                localized: "Wheels and downloads. pip fetches them again on the next install.",
                bundle: .strings,
                comment: "Developer lens: what deleting it costs. Keep text in backticks (commands) as is."
            ),
            symbol: "shippingbox"
        ),
        Location(
            kind: .npmCache,
            title: String(localized: "npm cache", bundle: .strings, comment: "Developer lens row; npm is a tool name"),
            path: ".npm/_cacache",
            note: String(
                localized: "Package tarballs. npm downloads them again; offline installs stop working until it refills.",
                bundle: .strings,
                comment: "Developer lens: what deleting it costs. Keep text in backticks (commands) as is."
            ),
            symbol: "shippingbox"
        ),
        Location(
            kind: .yarnCache,
            title: String(localized: "Yarn cache", bundle: .strings, comment: "Developer lens row"),
            path: "Library/Caches/Yarn",
            note: String(
                localized: "Package tarballs. Yarn downloads them again on the next install.",
                bundle: .strings,
                comment: "Developer lens: what deleting it costs. Keep text in backticks (commands) as is."
            ),
            symbol: "shippingbox"
        ),
        Location(
            kind: .gradleCaches,
            title: String(localized: "Gradle caches", bundle: .strings, comment: "Developer lens row"),
            path: ".gradle/caches",
            note: String(
                localized: "Dependencies and the build cache. The next build downloads and rebuilds them, slowly the first time.",
                bundle: .strings,
                comment: "Developer lens: what deleting it costs. Keep text in backticks (commands) as is."
            ),
            symbol: "shippingbox"
        ),
        Location(
            kind: .cargoRegistry,
            title: String(localized: "Cargo registry", bundle: .strings, comment: "Developer lens row"),
            path: ".cargo/registry",
            note: String(
                localized: "Crate sources and index. Cargo downloads them again on the next build.",
                bundle: .strings,
                comment: "Developer lens: what deleting it costs. Keep text in backticks (commands) as is."
            ),
            symbol: "shippingbox"
        ),
        Location(
            kind: .dockerDisk,
            title: String(localized: "Docker disk image", bundle: .strings, comment: "Developer lens row"),
            path: "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            note: String(
                localized: "Every image, container, and volume. Trashing it loses them all; prefer `docker system prune` from Docker.",
                bundle: .strings,
                comment: "Developer lens: what deleting it costs. Keep text in backticks (commands) as is."
            ),
            symbol: "cube.box"
        ),
    ]

    /// Locations that come back by themselves (D-120): Xcode rebuilds DerivedData and copies
    /// device symbols again; package managers download their caches again. Archives, simulator
    /// devices, runtimes, Docker's disk and node_modules aren't here: they hold work, or are
    /// removed another way.
    public static let rebuildable: Set<DeveloperItem.Kind> = [
        .derivedData, .deviceSupport, .homebrewCache, .pipCache, .npmCache, .yarnCache, .gradleCaches, .cargoRegistry,
    ]

    /// The rebuildable locations that exist, with their sizes, largest first. No scan needed.
    public static func rebuildableItems(home: String = NSHomeDirectory()) -> [DeveloperItem] {
        discover(home: home, scan: nil) { LiveStorageScanner.measure($0, home: home) }
            .filter { rebuildable.contains($0.kind) }
    }

    static let deviceSupportNote = String(
        localized: "Symbols copied from devices. Xcode copies them again, for a few minutes, the next time you connect that device.",
        bundle: .strings,
        comment: "Developer lens: what deleting iOS DeviceSupport costs"
    )

    static let runtimeNote = String(
        localized: "Re-download from Xcode → Settings → Components, several GB each. Remove them there, not in Finder.",
        bundle: .strings,
        comment: "Developer lens: what deleting simulator runtimes costs. Xcode → Settings → Components is Xcode’s menu path."
    )

    /// Runtimes live as mobile assets on 26 and later, and as disk images before that.
    static let simulatorRuntimes: [Location] = [
        ("iOS", "iOS"), ("watchOS", "watchOS"), ("tvOS", "appleTVOS"), ("visionOS", "xrOS"),
    ].map { platform, asset in
        Location(
            kind: .simulatorRuntimes,
            title: String(localized: "\(platform) simulator runtimes", bundle: .strings, comment: "Developer lens row; iOS, watchOS, …"),
            path: "/System/Library/AssetsV2/com_apple_MobileAsset_\(asset)SimulatorRuntime",
            note: runtimeNote,
            symbol: "square.stack.3d.down.right"
        )
    } + [
        Location(
            kind: .simulatorRuntimes,
            title: String(localized: "Simulator runtime images", bundle: .strings, comment: "Developer lens row"),
            path: "/Library/Developer/CoreSimulator/Images",
            note: runtimeNote,
            symbol: "square.stack.3d.down.right"
        ),
    ]

    static let nodeModulesNote = String(
        localized: "Restored from the lockfile by `npm install` (or pnpm, yarn). Needs the network or a warm cache.",
        bundle: .strings,
        comment: "Developer lens: what deleting node_modules costs. Keep text in backticks (commands) as is."
    )

    /// Every known location that exists, plus each outermost `node_modules` in `scan`, largest first.
    ///
    /// - Parameters:
    ///   - home: the home folder the relative locations hang off.
    ///   - systemRoot: prefix for the absolute locations; "/" except in tests.
    ///   - scan: the latest scan. Locations inside it are read from its tree; `node_modules` come only from it.
    ///   - measure: sizes a location that isn't in the scan (allocated bytes), or nil if it isn't there.
    public static func discover(
        home: String,
        systemRoot: String = "/",
        scan: StorageScan?,
        measure: (String) -> UInt64?
    ) -> [DeveloperItem] {
        var items: [DeveloperItem] = []
        for location in locations {
            let path = if location.path.hasPrefix("/") {
                systemRoot == "/" ? location.path : systemRoot + location.path
            } else {
                home + "/" + location.path
            }
            let size: UInt64? = if let node = scan?.root.node(atPath: path), node.isItem {
                node.size
            } else {
                measure(path)
            }
            guard let size, size > 0 else {
                continue
            }
            items.append(DeveloperItem(
                kind: location.kind,
                title: location.title,
                path: path,
                size: size,
                note: location.note,
                symbol: location.symbol
            ))
        }
        if let scan {
            items += nodeModules(in: scan.root).map { node in
                DeveloperItem(
                    kind: .nodeModules,
                    title: String(
                        localized: "node_modules in \(projectName(for: node.path))",
                        bundle: .strings,
                        comment: "Developer lens row; node_modules is a folder name, the argument a project folder"
                    ),
                    path: node.path,
                    size: node.size,
                    note: nodeModulesNote,
                    symbol: "cube"
                )
            }
        }
        return items.sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
    }

    /// The outermost `node_modules` folders in a tree; nested ones are part of their parent's size.
    public static func nodeModules(in root: StorageNode) -> [StorageNode] {
        var found: [StorageNode] = []
        root.visit { node in
            guard node.kind == .directory else {
                return false
            }
            if node.name == "node_modules" {
                found.append(node)
                return false
            }
            return true
        }
        return found
    }

    private static func projectName(for nodeModulesPath: String) -> String {
        ((nodeModulesPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }
}
