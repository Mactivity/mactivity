import Foundation

/// One line of the kernel's mount table (`getfsstat` with `MNT_NOWAIT`): what's mounted and the
/// figures it last had, without asking any drive or server.
public struct MountEntry: Hashable, Sendable {
    public let path: String
    public let fileSystem: String
    /// `f_mntfromname`: "/dev/disk5s1", "//user@nas.local/Media", "nas.local:/export".
    public let source: String
    public let isLocal: Bool
    /// Finder shows it: not a system volume or one mounted out of sight.
    public let isBrowsable: Bool
    public let totalBytes: UInt64
    public let availableBytes: UInt64

    public init(
        path: String, fileSystem: String, source: String, isLocal: Bool, isBrowsable: Bool, totalBytes: UInt64, availableBytes: UInt64
    ) {
        self.path = path
        self.fileSystem = fileSystem
        self.source = source
        self.isLocal = isLocal
        self.isBrowsable = isBrowsable
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

/// Space on a mounted volume.
public struct DriveSpace: Hashable, Sendable, Codable {
    public let totalBytes: UInt64
    public let availableBytes: UInt64

    public init(totalBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

// MARK: External drives

/// A drive you plug in (D-284), remembered after it's unplugged. Its contents are never read.
public struct ExternalDrive: Hashable, Sendable, Codable, Identifiable {
    /// What the drive says about its own health, as far as its connection lets it.
    public enum Health: String, Hashable, Sendable, Codable {
        case good, wearing, failing
        /// Most USB enclosures don't pass the drive's own report through.
        case notReported
    }

    /// The volume's UUID, so a renamed drive stays itself.
    public let id: String
    public var name: String
    /// "APFS", "ExFAT".
    public var format: String
    /// "Samsung PSSD T7".
    public var model: String?
    /// "USB", "Thunderbolt".
    public var connection: String?
    public var space: DriveSpace
    public var health: Health
    /// Rated life used, from a drive that reports NVMe SMART.
    public var percentUsed: Int?
    public var lastSeen: Date
    /// Plugged in now. What the file says about this means nothing: each read sets it.
    public var isConnected: Bool

    public init(
        id: String, name: String, format: String, model: String?, connection: String?, space: DriveSpace, health: Health,
        percentUsed: Int?, lastSeen: Date, isConnected: Bool
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.model = model
        self.connection = connection
        self.space = space
        self.health = health
        self.percentUsed = percentUsed
        self.lastSeen = lastSeen
        self.isConnected = isConnected
    }
}

/// What `diskutil info -plist` says about a mounted volume, as far as it matters here.
public struct DiskInfo: Hashable, Sendable {
    public let volumeUUID: String?
    public let name: String?
    public let format: String?
    public let model: String?
    public let connection: String?
    public let isInternal: Bool
    public let smartStatus: String?
    /// An APFS volume's own entry has no model: "disk5s2", the partition that has.
    public let physicalStore: String?

    public init(
        volumeUUID: String?, name: String?, format: String?, model: String?, connection: String?, isInternal: Bool, smartStatus: String?,
        physicalStore: String? = nil
    ) {
        self.volumeUUID = volumeUUID
        self.name = name
        self.format = format
        self.model = model
        self.connection = connection
        self.isInternal = isInternal
        self.smartStatus = smartStatus
        self.physicalStore = physicalStore
    }

    /// The same, with the model read from its physical store's entry.
    public func withModel(_ model: String?) -> DiskInfo {
        DiskInfo(
            volumeUUID: volumeUUID, name: name, format: format, model: model, connection: connection, isInternal: isInternal,
            smartStatus: smartStatus, physicalStore: physicalStore
        )
    }

    /// Pure, from the plist's data. Nil for anything that isn't a dictionary: the keys are
    /// `diskutil`'s and a future one could change them, which must read as "don't know".
    public static func parse(plist data: Data) -> DiskInfo? {
        guard let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        return DiskInfo(
            volumeUUID: dictionary["VolumeUUID"] as? String,
            name: (dictionary["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            format: (dictionary["FilesystemName"] as? String) ?? (dictionary["FilesystemType"] as? String),
            model: (dictionary["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            connection: dictionary["BusProtocol"] as? String,
            isInternal: (dictionary["Internal"] as? Bool) ?? true,
            smartStatus: dictionary["SMARTStatus"] as? String,
            physicalStore: (dictionary["APFSPhysicalStores"] as? [[String: Any]])?.first?["APFSPhysicalStore"] as? String
        )
    }

    /// A physical drive plugged in: not the Mac's own, and not a disk image someone opened, which
    /// mounts in the same place. When `diskutil` doesn't say, it doesn't count.
    public var isExternalDrive: Bool {
        !isInternal && connection != nil && connection != "Disk Image" && connection != "Virtual Interface"
    }
}

public enum ExternalDrives {
    /// Pure: what could be a plugged-in drive, by the mount table alone.
    public static func candidates(_ entries: [MountEntry]) -> [MountEntry] {
        entries.filter { $0.isLocal && $0.isBrowsable && $0.path.hasPrefix("/Volumes/") && $0.source.hasPrefix("/dev/") }
    }

    /// Pure: the drive's verdict, from its own NVMe report if it passes one through, or from
    /// the SMART status `diskutil` gives.
    public static func health(smartStatus: String?, report: DriveHealth?) -> (ExternalDrive.Health, percentUsed: Int?) {
        if let report {
            switch report.verdict {
            case .good: return (.good, report.percentUsed)
            case .worn: return (.wearing, report.percentUsed)
            case .failing: return (.failing, report.percentUsed)
            }
        }
        switch smartStatus?.lowercased() {
        case "verified": return (.good, nil)
        case "failing", "about to fail": return (.failing, nil)
        default: return (.notReported, nil)
        }
    }

    /// Pure: a drive's own report, only when exactly one external drive of that model answers and
    /// one is plugged in. Two of the same can't be told apart, and a wrong verdict is worse than none.
    public static func report(for model: String?, reports: [DriveHealth], mountedModels: [String?]) -> DriveHealth? {
        guard let model else {
            return nil
        }
        let matching = reports.filter { !$0.isInternal && $0.model == model }
        return matching.count == 1 && mountedModels.count(where: { $0 == model }) == 1 ? matching.first : nil
    }

    /// Pure: the drives to show and to keep. What's plugged in replaces what was remembered of it;
    /// the rest stay as last seen. Plugged in first, then most recently seen; the oldest beyond
    /// `limit` are forgotten so the file stays small.
    public static func merged(remembered: [ExternalDrive], connected: [ExternalDrive], limit: Int = 40) -> [ExternalDrive] {
        let ids = Set(connected.map(\.id))
        var gone = remembered.filter { !ids.contains($0.id) }
        for index in gone.indices {
            gone[index].isConnected = false
        }
        let all = connected.sorted { $0.name < $1.name } + gone.sorted { ($0.lastSeen, $1.name) > ($1.lastSeen, $0.name) }
        return Array(all.prefix(max(limit, connected.count)))
    }
}

// MARK: Network drives

/// A shared folder or NAS volume (D-285).
public struct NetworkDrive: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case smb, nfs, afp, webdav, other

        public static func of(fileSystem: String) -> Kind {
            switch fileSystem.lowercased() {
            case "smbfs": .smb
            case "nfs": .nfs
            case "afpfs": .afp
            case "webdav": .webdav
            default: .other
            }
        }

        public var title: String {
            switch self {
            case .smb: "SMB"
            case .nfs: "NFS"
            case .afp: "AFP"
            case .webdav: "WebDAV"
            case .other: String(localized: "Network", bundle: .strings, comment: "A network drive of an unknown kind")
            }
        }
    }

    public enum Status: Hashable, Sendable {
        case responding(DriveSpace)
        /// A read didn't come back in time. The mount table's figure, if it has one, is old.
        case notResponding(lastKnown: DriveSpace?)
    }

    public var id: String {
        path
    }

    public let path: String
    public let name: String
    /// "nas.local"; never the user name a mount source can carry.
    public let server: String?
    public let kind: Kind
    public let status: Status

    public init(path: String, name: String, server: String?, kind: Kind, status: Status) {
        self.path = path
        self.name = name
        self.server = server
        self.kind = kind
        self.status = status
    }
}

public enum NetworkDrives {
    /// Pure: network mounts in the mount table. `autofs` is the automounter's placeholder, not a
    /// share, and hidden mounts are the system's.
    public static func mounts(_ entries: [MountEntry]) -> [MountEntry] {
        entries.filter { !$0.isLocal && $0.isBrowsable && $0.fileSystem != "autofs" }
    }

    /// Pure: the server in a mount source, without its user name or password:
    /// "//me:secret@nas.local/Media", "nas.local:/export/media", "https://me@dav.example.com/x".
    public static func server(fromSource source: String) -> String? {
        var text = source
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        } else if text.hasPrefix("//") {
            text = String(text.dropFirst(2))
        }
        // "user@host", with anything before the last "@" being who, not where.
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        let host = text.prefix { $0 != "/" && $0 != ":" }
        let decoded = String(host).removingPercentEncoding ?? String(host)
        return decoded.isEmpty ? nil : decoded
    }
}

/// How busy NFS is, from `nfsstat -c -f JSON`: READ and WRITE calls for every NFS share together.
/// macOS keeps no count per share for NFS, and none at all for SMB, AFP or WebDAV (D-285).
public struct NFSCounters: Hashable, Sendable {
    public let reads: UInt64
    public let writes: UInt64

    public init(reads: UInt64, writes: UInt64) {
        self.reads = reads
        self.writes = writes
    }

    /// Pure. Nil when the shape isn't what it was: an undocumented format can change.
    public static func parse(json data: Data) -> NFSCounters? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let client = root["Client Info"] as? [String: Any]
        else {
            return nil
        }
        var reads: UInt64 = 0
        var writes: UInt64 = 0
        var found = false
        for section in ["NFSv3 RPC Counts", "NFSv4 Operation Counts"] {
            if let counts = client[section] as? [String: Any], let read = counts["Read"] as? NSNumber,
               let write = counts["Write"] as? NSNumber {
                reads += read.uint64Value
                writes += write.uint64Value
                found = true
            }
        }
        return found ? NFSCounters(reads: reads, writes: writes) : nil
    }

    /// Pure: calls a second between two readings. Nil if the counters went back (they can be
    /// reset) or no time passed.
    public static func rate(from earlier: NFSCounters, to later: NFSCounters, seconds: TimeInterval) -> (reads: Double, writes: Double)? {
        guard seconds > 0, later.reads >= earlier.reads, later.writes >= earlier.writes else {
            return nil
        }
        return (Double(later.reads - earlier.reads) / seconds, Double(later.writes - earlier.writes) / seconds)
    }
}

public protocol MountedDriveSource: Sendable {
    /// External drives plugged in now and those remembered; notes what's plugged in. Only reads
    /// when asked: when the card shows, and when macOS says something mounted.
    func externalDrives() async -> [ExternalDrive]
    /// Takes a remembered drive off the list, until it's plugged in again.
    func forgetExternalDrive(id: String) async
    /// Network mounts now. A dead one reads as not responding, and never holds anything up.
    func networkDrives() async -> [NetworkDrive]
    /// NFS's counters, when there's an NFS share to count for. Nil otherwise.
    func nfsCounters() async -> NFSCounters?
}
