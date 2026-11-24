import Core
@testable import Docker
import Foundation
import Testing

/// Stop, Force Quit, and Restart. The tokens here stand in for what `ConfirmedAction` creates
/// after the user confirms; the UI tests cover that nothing is sent before the confirm.
@Suite("Stop, kill, and restart")
struct TerminatorTests {
    private func token(_ target: TerminationTarget, _ mode: TerminationMode = .quit) -> ConfirmedTermination {
        ConfirmedTermination(target: target, mode: mode, confirmedAt: Date())
    }

    private let db = TerminationTarget.container(id: IDs.db, name: "storefront-web-db-1")

    @Test("Nothing is sent until a terminator is handed a token")
    func nothingWithoutToken() throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        _ = DockerTerminator(engine: daemon.engine)
        _ = DockerController(engine: daemon.engine)
        #expect(daemon.requests.isEmpty)
    }

    @Test("Stop is POST /containers/{id}/stop?t=10")
    func stop() async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.route("POST", "/containers/\(IDs.db)/stop?t=10", .empty(status: 204))

        let result = try await DockerTerminator(engine: daemon.engine).terminate(token(db))

        #expect(daemon.requests.map(\.line) == ["POST /containers/\(IDs.db)/stop?t=10"])
        #expect(result == TerminationResult(terminated: [], survivors: []))
    }

    @Test("Force Quit is POST /containers/{id}/kill")
    func kill() async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.route("POST", "/containers/\(IDs.db)/kill", .empty(status: 204))

        _ = try await DockerTerminator(engine: daemon.engine).terminate(token(db, .forceQuit))

        #expect(daemon.requests.map(\.line) == ["POST /containers/\(IDs.db)/kill"])
    }

    @Test("Restart is POST /containers/{id}/restart, graceful or immediate", arguments: [
        (TerminationMode.quit, "t=10"),
        (.forceQuit, "t=0"),
    ])
    func restart(mode: TerminationMode, query: String) async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.route("POST", "/containers/\(IDs.db)/restart?\(query)", .empty(status: 204))

        try await DockerController(engine: daemon.engine).restart(token(db, mode))

        #expect(daemon.requests.map(\.line) == ["POST /containers/\(IDs.db)/restart?\(query)"])
    }

    @Test("The restart adapter restarts; it never stops")
    func restartAdapter() async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.route("POST", "/containers/\(IDs.db)/restart?t=10", .empty(status: 204))

        _ = try await ContainerRestartTerminator(DockerController(engine: daemon.engine)).terminate(token(db))

        #expect(daemon.requests.map(\.line) == ["POST /containers/\(IDs.db)/restart?t=10"])
    }

    @Test("Stopping a stopped container (304) is fine; a missing one (404) throws with its message")
    func statuses() async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.route("POST", "/containers/\(IDs.db)/stop?t=10", .empty(status: 304))
        daemon.route("POST", "/containers/\(IDs.minio)/stop?t=10", .body(#"{"message":"No such container: minio"}"#, status: 404))
        let terminator = DockerTerminator(engine: daemon.engine)

        _ = try await terminator.terminate(token(db))
        await #expect(throws: DockerError.http(status: 404, message: "No such container: minio")) {
            try await terminator.terminate(token(.container(id: IDs.minio, name: "minio")))
        }
    }

    @Test("Non-container targets are refused and send nothing", arguments: [
        TerminationTarget.process(4242),
        .processGroup(4242),
        .app("com.example.app", pids: [4242]),
    ])
    func refusesOthers(target: TerminationTarget) async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        for mode in [TerminationMode.quit, .forceQuit] {
            await #expect(throws: DockerError.refused) {
                try await DockerTerminator(engine: daemon.engine).terminate(token(target, mode))
            }
            await #expect(throws: DockerError.refused) {
                try await DockerController(engine: daemon.engine).restart(token(target, mode))
            }
        }
        #expect(daemon.requests.isEmpty)
    }

    @Test("An ID that isn't one can't reach another endpoint", arguments: ["../../images/prune?", "a b", "", "x/../../y", ".."])
    func refusesBadIDs(id: String) async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        await #expect(throws: DockerError.refused) {
            try await DockerTerminator(engine: daemon.engine).terminate(token(.container(id: id, name: "x")))
        }
        #expect(daemon.requests.isEmpty)
    }

    @Test("The routing terminator sends containers to Docker and the rest elsewhere")
    func routing() async throws {
        let docker = SimulatedContainerSource()
        let other = SimulatedContainerSource(containers: [])
        let router = ContainerRoutingTerminator(containers: docker, everythingElse: other)
        let first = try #require(SimulatedContainerSource.sample.first)

        _ = try await router.terminate(token(first.target))
        await #expect(throws: DockerError.refused) {
            try await router.terminate(token(.process(4242)))
        }

        #expect(await docker.requests.map(\.target) == [first.target])
        #expect(await other.requests.isEmpty)
        #expect(try await docker.containers().first?.state == .exited)
    }

    @Test("No engine: stop throws noEngine")
    func noEngine() async {
        await #expect(throws: DockerError.noEngine) {
            try await DockerTerminator(discover: { nil }).terminate(token(db))
        }
    }
}
