import Core
import Foundation
import os

/// Stops Docker containers through the Engine API (expansion E5).
///
/// - Stop (`.quit`): `POST /containers/{id}/stop?t=10`. Docker sends the container's stop signal,
///   waits up to 10 s, then kills it; the request waits with it (timeout 15 s, not the usual 2 s).
/// - Force Quit: `POST /containers/{id}/kill`, SIGKILL at once.
///
/// Handles `.container(id:name:)` only and refuses every other target, so the app routes by
/// target (see `ContainerRoutingTerminator`). Only takes a `ConfirmedTermination`, which only the
/// UI's `ConfirmedAction` can create (CLAUDE.md rule 4). Never signals a process.
public actor DockerTerminator: ProcessTerminator {
    /// Seconds Docker waits between the stop signal and SIGKILL (`docker stop`'s default).
    public static let stopGraceSeconds = 10

    private static let log = Logger(subsystem: "app.mactivity.docker", category: "terminator")

    private let discover: @Sendable () -> DockerEngine?

    public init(discover: @escaping @Sendable () -> DockerEngine? = { DockerSocketDiscovery.discover() }) {
        self.discover = discover
    }

    public init(engine: DockerEngine) {
        discover = { engine }
    }

    /// A container has no PID on this Mac (it runs in the engine's VM), so a successful stop
    /// reports empty lists; a failed one throws.
    public func terminate(_ request: ConfirmedTermination) async throws -> TerminationResult {
        guard case let .container(id, _) = request.target else {
            throw DockerError.refused
        }
        let safe = try DockerID.validated(id)
        switch request.mode {
        case .quit:
            try await DockerRequest.post(
                "/containers/\(safe)/stop?t=\(Self.stopGraceSeconds)",
                engine: discover(),
                timeout: .seconds(Self.stopGraceSeconds + 5)
            )
        case .forceQuit:
            try await DockerRequest.post("/containers/\(safe)/kill", engine: discover(), timeout: UnixSocketHTTPClient.defaultTimeout)
        }
        Self.log.info("Container \(safe.prefix(12), privacy: .public) \(request.mode == .quit ? "stopped" : "killed")")
        return TerminationResult(terminated: [], survivors: [])
    }
}

/// Restarts containers (expansion E5). A restart is a stop followed by a start, so it needs the
/// same proof of confirmation as Stop: `restart` takes only a `ConfirmedTermination`.
///
/// `TerminationMode` has no restart case, so the token's mode picks how the old instance ends:
/// `.quit` is `restart?t=10` (graceful), `.forceQuit` is `restart?t=0` (killed at once).
/// `ContainerRestartTerminator` adapts this to `ProcessTerminator` for a `ConfirmedAction`.
public actor DockerController: ContainerRestarter {
    private static let log = Logger(subsystem: "app.mactivity.docker", category: "controller")

    private let discover: @Sendable () -> DockerEngine?

    public init(discover: @escaping @Sendable () -> DockerEngine? = { DockerSocketDiscovery.discover() }) {
        self.discover = discover
    }

    public init(engine: DockerEngine) {
        discover = { engine }
    }

    public func restart(_ request: ConfirmedTermination) async throws {
        guard case let .container(id, _) = request.target else {
            throw DockerError.refused
        }
        let safe = try DockerID.validated(id)
        let grace = request.mode == .quit ? DockerTerminator.stopGraceSeconds : 0
        try await DockerRequest.post("/containers/\(safe)/restart?t=\(grace)", engine: discover(), timeout: .seconds(grace + 5))
        Self.log.info("Container \(safe.prefix(12), privacy: .public) restarted")
    }
}

/// Lets a `ConfirmedAction` drive restarts: its "terminate" is a restart. Give it to a
/// `ConfirmedAction` of its own, never to the shared one Stop uses.
public struct ContainerRestartTerminator: ProcessTerminator {
    private let restarter: any ContainerRestarter

    public init(_ restarter: any ContainerRestarter) {
        self.restarter = restarter
    }

    public func terminate(_ request: ConfirmedTermination) async throws -> TerminationResult {
        try await restarter.restart(request)
        return TerminationResult(terminated: [], survivors: [])
    }
}

/// Sends `.container` targets to the Docker terminator and everything else to the other one
/// (the signal terminator), so one `ConfirmedAction` serves both.
public struct ContainerRoutingTerminator: ProcessTerminator {
    private let containers: any ProcessTerminator
    private let everythingElse: any ProcessTerminator

    public init(containers: any ProcessTerminator, everythingElse: any ProcessTerminator) {
        self.containers = containers
        self.everythingElse = everythingElse
    }

    public func terminate(_ request: ConfirmedTermination) async throws -> TerminationResult {
        if case .container = request.target {
            return try await containers.terminate(request)
        }
        return try await everythingElse.terminate(request)
    }
}
