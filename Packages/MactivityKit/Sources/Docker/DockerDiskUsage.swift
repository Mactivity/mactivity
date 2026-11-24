import Foundation

/// Docker disk use (1.4, D-224): what the engine's images, volumes, build cache and stopped
/// containers take, what of each nothing uses, and the command that reclaims it, for the user to
/// run. Mactivity never runs them: pruning deletes for good, and the Trash can't hold an image.
public struct DockerDiskUsage: Sendable, Hashable {
    public enum Part: String, Sendable, Hashable, CaseIterable, Identifiable {
        case images, volumes, buildCache, containers

        public var id: String {
            rawValue
        }

        /// What reclaims the unused part, as `docker system df` counts it.
        public var command: String {
            switch self {
            case .images: "docker image prune -a"
            case .volumes: "docker volume prune -a"
            // `-a`: without it only dangling cache goes, less than what's counted here.
            case .buildCache: "docker builder prune -a"
            case .containers: "docker container prune"
            }
        }
    }

    public struct Total: Sendable, Hashable {
        public let part: Part
        public let count: Int
        public let bytes: UInt64
        /// Not used by any container (or, for build cache, by any build).
        public let reclaimable: UInt64
    }

    /// One compose project's share: its images, volumes and containers.
    public struct ProjectShare: Sendable, Hashable, Identifiable {
        public let project: String
        public let bytes: UInt64

        public var id: String {
            project
        }
    }

    public let totals: [Total]
    /// Largest first; only compose projects (their label), not loose images.
    public let projects: [ProjectShare]

    public var bytes: UInt64 {
        totals.reduce(0) { $0 &+ $1.bytes }
    }

    public var reclaimable: UInt64 {
        totals.reduce(0) { $0 &+ $1.reclaimable }
    }

    public init(totals: [Total], projects: [ProjectShare]) {
        self.totals = totals
        self.projects = projects
    }
}

/// `GET /system/df`, the fields Mactivity reads.
struct SystemDiskPayload: Decodable {
    let layersSize: Int64?
    let images: [DiskImagePayload]?
    let containers: [DiskContainerPayload]?
    let volumes: [DiskVolumePayload]?
    let buildCache: [BuildRecordPayload]?

    enum CodingKeys: String, CodingKey {
        case layersSize = "LayersSize"
        case images = "Images"
        case containers = "Containers"
        case volumes = "Volumes"
        case buildCache = "BuildCache"
    }
}

struct DiskImagePayload: Decodable {
    let size: Int64?
    let sharedSize: Int64?
    let containers: Int?
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case size = "Size"
        case sharedSize = "SharedSize"
        case containers = "Containers"
        case labels = "Labels"
    }
}

struct DiskContainerPayload: Decodable {
    let sizeRw: Int64?
    let state: String?
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case sizeRw = "SizeRw"
        case state = "State"
        case labels = "Labels"
    }
}

struct DiskVolumePayload: Decodable {
    let labels: [String: String]?
    let usageData: DiskVolumeUsagePayload?

    enum CodingKeys: String, CodingKey {
        case labels = "Labels"
        case usageData = "UsageData"
    }
}

struct DiskVolumeUsagePayload: Decodable {
    let size: Int64?
    let refCount: Int?

    enum CodingKeys: String, CodingKey {
        case size = "Size"
        case refCount = "RefCount"
    }
}

struct BuildRecordPayload: Decodable {
    let size: Int64?
    let inUse: Bool?
    let shared: Bool?

    enum CodingKeys: String, CodingKey {
        case size = "Size"
        case inUse = "InUse"
        case shared = "Shared"
    }
}

/// Pure: the payload as totals, the way `docker system df` adds it up.
public enum DockerDiskMath {
    static let composeProject = "com.docker.compose.project"

    static func usage(_ payload: SystemDiskPayload) -> DockerDiskUsage {
        func bytes(_ value: Int64?) -> UInt64 {
            UInt64(max(0, value ?? 0))
        }
        let images = payload.images ?? []
        // Images share layers: the total is the layers' size, and an image in use keeps its
        // own (unshared) part.
        let imageTotal = payload.layersSize.map(bytes) ?? images.reduce(0) { $0 &+ bytes($1.size) }
        // An image whose shared size the engine didn't compute (-1) is skipped, as the CLI does.
        let imagesInUse = images.filter { ($0.containers ?? 0) > 0 && ($0.sharedSize ?? 0) >= 0 }
            .reduce(UInt64(0)) { $0 &+ bytes($1.size) &- min(bytes($1.size), bytes($1.sharedSize)) }
        let containers = payload.containers ?? []
        let volumes = (payload.volumes ?? []).filter { ($0.usageData?.size ?? -1) >= 0 }
        let cache = payload.buildCache ?? []
        let totals: [DockerDiskUsage.Total] = [
            .init(
                part: .images,
                count: images.count,
                bytes: imageTotal,
                reclaimable: imageTotal > imagesInUse ? imageTotal - imagesInUse : 0
            ),
            .init(
                part: .volumes, count: volumes.count, bytes: volumes.reduce(0) { $0 &+ bytes($1.usageData?.size) },
                reclaimable: volumes.filter { ($0.usageData?.refCount ?? 0) == 0 }.reduce(0) { $0 &+ bytes($1.usageData?.size) }
            ),
            .init(
                part: .buildCache, count: cache.count, bytes: cache.filter { $0.shared != true }.reduce(0) { $0 &+ bytes($1.size) },
                reclaimable: cache.filter { $0.inUse != true && $0.shared != true }.reduce(0) { $0 &+ bytes($1.size) }
            ),
            .init(
                part: .containers, count: containers.count, bytes: containers.reduce(0) { $0 &+ bytes($1.sizeRw) },
                reclaimable: containers.filter { $0.state?.lowercased() != "running" }.reduce(0) { $0 &+ bytes($1.sizeRw) }
            ),
        ]
        var byProject: [String: UInt64] = [:]
        for image in images {
            if let project = image.labels?[composeProject] {
                byProject[project, default: 0] &+= bytes(image.size) &- min(bytes(image.size), bytes(image.sharedSize))
            }
        }
        for volume in volumes {
            if let project = volume.labels?[composeProject] {
                byProject[project, default: 0] &+= bytes(volume.usageData?.size)
            }
        }
        for container in containers {
            if let project = container.labels?[composeProject] {
                byProject[project, default: 0] &+= bytes(container.sizeRw)
            }
        }
        let projects = byProject.filter { $0.value > 0 }
            .map { DockerDiskUsage.ProjectShare(project: $0.key, bytes: $0.value) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.project < $1.project }
        return DockerDiskUsage(totals: totals, projects: projects)
    }

    /// For tests and fixtures: decodes a `/system/df` body.
    public static func usage(json: Data) throws -> DockerDiskUsage {
        try usage(JSONDecoder().decode(SystemDiskPayload.self, from: json))
    }
}

/// Docker's disk use, when an engine is running.
public protocol DockerDiskSource: Sendable {
    /// Throws `DockerError.noEngine` with no socket. The engine walks every layer and volume,
    /// so this can take seconds; ask only when it's shown.
    func diskUsage() async throws -> DockerDiskUsage
}

extension DockerContainerSource: DockerDiskSource {
    public func diskUsage() async throws -> DockerDiskUsage {
        guard let engine = await engine() else {
            throw DockerError.noEngine
        }
        let response = try await UnixSocketHTTPClient(socketPath: engine.socketPath).get("/system/df", timeout: .seconds(60))
        return try DockerDiskMath.usage(json: DockerRequest.checked(response))
    }
}

extension SimulatedContainerSource: DockerDiskSource {
    public func diskUsage() async throws -> DockerDiskUsage {
        guard await engine() != nil else {
            throw DockerError.noEngine
        }
        let gb: UInt64 = 1_000_000_000
        return DockerDiskUsage(
            totals: [
                .init(part: .images, count: 23, bytes: 14 * gb, reclaimable: 9 * gb),
                .init(part: .volumes, count: 8, bytes: 3_400_000_000, reclaimable: 1_200_000_000),
                .init(part: .buildCache, count: 140, bytes: 6_100_000_000, reclaimable: 5_800_000_000),
                .init(part: .containers, count: 5, bytes: 210_000_000, reclaimable: 40_000_000),
            ],
            projects: [
                .init(project: "storefront", bytes: 4_800_000_000),
                .init(project: "analytics", bytes: 2_100_000_000),
            ]
        )
    }
}
