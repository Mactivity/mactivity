import Foundation
@testable import Storage
import Testing

/// What grew between two scans (D-208).
struct FolderGrowthTests {
    private let home = "/Users/k"
    private let gb: UInt64 = 1_000_000_000

    private func sizes(_ values: [String: Double], at: TimeInterval = 0) -> FolderSizes {
        FolderSizes(
            root: home, scannedAt: Date(timeIntervalSince1970: at),
            sizes: values.reduce(into: [:]) { $0[home + $1.key] = UInt64($1.value * 1e9) }
        )
    }

    @Test("The deepest folder that explains the growth, not every folder above it")
    func deepest() {
        let old = sizes([
            "": 100,
            "/Library": 40,
            "/Library/Developer": 20,
            "/Library/Developer/Xcode/DerivedData": 10,
            "/Library/Developer/Xcode": 12,
            "/Downloads": 5,
        ])
        let new = sizes([
            "": 112.5,
            "/Library": 49.2,
            "/Library/Developer": 29.2,
            "/Library/Developer/Xcode/DerivedData": 19.2,
            "/Library/Developer/Xcode": 21.2,
            "/Downloads": 8.1,
        ])
        let growth = FolderGrowthLog.growth(from: old, to: new)
        #expect(growth.map(\.name) == ["DerivedData", "Downloads"])
        #expect(growth.first?.grew == UInt64(9.2e9))
        #expect(growth.first?.before == 10 * gb)
    }

    @Test("A parent is named too when it grew beyond the folders listed inside it")
    func parentRemainder() {
        let old = sizes(["": 50, "/Library": 20, "/Library/Caches": 2])
        let new = sizes(["": 56, "/Library": 26, "/Library/Caches": 4])
        let growth = FolderGrowthLog.growth(from: old, to: new)
        // Caches +2, then Library +4 beyond it; the home folder has nothing left.
        #expect(growth.map(\.name) == ["Library", "Caches"])
        #expect(growth.first?.grew == 4 * gb)
    }

    @Test("A new folder counts from nothing; small growth and another place don't count")
    func edges() {
        let old = sizes(["": 50])
        let new = sizes(["": 53, "/Movies": 3, "/Notes": 0.3])
        #expect(FolderGrowthLog.growth(from: old, to: new).map(\.name) == ["Movies"])
        #expect(FolderGrowthLog.growth(from: old, to: new).first?.before == nil)
        let elsewhere = FolderSizes(root: "/", scannedAt: Date(), sizes: ["/": 900 * gb])
        #expect(FolderGrowthLog.growth(from: elsewhere, to: new).isEmpty)
    }

    @Test("A scan's sizes: folders of 200 MB or more, six levels down")
    func fromScan() {
        func dir(_ path: String, _ children: [StorageNode]) -> StorageNode {
            .directory(name: (path as NSString).lastPathComponent, path: path, children: children)
        }
        func file(_ path: String, _ size: UInt64) -> StorageNode {
            StorageNode(name: (path as NSString).lastPathComponent, path: path, kind: .file, size: size, fileCount: 1)
        }
        let root = dir(home, [
            dir(home + "/Big", [file(home + "/Big/a.mov", 3 * gb)]),
            dir(home + "/Small", [file(home + "/Small/b.txt", 1000)]),
        ])
        let scan = StorageScan(
            root: root, startedAt: Date(), duration: .seconds(1), fileCount: 2, directoryCount: 3, categories: [],
            largestFiles: [], unreadable: [], skipped: [], home: home
        )
        let kept = FolderGrowthLog.sizes(scan)
        #expect(Set(kept.sizes.keys) == [home, home + "/Big"])
    }

    @Test("The file gives back the last sizes for the same place and keeps the new ones")
    func file() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sizes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FolderGrowthLog.exchange(sizes(["": 10], at: 1), at: url) == nil)
        let other = FolderSizes(root: "/", scannedAt: Date(), sizes: ["/": 1])
        #expect(FolderGrowthLog.exchange(other, at: url) == nil)
        #expect(FolderGrowthLog.exchange(sizes(["": 12], at: 2), at: url) == sizes(["": 10], at: 1))
    }
}
