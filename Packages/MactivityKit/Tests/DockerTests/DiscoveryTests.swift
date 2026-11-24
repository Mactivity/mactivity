@testable import Docker
import Foundation
import Testing

@Suite("Socket discovery")
struct DiscoveryTests {
    private let home = "/Users/demo"

    @Test("Order: DOCKER_HOST, Docker Desktop, OrbStack, Colima, Rancher Desktop, /var/run")
    func order() {
        let paths = DockerSocketDiscovery.candidates(environment: ["DOCKER_HOST": "unix:///custom/engine.sock"], home: home)
            .map(\.path)
        #expect(paths == [
            "/custom/engine.sock",
            "/Users/demo/.docker/run/docker.sock",
            "/Users/demo/.orbstack/run/docker.sock",
            "/Users/demo/.colima/default/docker.sock",
            "/Users/demo/.rd/docker.sock",
            "/var/run/docker.sock",
        ])
    }

    @Test("A TCP or SSH DOCKER_HOST is skipped: Unix sockets only", arguments: ["tcp://127.0.0.1:2375", "ssh://me@box", "unix://", ""])
    func nonUnixHost(host: String) {
        let first = DockerSocketDiscovery.candidates(environment: ["DOCKER_HOST": host], home: home).first
        #expect(first?.path == "/Users/demo/.docker/run/docker.sock")
    }

    @Test("First existing socket wins, and says which engine it is", arguments: [
        (["/Users/demo/.docker/run/docker.sock", "/Users/demo/.orbstack/run/docker.sock"], DockerEngine.Kind.dockerDesktop),
        (["/Users/demo/.orbstack/run/docker.sock", "/Users/demo/.colima/default/docker.sock"], .orbStack),
        (["/Users/demo/.colima/default/docker.sock", "/var/run/docker.sock"], .colima),
        (["/var/run/docker.sock"], .other),
    ])
    func firstWins(existing: [String], kind: DockerEngine.Kind) {
        let engine = DockerSocketDiscovery.discover(environment: [:], home: home, isSocket: existing.contains, resolve: { $0 })
        #expect(engine?.socketPath == existing.first)
        #expect(engine?.kind == kind)
    }

    @Test("A socket something answers on beats a dead one left behind (D-145)")
    func liveBeatsStale() {
        let existing: Set = ["/Users/demo/.docker/run/docker.sock", "/Users/demo/.orbstack/run/docker.sock"]
        let engine = DockerSocketDiscovery.discover(
            environment: [:], home: home, isSocket: existing.contains,
            isListening: { $0 == "/Users/demo/.orbstack/run/docker.sock" }, resolve: { $0 }
        )
        #expect(engine?.kind == .orbStack)
        // Nothing answers: the first socket, so the view can say Docker Desktop isn't running.
        let none = DockerSocketDiscovery.discover(environment: [:], home: home, isSocket: existing.contains, isListening: { _ in false })
        #expect(none?.kind == .dockerDesktop)
    }

    @Test("DOCKER_HOST beats every default path")
    func hostFirst() {
        let everything: Set = [
            "/Users/demo/.orbstack/run/docker.sock", "/Users/demo/.docker/run/docker.sock", "/var/run/docker.sock",
        ]
        let engine = DockerSocketDiscovery.discover(
            environment: ["DOCKER_HOST": "unix:///Users/demo/.orbstack/run/docker.sock"],
            home: home,
            isSocket: everything.contains,
            resolve: { $0 }
        )
        #expect(engine == DockerEngine(kind: .orbStack, socketPath: "/Users/demo/.orbstack/run/docker.sock"))
    }

    @Test("/var/run/docker.sock takes its kind from its symlink's target")
    func symlinkKind() {
        let engine = DockerSocketDiscovery.discover(
            environment: [:],
            home: home,
            isSocket: { $0 == "/var/run/docker.sock" },
            resolve: { _ in "/Users/demo/.docker/run/docker.sock" }
        )
        #expect(engine == DockerEngine(kind: .dockerDesktop, socketPath: "/var/run/docker.sock"))
        #expect(engine?.name == "Docker Desktop")
    }

    @Test("Nothing found, nothing returned")
    func nothing() {
        #expect(DockerSocketDiscovery.discover(environment: [:], home: home, isSocket: { _ in false }) == nil)
    }

    @Test("Finds a real socket under a scratch home, and a plain file isn't one")
    func realSocket() throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("mdh-\(UUID().uuidString.prefix(6))")
        let orbstack = (home as NSString).appendingPathComponent(".orbstack/run")
        let desktop = (home as NSString).appendingPathComponent(".docker/run")
        try FileManager.default.createDirectory(atPath: orbstack, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: desktop, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        // A leftover regular file where Docker Desktop's socket would be doesn't count.
        FileManager.default.createFile(atPath: (desktop as NSString).appendingPathComponent("docker.sock"), contents: Data())
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        let link = (orbstack as NSString).appendingPathComponent("docker.sock")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: daemon.socketPath)

        let engine = DockerSocketDiscovery.discover(environment: [:], home: home)
        #expect(engine == DockerEngine(kind: .orbStack, socketPath: link))
    }

    @Test("Kind from path", arguments: [
        ("/Users/a/.docker/run/docker.sock", DockerEngine.Kind.dockerDesktop),
        ("/Users/a/.orbstack/run/docker.sock", .orbStack),
        ("/Users/a/.colima/work/docker.sock", .colima),
        ("/Users/a/.rd/docker.sock", .other),
    ])
    func kind(path: String, expected: DockerEngine.Kind) {
        #expect(DockerEngine.Kind(socketPath: path) == expected)
    }
}
