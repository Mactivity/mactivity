import Core
import Foundation
@testable import Sensors
import Testing

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
    }
}

private struct NoReports: DriveHealthSource {
    func drives() async -> [DriveHealth] {
        []
    }
}

@Suite("External and network drives (D-284, D-285)")
struct MountedDrivesTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Fixtures.directory.appendingPathComponent(name))
    }

    private func entry(
        _ path: String, fs: String = "apfs", source: String = "/dev/disk5s1", local: Bool = true, browsable: Bool = true,
        total: UInt64 = 1000, available: UInt64 = 400
    ) -> MountEntry {
        MountEntry(
            path: path, fileSystem: fs, source: source, isLocal: local, isBrowsable: browsable, totalBytes: total, availableBytes: available
        )
    }

    private func info(
        uuid: String? = "UUID-1", name: String = "Backup", model: String? = "Samsung PSSD T7", connection: String? = "USB",
        isInternal: Bool = false, smart: String? = "Not Supported"
    ) -> DiskInfo {
        DiskInfo(
            volumeUUID: uuid, name: name, format: "APFS", model: model, connection: connection, isInternal: isInternal, smartStatus: smart
        )
    }

    private func report(_ model: String, isInternal: Bool = false, percent: Int = 3, warning: Int = 0) -> DriveHealth {
        DriveHealth(
            index: 0, model: model, isInternal: isInternal, percentUsed: percent, availableSpare: 100, spareThreshold: 10,
            criticalWarning: warning, temperatureCelsius: nil, bytesRead: 0, bytesWritten: 0, powerOnHours: 1, unsafeShutdowns: 0,
            mediaErrors: 0
        )
    }

    // MARK: diskutil, real output

    @Test("A disk image from this Mac: mounted like a drive, and not one")
    func diskImage() throws {
        let parsed = try #require(DiskInfo.parse(plist: fixture("diskutil-info-disk-image.plist")))
        #expect(parsed.connection == "Disk Image")
        #expect(!parsed.isInternal)
        #expect(!parsed.isExternalDrive)
        #expect(parsed.physicalStore != nil)
    }

    @Test("This Mac's own volume isn't external, and has no model of its own")
    func bootVolume() throws {
        let parsed = try #require(DiskInfo.parse(plist: fixture("diskutil-info-boot-volume.plist")))
        #expect(parsed.isInternal)
        #expect(!parsed.isExternalDrive)
        #expect(parsed.smartStatus == "Verified")
        #expect(parsed.model == nil)
        #expect(parsed.physicalStore == "disk0s2")
        #expect(parsed.name == "Macintosh HD")
        #expect(parsed.format == "APFS")
    }

    @Test("Output that isn't what's expected reads as don't know, never as a drive")
    func odd() {
        #expect(DiskInfo.parse(plist: Data("not a plist".utf8)) == nil)
        let empty = try? PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
        let parsed = empty.flatMap { DiskInfo.parse(plist: $0) }
        #expect(parsed?.isExternalDrive == false)
    }

    // MARK: External

    @Test("Candidates: mounted in /Volumes from a device, shown in Finder")
    func candidates() {
        let found = ExternalDrives.candidates([
            entry("/"), entry("/Volumes/Backup"), entry("/Volumes/Recovery", browsable: false),
            entry("/Volumes/Media", fs: "smbfs", source: "//nas/Media", local: false), entry("/System/Volumes/Data"),
            entry("/Volumes/Odd", fs: "fskit", source: "map auto"),
        ])
        #expect(found.map(\.path) == ["/Volumes/Backup"])
    }

    @Test("Health: the drive's own report, its SMART status, or plainly nothing")
    func health() {
        #expect(ExternalDrives.health(smartStatus: "Verified", report: nil) == (.good, nil))
        #expect(ExternalDrives.health(smartStatus: "Failing", report: nil) == (.failing, nil))
        #expect(ExternalDrives.health(smartStatus: "About to Fail", report: nil) == (.failing, nil))
        #expect(ExternalDrives.health(smartStatus: "Not Supported", report: nil) == (.notReported, nil))
        #expect(ExternalDrives.health(smartStatus: nil, report: nil) == (.notReported, nil))
        #expect(ExternalDrives.health(smartStatus: "Not Supported", report: report("T", percent: 3)) == (.good, 3))
        #expect(ExternalDrives.health(smartStatus: "Verified", report: report("T", percent: 85)) == (.wearing, 85))
        #expect(ExternalDrives.health(smartStatus: "Verified", report: report("T", warning: 4)) == (.failing, 3))
    }

    @Test("A report only when it can only be that drive's")
    func reportMatching() {
        let one = report("T7")
        #expect(ExternalDrives.report(for: "T7", reports: [one], mountedModels: ["T7"]) == one)
        #expect(ExternalDrives.report(for: "T7", reports: [one, one], mountedModels: ["T7"]) == nil)
        #expect(ExternalDrives.report(for: "T7", reports: [one], mountedModels: ["T7", "T7"]) == nil)
        #expect(ExternalDrives.report(for: "T7", reports: [report("T7", isInternal: true)], mountedModels: ["T7"]) == nil)
        #expect(ExternalDrives.report(for: nil, reports: [one], mountedModels: [nil]) == nil)
    }

    @Test("Remembered, with plugged-in drives first and refreshed, and a limit")
    func merge() {
        let old = Date(timeIntervalSince1970: 1000)
        func drive(_ id: String, seen: Date, connected: Bool, free: UInt64 = 1) -> ExternalDrive {
            ExternalDrive(
                id: id, name: id, format: "APFS", model: nil, connection: "USB", space: DriveSpace(totalBytes: 10, availableBytes: free),
                health: .notReported, percentUsed: nil, lastSeen: seen, isConnected: connected
            )
        }
        let merged = ExternalDrives.merged(
            remembered: [drive("a", seen: old, connected: true), drive("b", seen: old.addingTimeInterval(9), connected: false)],
            connected: [
                drive("c", seen: old.addingTimeInterval(99), connected: true),
                drive("b", seen: old.addingTimeInterval(99), connected: true, free: 7),
            ]
        )
        #expect(merged.map(\.id) == ["b", "c", "a"])
        #expect(merged[0].space.availableBytes == 7)
        #expect(merged[2].isConnected == false, "a drive no longer listed isn't plugged in, whatever the file says")
        let many = (0 ..< 50).map { drive("d\($0)", seen: old.addingTimeInterval(Double($0)), connected: false) }
        let trimmed = ExternalDrives.merged(remembered: many, connected: [], limit: 40)
        #expect(trimmed.count == 40)
        #expect(trimmed.first?.id == "d49")
    }

    @Test("A drive plugged in is remembered in the file, shown after it's gone, and can be forgotten")
    func memory() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drives-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("external-drives.json")
        let mounted = OSLockedEntries([entry("/Volumes/Backup"), entry("/Volumes/Some Image")])
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let source = LiveMountedDrives(
            memory: file, health: NoReports(), table: { mounted.value },
            info: { path in
                path == "/Volumes/Backup"
                    ? DiskInfo(
                        volumeUUID: "UUID-1", name: "Backup", format: "APFS", model: "T7", connection: "USB", isInternal: false,
                        smartStatus: "Not Supported"
                    )
                    : DiskInfo(
                        volumeUUID: "UUID-2", name: "Some Image", format: "APFS", model: nil, connection: "Disk Image", isInternal: false,
                        smartStatus: nil
                    )
            },
            read: { _ in DriveSpace(totalBytes: 2000, availableBytes: 900) }, timeout: .seconds(1), now: { first }
        )
        let plugged = await source.externalDrives()
        #expect(plugged.map(\.name) == ["Backup"])
        #expect(plugged.first?.isConnected == true)
        #expect(plugged.first?.space.availableBytes == 900)
        #expect(FileManager.default.fileExists(atPath: file.path))

        mounted.value = []
        let afterwards = LiveMountedDrives(
            memory: file, health: NoReports(), table: { mounted.value }, info: { _ in nil }, read: { _ in nil }, timeout: .seconds(1),
            now: { first.addingTimeInterval(86400) }
        )
        let gone = await afterwards.externalDrives()
        #expect(gone.map(\.name) == ["Backup"])
        #expect(gone.first?.isConnected == false)
        #expect(gone.first?.lastSeen == first)
        #expect(gone.first?.space.availableBytes == 900)

        await afterwards.forgetExternalDrive(id: "UUID-1")
        #expect(await afterwards.externalDrives().isEmpty)
    }

    // MARK: Network

    @Test("Network mounts: not local, not the automounter's placeholder, not hidden")
    func networkMounts() {
        let found = NetworkDrives.mounts([
            entry("/"), entry("/Volumes/Media", fs: "smbfs", source: "//nas/Media", local: false),
            entry("/home", fs: "autofs", source: "map auto_home", local: false),
            entry("/Volumes/Hidden", fs: "nfs", source: "s:/x", local: false, browsable: false),
        ])
        #expect(found.map(\.path) == ["/Volumes/Media"])
        #expect(NetworkDrive.Kind.of(fileSystem: "smbfs") == .smb)
        #expect(NetworkDrive.Kind.of(fileSystem: "nfs") == .nfs)
        #expect(NetworkDrive.Kind.of(fileSystem: "afpfs") == .afp)
        #expect(NetworkDrive.Kind.of(fileSystem: "webdav") == .webdav)
        #expect(NetworkDrive.Kind.of(fileSystem: "exfat") == .other)
    }

    @Test("The server's name, and never who's logged in or their password")
    func servers() {
        #expect(NetworkDrives.server(fromSource: "//nas.local/Media") == "nas.local")
        #expect(NetworkDrives.server(fromSource: "//robin@nas.local/Media") == "nas.local")
        #expect(NetworkDrives.server(fromSource: "//robin:secret@nas.local/Media") == "nas.local")
        #expect(NetworkDrives.server(fromSource: "//WORK;robin@files.example.com/Share") == "files.example.com")
        #expect(NetworkDrives.server(fromSource: "nas.local:/export/media") == "nas.local")
        #expect(NetworkDrives.server(fromSource: "https://robin@dav.example.com/files") == "dav.example.com")
        #expect(NetworkDrives.server(fromSource: "afp://robin@time.local/Backups") == "time.local")
        #expect(NetworkDrives.server(fromSource: "") == nil)
    }

    @Test("A mount that never answers reads as not responding quickly, with only one thread stuck on it")
    func deadMount() async {
        let release = DispatchSemaphore(value: 0)
        let reads = Counter()
        let reader = MountReader(timeout: .milliseconds(100)) { _ in
            reads.add()
            if reads.count == 1 {
                release.wait()
            }
            return DriveSpace(totalBytes: 10, availableBytes: 5)
        }
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await reader.read("/Volumes/Dead") == .notResponding)
        #expect(clock.now - started < .seconds(2))
        // Already stuck: answered at once, without another thread.
        #expect(await reader.read("/Volumes/Dead") == .notResponding)
        #expect(reads.count == 1)
        release.signal()
        // Once the read comes back, the mount can be read again.
        var outcome = MountReader.Outcome.notResponding
        for _ in 0 ..< 200 where outcome == .notResponding {
            try? await Task.sleep(for: .milliseconds(5))
            outcome = await reader.read("/Volumes/Dead")
        }
        #expect(outcome == .figures(DriveSpace(totalBytes: 10, availableBytes: 5)))
    }

    @Test("A dead share among good ones: the list still comes back, with it marked, and no user name in it")
    func listWithDeadShare() async {
        let hold = DispatchSemaphore(value: 0)
        defer { hold.signal() }
        let entries = [
            entry("/Volumes/Good", fs: "smbfs", source: "//robin@nas.local/Good", local: false),
            entry("/Volumes/Dead", fs: "nfs", source: "old.local:/x", local: false, total: 800, available: 300),
        ]
        let source = LiveMountedDrives(
            memory: nil, health: NoReports(), table: { entries }, info: { _ in nil },
            read: { path in
                if path == "/Volumes/Dead" {
                    hold.wait()
                }
                return DriveSpace(totalBytes: 100, availableBytes: 40)
            },
            timeout: .milliseconds(100), now: { Date() }
        )
        let drives = await source.networkDrives()
        #expect(drives.map(\.name) == ["Dead", "Good"])
        #expect(drives[0].status == .notResponding(lastKnown: DriveSpace(totalBytes: 800, availableBytes: 300)))
        #expect(drives[1].status == .responding(DriveSpace(totalBytes: 100, availableBytes: 40)))
        #expect(drives[1].server == "nas.local")
    }

    @Test("The mount table can be read here, and every browsable local mount has a path")
    func liveTable() {
        let entries = MountTable.read()
        #expect(entries.contains { $0.path == "/" && $0.isLocal })
    }

    // MARK: NFS

    @Test("NFS counters, from this Mac's real output with nothing mounted")
    func nfsIdle() throws {
        let counters = try NFSCounters.parse(json: fixture("nfsstat-client-idle.json"))
        #expect(counters == NFSCounters(reads: 0, writes: 0))
    }

    @Test("NFS counters add v3 and v4; a different shape reads as nothing")
    func nfsParse() {
        let json = #"{"Client Info":{"NFSv3 RPC Counts":{"Read":10,"Write":4},"NFSv4 Operation Counts":{"Read":1,"Write":2}}}"#
        #expect(NFSCounters.parse(json: Data(json.utf8)) == NFSCounters(reads: 11, writes: 6))
        #expect(NFSCounters.parse(json: Data("{}".utf8)) == nil)
        #expect(NFSCounters.parse(json: Data(#"{"Client Info":{"Other":{}}}"#.utf8)) == nil)
        #expect(NFSCounters.parse(json: Data("nonsense".utf8)) == nil)
    }

    @Test("NFS rate between two readings; a reset gives nothing, not a wild figure")
    func nfsRate() throws {
        let rate = try #require(
            NFSCounters.rate(from: NFSCounters(reads: 100, writes: 10), to: NFSCounters(reads: 200, writes: 30), seconds: 10)
        )
        #expect(rate.reads == 10)
        #expect(rate.writes == 2)
        #expect(NFSCounters.rate(from: NFSCounters(reads: 100, writes: 10), to: NFSCounters(reads: 5, writes: 30), seconds: 10) == nil)
        #expect(NFSCounters.rate(from: NFSCounters(reads: 0, writes: 0), to: NFSCounters(reads: 5, writes: 3), seconds: 0) == nil)
    }
}

private final class OSLockedEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [MountEntry]

    init(_ entries: [MountEntry]) {
        self.entries = entries
    }

    var value: [MountEntry] {
        get { lock.withLock { entries } }
        set { lock.withLock { entries = newValue } }
    }
}
