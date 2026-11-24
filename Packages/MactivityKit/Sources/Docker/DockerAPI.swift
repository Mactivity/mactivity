import Foundation

// The slice of the Docker Engine API that Mactivity reads, and the math `docker stats` does on it.

/// A port in a `GET /containers/json` entry. `PublicPort` is absent when nothing is published.
struct ContainerPortPayload: Decodable {
    let privatePort: UInt16?
    let publicPort: UInt16?

    enum CodingKeys: String, CodingKey {
        case privatePort = "PrivatePort"
        case publicPort = "PublicPort"
    }
}

/// One entry of `GET /containers/json`.
struct ContainerSummaryPayload: Decodable {
    let id: String
    let names: [String]?
    let image: String?
    let state: String?
    let status: String?
    let ports: [ContainerPortPayload]?
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case image = "Image"
        case state = "State"
        case status = "Status"
        case ports = "Ports"
        case labels = "Labels"
    }
}

/// `cpu_stats.cpu_usage`.
struct CPUUsagePayload: Decodable {
    let totalUsage: UInt64?
    let percpuUsage: [UInt64]?
}

/// `cpu_stats` and `precpu_stats`.
struct CPUStatsPayload: Decodable {
    let cpuUsage: CPUUsagePayload?
    let systemCpuUsage: UInt64?
    let onlineCpus: Int?
}

/// `memory_stats`.
struct MemoryStatsPayload: Decodable {
    let usage: UInt64?
    let limit: UInt64?
    let stats: [String: UInt64]?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = try container.decodeIfPresent(UInt64.self, forKey: .usage)
        limit = try container.decodeIfPresent(UInt64.self, forKey: .limit)
        // Every value is a counter today; don't let one odd field hide the whole reading.
        stats = try? container.decodeIfPresent([String: UInt64].self, forKey: .stats)
    }

    enum CodingKeys: String, CodingKey {
        case usage, limit, stats
    }
}

/// `GET /containers/{id}/stats?stream=false`, decoded with `.convertFromSnakeCase`.
struct ContainerStatsPayload: Decodable {
    let cpuStats: CPUStatsPayload?
    let precpuStats: CPUStatsPayload?
    let memoryStats: MemoryStatsPayload?

    static func decode(_ data: Data) throws -> ContainerStatsPayload {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ContainerStatsPayload.self, from: data)
    }
}

/// The Engine API's error body.
struct DockerErrorPayload: Decodable {
    let message: String
}

/// `docker stats`' arithmetic (docker/cli `cli/command/container/stats_helpers.go`, Apache-2.0,
/// reimplemented from its documented behavior).
public enum DockerStatsMath {
    /// Cumulative CPU counters from one stats reading.
    public struct CPUSample: Hashable, Sendable {
        /// Nanoseconds of CPU the container has used.
        public let containerNanoseconds: UInt64
        /// Nanoseconds of CPU the whole engine host (the VM on a Mac) has used.
        public let systemNanoseconds: UInt64
        public let onlineCPUs: Int

        public init(containerNanoseconds: UInt64, systemNanoseconds: UInt64, onlineCPUs: Int) {
            self.containerNanoseconds = containerNanoseconds
            self.systemNanoseconds = systemNanoseconds
            self.onlineCPUs = onlineCPUs
        }
    }

    /// (Δcontainer ÷ Δsystem) × online CPUs × 100, so 100% is one core. Nil when the system
    /// counter didn't move (no interval to measure); 0 when the container's didn't.
    public static func cpuPercent(current: CPUSample, previous: CPUSample) -> Double? {
        guard current.systemNanoseconds > previous.systemNanoseconds else {
            return nil
        }
        guard current.containerNanoseconds > previous.containerNanoseconds else {
            return 0
        }
        let container = Double(current.containerNanoseconds - previous.containerNanoseconds)
        let system = Double(current.systemNanoseconds - previous.systemNanoseconds)
        return container / system * Double(max(1, current.onlineCPUs)) * 100
    }

    /// Usage minus the inactive page cache: `total_inactive_file` on cgroup v1,
    /// `inactive_file` on v2. Whichever is present and smaller than usage.
    public static func memoryUsed(usage: UInt64, stats: [String: UInt64]) -> UInt64 {
        if let inactive = stats["total_inactive_file"], inactive < usage {
            return usage - inactive
        }
        if let inactive = stats["inactive_file"], inactive < usage {
            return usage - inactive
        }
        return usage
    }

    static func sample(_ stats: CPUStatsPayload?) -> CPUSample? {
        guard let stats, let total = stats.cpuUsage?.totalUsage, let system = stats.systemCpuUsage, system > 0 else {
            return nil
        }
        let online = stats.onlineCpus.flatMap { $0 > 0 ? $0 : nil } ?? stats.cpuUsage?.percpuUsage?.count ?? 1
        return CPUSample(containerNanoseconds: total, systemNanoseconds: system, onlineCPUs: online)
    }
}

extension Container {
    /// Builds a container from its summary and, when running, the figures already worked out.
    init(summary: ContainerSummaryPayload, cpuPercent: Double?, memoryUsed: UInt64?, memoryLimit: UInt64?) {
        let labels = summary.labels ?? [:]
        let name = summary.names?.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        let ports = Set((summary.ports ?? []).compactMap(\.publicPort).filter { $0 > 0 }).sorted()
        self.init(
            id: summary.id,
            name: name ?? String(summary.id.prefix(12)),
            image: summary.image ?? "",
            state: summary.state.flatMap { State(rawValue: $0.lowercased()) } ?? .exited,
            status: summary.status ?? "",
            ports: ports,
            cpuPercent: cpuPercent,
            memoryUsedBytes: memoryUsed,
            memoryLimitBytes: memoryLimit,
            composeProject: labels["com.docker.compose.project"],
            composeService: labels["com.docker.compose.service"],
            workingDirectory: labels["com.docker.compose.project.working_dir"]
        )
    }
}

/// Container IDs and names go into request paths, so only Docker's own alphabet is allowed.
enum DockerID {
    static func validated(_ id: String) throws -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard !id.isEmpty, id.count <= 128, id.allSatisfy(allowed.contains), id != ".", id != ".." else {
            throw DockerError.refused
        }
        return id
    }
}
