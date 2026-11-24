import Core
import Foundation

/// A backup drive plugged in, another last seen a while ago, and two shares, one of them dead:
/// for previews, tests and simulated data. Nothing is written anywhere.
public actor SimulatedMountedDrives: MountedDriveSource {
    private var external: [ExternalDrive]
    private let network: [NetworkDrive]
    private var nfs = NFSCounters(reads: 1_000_000, writes: 200_000)

    public init(external: [ExternalDrive]? = nil, network: [NetworkDrive]? = nil) {
        let now = Date()
        self.external = external ?? [
            ExternalDrive(
                id: "sim-backup", name: "Backup", format: "APFS", model: "Samsung PSSD T7", connection: "USB",
                space: DriveSpace(totalBytes: 2_000_000_000_000, availableBytes: 812_000_000_000), health: .notReported, percentUsed: nil,
                lastSeen: now, isConnected: true
            ),
            ExternalDrive(
                id: "sim-archive", name: "Archive", format: "ExFAT", model: "WD My Passport", connection: "USB",
                space: DriveSpace(totalBytes: 4_000_000_000_000, availableBytes: 1_250_000_000_000), health: .good, percentUsed: nil,
                lastSeen: now.addingTimeInterval(-12 * 86400), isConnected: false
            ),
        ]
        self.network = network ?? [
            NetworkDrive(
                path: "/Volumes/Media", name: "Media", server: "nas.local", kind: .smb,
                status: .responding(DriveSpace(totalBytes: 8_000_000_000_000, availableBytes: 2_100_000_000_000))
            ),
            NetworkDrive(
                path: "/Volumes/Projects", name: "Projects", server: "fileserver.local", kind: .nfs,
                status: .notResponding(lastKnown: DriveSpace(totalBytes: 2_000_000_000_000, availableBytes: 500_000_000_000))
            ),
        ]
    }

    public func externalDrives() async -> [ExternalDrive] {
        external
    }

    public func forgetExternalDrive(id: String) async {
        external.removeAll { $0.id == id }
    }

    public func networkDrives() async -> [NetworkDrive] {
        network
    }

    public func nfsCounters() async -> NFSCounters? {
        nfs = NFSCounters(reads: nfs.reads + 40, writes: nfs.writes + 10)
        return nfs
    }
}
