import Foundation
import os

/// Containers from the local Docker engine, over its Unix socket (expansion E5).
///
/// Each call makes one `GET /containers/json?all=1` and one stats request per running container,
/// at most eight at a time. The caller sets the cadence: `ContainersModel` asks every 5 s, and
/// only while a Projects view is visible.
///
/// CPU %: the first reading of a container uses `stats?stream=false`, which makes the daemon wait
/// about a second for two samples. Later readings add `one-shot=true`, which answers at once, and
/// the actor diffs against the previous reading it kept, exactly as `docker stats` diffs its own.
public actor DockerContainerSource: ContainerSource {
    private static let log = Logger(subsystem: "app.mactivity.docker", category: "containers")
    static let maxConcurrentStats = 8

    private let discover: @Sendable () -> DockerEngine?
    private var previous: [String: DockerStatsMath.CPUSample] = [:]

    /// Looks for the socket on every call, so starting Docker Desktop later just works.
    public init(discover: @escaping @Sendable () -> DockerEngine? = { DockerSocketDiscovery.discover() }) {
        self.discover = discover
    }

    public init(engine: DockerEngine) {
        discover = { engine }
    }

    public func engine() async -> DockerEngine? {
        discover()
    }

    public func containers() async throws -> [Container] {
        guard let engine = discover() else {
            previous = [:]
            throw DockerError.noEngine
        }
        let client = UnixSocketHTTPClient(socketPath: engine.socketPath)
        let response = try await client.get("/containers/json?all=1")
        let summaries = try JSONDecoder().decode([ContainerSummaryPayload].self, from: DockerRequest.checked(response))

        let running = summaries.filter { $0.state?.lowercased() == "running" }.map(\.id)
        let known = previous
        let readings = await Self.stats(for: running, known: known, client: client)

        var next: [String: DockerStatsMath.CPUSample] = [:]
        let containers = summaries.map { summary -> Container in
            guard let reading = readings[summary.id] else {
                return Container(summary: summary, cpuPercent: nil, memoryUsed: nil, memoryLimit: nil)
            }
            var cpu: Double?
            if let current = DockerStatsMath.sample(reading.cpuStats) {
                next[summary.id] = current
                let before = DockerStatsMath.sample(reading.precpuStats) ?? known[summary.id]
                cpu = before.flatMap { DockerStatsMath.cpuPercent(current: current, previous: $0) }
            }
            let memory = reading.memoryStats
            let used = memory?.usage.map { DockerStatsMath.memoryUsed(usage: $0, stats: memory?.stats ?? [:]) }
            return Container(summary: summary, cpuPercent: cpu, memoryUsed: used, memoryLimit: memory?.limit)
        }
        previous = next
        return containers
    }

    /// Stats for each running container, a few at a time. A container whose stats fail keeps its
    /// row, without figures.
    private static func stats(
        for ids: [String],
        known: [String: DockerStatsMath.CPUSample],
        client: UnixSocketHTTPClient
    ) async -> [String: ContainerStatsPayload] {
        await withTaskGroup(of: (String, ContainerStatsPayload?).self) { group in
            var results: [String: ContainerStatsPayload] = [:]
            var pending = ids[...]
            func startNext() {
                guard let id = pending.popFirst(), let safe = try? DockerID.validated(id) else {
                    return
                }
                let path = "/containers/\(safe)/stats?stream=false" + (known[id] == nil ? "" : "&one-shot=true")
                group.addTask {
                    do {
                        let response = try await client.get(path)
                        return try (id, ContainerStatsPayload.decode(DockerRequest.checked(response)))
                    } catch {
                        Self.log.notice("Stats for a container failed: \(String(describing: error), privacy: .public)")
                        return (id, nil)
                    }
                }
            }
            for _ in 0 ..< min(maxConcurrentStats, ids.count) {
                startNext()
            }
            for await (id, payload) in group {
                if let payload {
                    results[id] = payload
                }
                startNext()
            }
            return results
        }
    }
}

/// Shared by the source, the terminator, and the controller.
enum DockerRequest {
    /// The body of a 2xx response, or the Engine API's error message.
    static func checked(_ response: HTTPResponse) throws -> Data {
        guard response.isSuccess else {
            let message = (try? JSONDecoder().decode(DockerErrorPayload.self, from: response.body))?.message
            throw DockerError.http(status: response.status, message: message ?? "")
        }
        return response.body
    }

    /// POSTs a state change. 204 is done; 304 means it already was (stopping a stopped container).
    static func post(_ path: String, engine: DockerEngine?, timeout: Duration) async throws {
        guard let engine else {
            throw DockerError.noEngine
        }
        let response = try await UnixSocketHTTPClient(socketPath: engine.socketPath).post(path, timeout: timeout)
        if response.status == 304 {
            return
        }
        _ = try checked(response)
    }
}
