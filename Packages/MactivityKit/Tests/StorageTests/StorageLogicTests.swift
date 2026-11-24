import Foundation
@testable import Storage
import Testing

@Suite("Category mapping")
struct CategoryMappingTests {
    @Test("Extensions map to categories by UTType", arguments: [
        ("jpg", StorageCategory.photosAndVideo), ("HEIC", .photosAndVideo), ("mov", .photosAndVideo), ("mp4", .photosAndVideo),
        ("mp3", .audio), ("m4a", .audio), ("wav", .audio),
        ("zip", .archives), ("dmg", .archives), ("tar", .archives), ("gz", .archives),
        ("pdf", .documents), ("txt", .documents), ("docx", .documents), ("key", .documents),
        ("swift", .developer), ("js", .developer), ("json", .developer), ("py", .developer), ("plist", .developer),
        ("app", .apps),
        ("", .other), ("qqqzzz", .other),
    ])
    func extensions(fileExtension: String, expected: StorageCategory) {
        #expect(CategoryRules.category(forExtension: fileExtension) == expected)
    }

    @Test("Folders set the category for their contents")
    func folderContexts() {
        let home = "/Users/alex"
        #expect(CategoryRules.context(forFolder: "Safari.app", path: "/Applications/Safari.app", home: home, inherited: nil) == .apps)
        #expect(CategoryRules.context(forFolder: "Library", path: "/Users/alex/Library", home: home, inherited: nil) == .systemAndLibrary)
        #expect(CategoryRules.context(forFolder: "Library", path: "/Users/sam/Library", home: home, inherited: nil) == .systemAndLibrary)
        #expect(CategoryRules
            .context(forFolder: "Library", path: "/System/Volumes/Data/Users/sam/Library", home: home, inherited: nil) == .systemAndLibrary)
        #expect(CategoryRules.context(forFolder: "Library", path: "/Users/alex/Projects/Library", home: home, inherited: nil) == nil)
        #expect(CategoryRules.context(
            forFolder: "Developer",
            path: "/Users/alex/Library/Developer",
            home: home,
            inherited: .systemAndLibrary
        ) == .developer)
        #expect(CategoryRules
            .context(forFolder: "node_modules", path: "/Users/alex/web/node_modules", home: home, inherited: nil) == .developer)
        #expect(CategoryRules
            .context(forFolder: "Resources", path: "/Applications/X.app/Contents/Resources", home: home, inherited: .apps) == .apps)
        #expect(CategoryRules.context(
            forFolder: "node_modules",
            path: "/Applications/X.app/Contents/node_modules",
            home: home,
            inherited: .apps
        ) == .apps)
        #expect(CategoryRules.context(
            forFolder: "Photos Library.photoslibrary",
            path: "/Users/alex/Pictures/Photos Library.photoslibrary",
            home: home,
            inherited: nil
        ) == .photosAndVideo)
        #expect(CategoryRules.context(forFolder: "Pictures", path: "/Users/alex/Pictures", home: home, inherited: nil) == nil)
        #expect(CategoryRules.context(forFolder: "System", path: "/System", home: home, inherited: nil) == .systemAndLibrary)
    }

    @Test("The per-scan cache is case-insensitive and handles names without an extension")
    func cache() {
        var cache = CategoryCache()
        #expect(cache.category(forFileNamed: "IMG_0001.JPG") == .photosAndVideo)
        #expect(cache.category(forFileNamed: "img.jpg") == .photosAndVideo)
        #expect(cache.category(forFileNamed: "Makefile") == .other)
        #expect(cache.category(forFileNamed: ".zshrc") == .other)
    }
}

@Suite("Developer lens")
struct DeveloperLensTests {
    @Test("Finds known locations on a fake home, and node_modules only from the scan")
    func fakeHome() throws {
        let home = try ScratchTree()
        let system = try ScratchTree()
        try home.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", bytes: 300_000)
        try home.file("Library/Developer/Xcode/iOS DeviceSupport/18.0/Symbols/dyld", bytes: 120_000)
        try home.file("Library/Developer/CoreSimulator/Devices/UUID/data/app", bytes: 90000)
        try home.file("Library/Caches/Homebrew/downloads/bottle.tar.gz", bytes: 80000)
        try home.file("Library/Caches/pip/wheels/w.whl", bytes: 40000)
        try home.file(".npm/_cacache/content-v2/sha512/aa", bytes: 30000)
        try home.file(".gradle/caches/modules-2/m.jar", bytes: 20000)
        try home.file(".cargo/registry/cache/c.crate", bytes: 10000)
        try home.file("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 150_000)
        try home.file("Projects/web/node_modules/react/index.js", bytes: 60000)
        try home.file("Projects/web/node_modules/react/node_modules/loose/index.js", bytes: 5000)
        try home.file("Projects/api/node_modules/express/index.js", bytes: 25000)
        try system.file("System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/asset/img", bytes: 70000)
        // Only Projects is scanned; the rest is measured on its own.
        let scan = try runScan(home.path + "/Projects", home: home.path)
        let items = DeveloperLens.discover(home: home.path, systemRoot: system.path, scan: scan) { path in
            LiveStorageScanner.measure(path, home: home.path)
        }
        let kinds = Set(items.map(\.kind))
        #expect(kinds == [
            .derivedData, .deviceSupport, .simulatorDevices, .simulatorRuntimes, .homebrewCache, .pipCache,
            .npmCache, .gradleCaches, .cargoRegistry, .dockerDisk, .nodeModules,
        ])
        #expect(!kinds.contains(.archives), "missing locations are left out")
        #expect(!kinds.contains(.yarnCache))
        let modules = items.filter { $0.kind == .nodeModules }
        #expect(modules.map(\.path).sorted() == [home.path + "/Projects/api/node_modules", home.path + "/Projects/web/node_modules"])
        #expect(modules.first { $0.path.hasSuffix("web/node_modules") }?.title == "node_modules in web")
        let derived = try #require(items.first { $0.kind == .derivedData })
        #expect(derived.size == home.allocated("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o"))
        #expect(items.map(\.size) == items.map(\.size).sorted(by: >), "largest first")
        #expect(items.allSatisfy { !$0.note.isEmpty })
    }

    @Test("A location inside the scan is read from the tree, not measured again")
    func fromTree() throws {
        let home = try ScratchTree()
        try home.file("Library/Developer/Xcode/DerivedData/A/b.o", bytes: 50000)
        let scan = try runScan(home.path, home: home.path)
        var measured: [String] = []
        let items = DeveloperLens.discover(home: home.path, systemRoot: home.path + "/nope", scan: scan) { path in
            measured.append(path)
            return nil
        }
        #expect(items.map(\.kind) == [.derivedData])
        #expect(!measured.contains(home.path + "/Library/Developer/Xcode/DerivedData"))
    }
}

@Suite("Sunburst layout")
struct SunburstLayoutTests {
    private func file(_ name: String, _ size: UInt64, in parent: String) -> StorageNode {
        StorageNode(name: name, path: parent + "/" + name, kind: .file, size: size, fileCount: 1, category: .other)
    }

    private func sampleTree() -> StorageNode {
        let big = StorageNode.directory(name: "big", path: "/r/big", children: [
            file("a", 600, in: "/r/big"), file("b", 300, in: "/r/big"), file("c", 100, in: "/r/big"),
        ])
        var tiny: [StorageNode] = []
        for index in 0 ..< 50 {
            tiny.append(file("t\(index)", 1, in: "/r"))
        }
        return .directory(name: "r", path: "/r", children: [big, file("mid", 950, in: "/r")] + tiny)
    }

    @Test("Ring 1 spans the full circle; children stay inside their parent")
    func anglesSum() throws {
        let segments = SunburstLayout.segments(for: sampleTree(), minimumAngle: 0.01)
        let ring1 = segments.filter { $0.ring == 1 }
        let sum = ring1.reduce(0) { $0 + $1.span }
        #expect(abs(sum - SunburstLayout.fullCircle) < 1e-9)
        let big = try #require(ring1.first { $0.node?.name == "big" })
        let children = segments.filter { $0.ring == 2 }
        #expect(children.count == 3)
        #expect(abs(children.reduce(0) { $0 + $1.span } - big.span) < 1e-9)
        #expect(children.allSatisfy { $0.startAngle >= big.startAngle - 1e-12 && $0.endAngle <= big.endAngle + 1e-12 })
        #expect(children.allSatisfy { $0.branch == big.branch })
    }

    @Test("Slices under the minimum angle merge into one Other slice")
    func merging() throws {
        let segments = SunburstLayout.segments(for: sampleTree(), minimumAngle: 0.01)
        let ring1 = segments.filter { $0.ring == 1 }
        #expect(ring1.count == 3, "big, mid, and one merged slice")
        let merged = try #require(ring1.last)
        guard case let .merged(parent, count, size) = merged.content else {
            Issue.record("the last slice should be merged")
            return
        }
        #expect(parent == "/r")
        #expect(count == 50)
        #expect(size == 50)
        #expect(abs(merged.endAngle - SunburstLayout.fullCircle) < 1e-9)
    }

    @Test("Rings stop at the requested depth")
    func depth() {
        let segments = SunburstLayout.segments(for: sampleTree(), rings: 1)
        #expect(segments.allSatisfy { $0.ring == 1 })
        #expect(SunburstLayout.segments(for: .directory(name: "e", path: "/e", children: [])).isEmpty)
    }

    @Test("Hit testing finds the segment under a point")
    func hitTesting() {
        let segments = SunburstLayout.segments(for: sampleTree(), minimumAngle: 0.01)
        // Straight up, in ring 1: angle 0, the first (largest) child.
        let top = SunburstLayout.hit(segments, dx: 0, dy: -45, centerRadius: 30, ringWidth: 20)
        #expect(top?.node?.name == "big")
        // Inside the center: nothing.
        #expect(SunburstLayout.hit(segments, dx: 5, dy: 5, centerRadius: 30, ringWidth: 20) == nil)
        #expect(abs(SunburstLayout.angle(dx: 1, dy: 0) - Double.pi / 2) < 1e-9, "3 o'clock is a quarter turn")
        #expect(abs(SunburstLayout.angle(dx: -1, dy: 0) - 3 * Double.pi / 2) < 1e-9)
    }
}

@Suite("Volume and permissions")
struct VolumeTests {
    @Test("Purgeable is important-usage minus available; the bar adds up to capacity")
    func summaryMath() {
        let volume = VolumeSummary(
            name: "HD",
            mountPath: "/",
            format: "APFS",
            capacity: 1000,
            available: 300,
            availableForImportantUsage: 350
        )
        #expect(volume.purgeable == 50)
        #expect(volume.free == 300)
        #expect(volume.used == 650)
        #expect(volume.used + volume.purgeable + volume.free == volume.capacity)
        let odd = VolumeSummary(name: "HD", mountPath: "/", format: "APFS", capacity: 1000, available: 300, availableForImportantUsage: 200)
        #expect(odd.purgeable == 0)
    }

    @Test("The startup volume has a summary")
    func startupVolume() throws {
        let volume = try #require(VolumeInfo.summary(for: URL(fileURLWithPath: "/")))
        #expect(volume.capacity > 0)
        #expect(volume.used + volume.purgeable + volume.free == volume.capacity)
    }

    @Test("Full Disk Access probe: EPERM means denied, a readable file means granted")
    func probe() throws {
        let tree = try ScratchTree()
        let readable = try tree.file("ok.txt", bytes: 10)
        let locked = try tree.file("locked.txt", bytes: 10)
        chmod(locked.path, 0)
        #expect(VolumeInfo.fullDiskAccess(probing: [locked.path]) == .denied)
        #expect(VolumeInfo.fullDiskAccess(probing: [locked.path, readable.path]) == .granted)
        #expect(VolumeInfo.fullDiskAccess(probing: [tree.path + "/missing"]) == .unknown)
    }
}

@Suite("Trasher")
struct TrasherTests {
    @Test("A confirmed file goes to the Trash, not away")
    func trashesFile() async throws {
        let tree = try ScratchTree()
        let file = try tree.file("delete-me-\(UUID().uuidString).bin", bytes: 1000)
        let trasher = StorageTrasher(home: "/Users/nobody-\(UUID().uuidString)")
        let trashed = try await trasher.moveToTrash(TrashConfirmation(path: file.path, confirmedAt: Date()))
        let location = try #require(trashed)
        defer { try? FileManager.default.removeItem(at: location) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: location.path))
        #expect(location.path.contains(".Trash"))
    }

    @Test("Protected locations are refused", arguments: ["/", "/Users", "/Applications", "/System/Library", "/Library", "relative/path"])
    func refusesProtected(path: String) {
        let trasher = StorageTrasher(home: "/Users/alex")
        #expect(throws: StorageTrashError.self) {
            try trasher.check(path)
        }
    }

    @Test("The home folder and its top-level folders are refused")
    func refusesHome() {
        let trasher = StorageTrasher(home: "/Users/alex")
        for path in ["/Users/alex", "/Users/alex/Library", "/Users/alex/Documents/", "/Users/alex/../alex"] {
            #expect(throws: StorageTrashError.protectedLocation(path)) {
                try trasher.check(path)
            }
        }
    }

    @Test("Through the data volume's path, the same places stay protected, and the rest can move (D-140)")
    func dataVolume() {
        let trasher = StorageTrasher(home: "/Users/alex")
        for path in [
            "/System/Volumes/Data", "/System/Volumes/Data/Users", "/System/Volumes/Data/Applications",
            "/System/Volumes/Data/Users/alex", "/System/Volumes/Data/Users/alex/Documents",
        ] {
            #expect(throws: StorageTrashError.protectedLocation(path)) {
                try trasher.check(path)
            }
        }
        // Allowed past the location check: it's only "not found" because it doesn't exist here.
        let file = "/System/Volumes/Data/Users/alex/Downloads/big-\(UUID().uuidString).dmg"
        #expect(throws: StorageTrashError.notFound(file)) {
            try trasher.check(file)
        }
    }

    @Test("A missing item is reported as not found")
    func missing() {
        let trasher = StorageTrasher(home: "/Users/alex")
        let path = NSTemporaryDirectory() + "missing-\(UUID().uuidString)"
        #expect(throws: StorageTrashError.notFound(path)) {
            try trasher.check(path)
        }
    }
}

@Suite("Simulated scanner")
struct SimulatedScannerTests {
    @Test("Streams progress, then a consistent tree")
    func stream() async throws {
        let scanner = SimulatedStorageScanner(fullDiskAccess: .denied, stepDelay: .zero)
        var progress = 0
        var finished: StorageScan?
        for try await event in scanner.scan(scanner.home) {
            switch event {
            case .progress: progress += 1
            case let .finished(scan): finished = scan
            }
        }
        let scan = try #require(finished)
        #expect(progress > 0)
        #expect(scan.root.size == scan.categories.reduce(0) { $0 + $1.bytes })
        #expect(scan.unreadable.count == 3)
        #expect(scan.largestFiles.first?.name == "Trip to Lisbon 2026.mov")
        let lens = await scanner.developerLens(for: scan)
        #expect(lens.contains { $0.kind == .derivedData })
        #expect(lens.filter { $0.kind == .nodeModules }.count == 2)
        #expect(lens.contains { $0.kind == .dockerDisk })
    }
}
