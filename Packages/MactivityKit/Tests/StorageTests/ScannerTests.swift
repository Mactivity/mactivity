import Darwin
import Foundation
@testable import Storage
import Testing

/// A scratch folder tree built for one test and removed after it.
final class ScratchTree {
    let root: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mactivity-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var → /private/var so paths match what the scanner reports.
        root = base.resolvingSymlinksInPath()
    }

    deinit {
        // Restore permissions first so a chmod 000 folder can be removed.
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            chmod(root.path, 0o755)
            while let relative = enumerator.nextObject() as? String {
                chmod(root.appendingPathComponent(relative).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    var path: String {
        root.path
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file with `bytes` of real (non-zero, so incompressible-ish) data.
    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            for index in raw.indices {
                raw[index] = UInt8(truncatingIfNeeded: index &* 2_654_435_761 >> 7)
            }
        }
        try data.write(to: url)
        return url
    }

    func allocated(_ relative: String) -> UInt64 {
        var info = stat()
        lstat(root.appendingPathComponent(relative).path, &info)
        return UInt64(info.st_blocks) * 512
    }
}

func runScan(_ path: String, threshold: UInt64 = 0, home: String = "/nonexistent-home") throws -> StorageScan {
    let engine = BulkScanEngine(
        root: path,
        options: StorageScanOptions(home: home, fileNodeThreshold: threshold),
        isCancelled: { false },
        progress: { _ in }
    )
    return try engine.scan()
}

@Suite("Bulk scanner on a scratch tree")
struct ScannerTests {
    @Test("Sizes are allocated bytes and add up through the tree")
    func allocatedSizes() throws {
        let tree = try ScratchTree()
        try tree.file("a/one.bin", bytes: 100_000)
        try tree.file("a/b/two.bin", bytes: 250_000)
        try tree.file("three.txt", bytes: 10)
        let scan = try runScan(tree.path)
        let expected = tree.allocated("a/one.bin") + tree.allocated("a/b/two.bin") + tree.allocated("three.txt")
        #expect(scan.root.size == expected)
        #expect(scan.fileCount == 3)
        #expect(scan.directoryCount == 3)
        let folder = try #require(scan.root.node(atPath: tree.path + "/a"))
        #expect(folder.size == tree.allocated("a/one.bin") + tree.allocated("a/b/two.bin"))
        #expect(scan.root.children.first?.name == "a", "children are sorted largest first")
    }

    @Test("A sparse file counts the blocks it occupies, not its length")
    func sparseFile() throws {
        let tree = try ScratchTree()
        let url = tree.root.appendingPathComponent("sparse.img")
        let fd = open(url.path, O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0)
        // 1 GB long, one 4 kB block written at the end.
        lseek(fd, 1_000_000_000, SEEK_SET)
        var byte: UInt8 = 1
        write(fd, &byte, 1)
        close(fd)
        let scan = try runScan(tree.path)
        let node = try #require(scan.root.node(atPath: url.path))
        #expect(node.size == tree.allocated("sparse.img"))
        #expect(node.size < 10_000_000)
    }

    @Test("A hard-linked file is counted once")
    func hardLinks() throws {
        let tree = try ScratchTree()
        let original = try tree.file("x/original.bin", bytes: 400_000)
        try tree.folder("y")
        #expect(link(original.path, tree.path + "/y/link.bin") == 0)
        #expect(link(original.path, tree.path + "/y/link2.bin") == 0)
        let scan = try runScan(tree.path)
        #expect(scan.fileCount == 1)
        #expect(scan.root.size == tree.allocated("x/original.bin"))
    }

    @Test("Symlinks are counted as themselves and never followed")
    func symlinks() throws {
        let tree = try ScratchTree()
        try tree.file("target/big.bin", bytes: 500_000)
        let outside = try ScratchTree()
        try outside.file("elsewhere.bin", bytes: 800_000)
        try FileManager.default.createSymbolicLink(atPath: tree.path + "/to-target", withDestinationPath: tree.path + "/target")
        try FileManager.default.createSymbolicLink(atPath: tree.path + "/to-outside", withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: tree.path + "/to-file", withDestinationPath: tree.path + "/target/big.bin")
        let scan = try runScan(tree.path)
        let links = tree.allocated("to-target") + tree.allocated("to-outside") + tree.allocated("to-file")
        #expect(scan.root.size == tree.allocated("target/big.bin") + links)
        #expect(scan.fileCount == 4, "big.bin plus three links")
        #expect(scan.root.node(atPath: tree.path + "/to-outside")?.isDirectory != true)
    }

    @Test("An unreadable folder is reported, and the rest is still scanned")
    func unreadableFolder() throws {
        let tree = try ScratchTree()
        try tree.file("open/fine.bin", bytes: 50000)
        let locked = try tree.folder("locked")
        try tree.file("locked/secret.bin", bytes: 90000)
        #expect(chmod(locked.path, 0) == 0)
        let scan = try runScan(tree.path)
        #expect(scan.unreadable == [locked.path])
        let node = try #require(scan.root.node(atPath: locked.path))
        #expect(node.kind == .unreadable)
        #expect(scan.root.size == tree.allocated("open/fine.bin"))
    }

    @Test("An unreadable root throws")
    func unreadableRoot() throws {
        #expect(throws: StorageScanError.self) {
            try runScan("/nonexistent-\(UUID().uuidString)")
        }
    }

    @Test("Small files are bucketed per folder; large ones keep their own node")
    func smallFileBuckets() throws {
        let tree = try ScratchTree()
        for index in 0 ..< 5 {
            try tree.file("many/small-\(index).txt", bytes: 100)
        }
        try tree.file("many/large.bin", bytes: 300_000)
        let scan = try runScan(tree.path, threshold: 200_000)
        let folder = try #require(scan.root.node(atPath: tree.path + "/many"))
        #expect(folder.children.count == 2)
        let bucket = try #require(folder.children.first { $0.kind == .smallFiles })
        #expect(bucket.fileCount == 5)
        #expect(bucket.name == "5 smaller files")
        #expect(folder.children.first { $0.kind == .file }?.name == "large.bin")
        #expect(scan.largestFiles.map(\.name) == ["large.bin"])
    }

    @Test("Categories come from the folder context first, then the UTType")
    func categoriesDuringScan() throws {
        let tree = try ScratchTree()
        try tree.file("Photos/beach.jpg", bytes: 20000)
        try tree.file("Tools.app/Contents/MacOS/Tools", bytes: 30000)
        try tree.file("Tools.app/Contents/Resources/icon.png", bytes: 5000)
        try tree.file("web/node_modules/left-pad/index.js", bytes: 4000)
        try tree.file("Library/Caches/blob.dat", bytes: 7000)
        let scan = try runScan(tree.path, home: tree.path)
        func bytes(_ category: StorageCategory) -> UInt64 {
            scan.categories.first { $0.category == category }?.bytes ?? 0
        }
        #expect(bytes(.photosAndVideo) == tree.allocated("Photos/beach.jpg"))
        #expect(bytes(.apps) == tree.allocated("Tools.app/Contents/MacOS/Tools") + tree.allocated("Tools.app/Contents/Resources/icon.png"))
        #expect(bytes(.developer) == tree.allocated("web/node_modules/left-pad/index.js"))
        #expect(bytes(.systemAndLibrary) == tree.allocated("Library/Caches/blob.dat"))
        #expect(scan.categories.count == StorageCategory.allCases.count)
    }

    @Test("Cancelling stops the scan and throws cancelled")
    func cancellation() throws {
        let tree = try ScratchTree()
        for index in 0 ..< 40 {
            try tree.file("f\(index)/g/file.txt", bytes: 10)
        }
        let engine = BulkScanEngine(
            root: tree.path,
            options: StorageScanOptions(home: "/x", fileNodeThreshold: 0),
            isCancelled: { true },
            progress: { _ in }
        )
        #expect(throws: StorageScanError.cancelled) {
            try engine.scan()
        }
    }

    @Test("The live stream reports progress and finishes; cancelling the consumer ends it")
    func liveStream() async throws {
        let tree = try ScratchTree()
        for index in 0 ..< 30 {
            try tree.file("d\(index)/file.bin", bytes: 1000)
        }
        let scanner = LiveStorageScanner(home: tree.root, fileNodeThreshold: 0)
        var finished: StorageScan?
        for try await event in scanner.scan(tree.root) {
            if case let .finished(scan) = event {
                finished = scan
            }
        }
        #expect(finished?.fileCount == 30)

        let task = Task {
            var events = 0
            for try await _ in scanner.scan(tree.root) {
                events += 1
            }
            return events
        }
        task.cancel()
        let outcome = await task.result
        switch outcome {
        case .success: break // It may finish before the cancel lands; either way it ends.
        case let .failure(error): #expect(error is CancellationError || error as? StorageScanError == .cancelled)
        }
    }

    @Test("Removing a path shrinks every ancestor")
    func removingPath() throws {
        let tree = try ScratchTree()
        try tree.file("a/b/big.bin", bytes: 300_000)
        try tree.file("a/keep.bin", bytes: 100_000)
        let scan = try runScan(tree.path)
        let removed = scan.removing(path: tree.path + "/a/b")
        #expect(removed.root.size == tree.allocated("a/keep.bin"))
        #expect(removed.root.node(atPath: tree.path + "/a/b") == nil)
        #expect(removed.largestFiles.map(\.name) == ["keep.bin"])
        #expect(removed.categoriesAreStale)
    }
}
