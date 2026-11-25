import Foundation
@testable import Storage
import Testing

/// Duplicate files (1.6): which copy stays, and what an extra one frees.
struct DuplicateFilesTests {
    let home = "/Users/robin"

    func candidate(_ path: String, created: TimeInterval, size: UInt64 = 5_000_000) -> DuplicateFiles.Candidate {
        DuplicateFiles.Candidate(
            path: path, size: size, created: Date(timeIntervalSince1970: created), modified: Date(timeIntervalSince1970: created)
        )
    }

    @Test("The kept copy: not the one in Downloads, then the oldest")
    func keeper() {
        let inDownloads = candidate("/Users/robin/Downloads/clip.mov", created: 100)
        let inMovies = candidate("/Users/robin/Movies/clip.mov", created: 200)
        let older = candidate("/Users/robin/Documents/clip.mov", created: 50)
        #expect(DuplicateFiles.keeper(of: [inDownloads, inMovies], home: home) == inMovies)
        #expect(DuplicateFiles.keeper(of: [inDownloads, inMovies, older], home: home) == older)
        #expect(DuplicateFiles.keeper(of: [inDownloads], home: home) == inDownloads)
    }

    @Test("Only sizes held by two files or more are compared")
    func sameSize() {
        let groups = DuplicateFiles.sameSize([
            candidate("/a", created: 1, size: 3_000_000), candidate("/b", created: 1, size: 3_000_000),
            candidate("/c", created: 1, size: 4_000_000),
        ])
        #expect(groups.count == 1)
        #expect(groups.first?.count == 2)
    }

    @Test("Same content hashes the same; a clone frees nothing, a real copy frees its size")
    func onDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dupes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("a.bin")
        var bytes = [UInt8](repeating: 0, count: 3_000_000)
        for index in bytes.indices {
            bytes[index] = UInt8(truncatingIfNeeded: index &* 31)
        }
        try Data(bytes).write(to: original)
        let copy = root.appendingPathComponent("b.bin")
        try Data(bytes).write(to: copy)
        let clone = root.appendingPathComponent("c.bin")
        #expect(copyfile(original.path, clone.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0)
        var changed = bytes
        changed[1_500_000] ^= 1
        let different = root.appendingPathComponent("d.bin")
        try Data(changed).write(to: different)

        #expect(DuplicateFiles.fullHash(original.path) == DuplicateFiles.fullHash(copy.path))
        #expect(DuplicateFiles.sample(original.path) == DuplicateFiles.sample(copy.path))
        #expect(DuplicateFiles.fullHash(original.path) != DuplicateFiles.fullHash(different.path))
        let copySize = try #require(DuplicateFiles.privateSize(copy.path))
        #expect(copySize >= 3_000_000)
        #expect(DuplicateFiles.privateSize(clone.path) == 0)
    }

    @Test("Before the Trash: the kept copy must still be there and the same; a hard link is no copy (D-251)")
    func stillCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dupes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data((0 ..< 300_000).map { UInt8($0 % 251) })
        let kept = root.appendingPathComponent("kept.bin").path
        let copy = root.appendingPathComponent("copy.bin").path
        let link = root.appendingPathComponent("link.bin").path
        try data.write(to: URL(fileURLWithPath: kept))
        try data.write(to: URL(fileURLWithPath: copy))
        try FileManager.default.linkItem(atPath: kept, toPath: link)
        #expect(DuplicateFiles.stillCopy(copy, of: kept))
        #expect(!DuplicateFiles.stillCopy(link, of: kept))
        #expect(!DuplicateFiles.stillCopy(kept, of: kept))
        let candidates = [kept, link, copy].map { path in
            DuplicateFiles.Candidate(
                path: path,
                size: 300_000,
                created: .distantPast,
                modified: .distantPast,
                file: DuplicateFiles.identity(path)?.file
            )
        }
        #expect(DuplicateFiles.distinctFiles(candidates).map(\.path) == [kept, copy])
        // The kept copy changed, or went: the duplicate stays.
        var changed = data
        changed[150_000] ^= 0xFF
        try changed.write(to: URL(fileURLWithPath: kept))
        #expect(!DuplicateFiles.stillCopy(copy, of: kept))
        try FileManager.default.removeItem(atPath: kept)
        #expect(!DuplicateFiles.stillCopy(copy, of: kept))
    }
}
