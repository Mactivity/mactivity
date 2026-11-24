@testable import Docker
import Foundation
import Testing

@Suite("HTTP over a Unix socket")
struct HTTPClientTests {
    @Test("Content-Length bodies: nil until every byte is in")
    func sizedBody() throws {
        let head = Array("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n".utf8)
        let body = Array(#"{"ok":true}"#.utf8)
        #expect(try HTTPResponseParser.parse(head, atEndOfStream: false) == nil)
        #expect(try HTTPResponseParser.parse(head + body.prefix(5), atEndOfStream: false) == nil)
        let response = try #require(try HTTPResponseParser.parse(head + body, atEndOfStream: false))
        #expect(response.status == 200)
        #expect(response.headers["content-type"] == "application/json")
        #expect(response.body == Data(body))
        #expect(throws: DockerError.connectionClosed) {
            try HTTPResponseParser.parse(head + body.prefix(5), atEndOfStream: true)
        }
    }

    @Test("Chunked bodies: extensions ignored, complete at the zero chunk")
    func chunkedBody() throws {
        let head = Array("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let chunks = Array("4;name=x\r\n{\"a\"\r\nA\r\n:[1,2,3]}\n\r\n".utf8)
        #expect(try HTTPResponseParser.parse(head + chunks, atEndOfStream: false) == nil)
        let whole = head + chunks + Array("0\r\n\r\n".utf8)
        let response = try #require(try HTTPResponseParser.parse(whole, atEndOfStream: false))
        #expect(String(bytes: response.body, encoding: .utf8) == "{\"a\":[1,2,3]}\n")
        #expect(throws: DockerError.malformedResponse) {
            try HTTPResponseParser.parse(head + Array("zz\r\n".utf8), atEndOfStream: false)
        }
    }

    @Test("204 and 304 have no body; unframed bodies end at close")
    func bodiless() throws {
        let noContent = try #require(try HTTPResponseParser.parse(Array("HTTP/1.1 204 No Content\r\n\r\n".utf8), atEndOfStream: false))
        #expect(noContent.status == 204 && noContent.body.isEmpty)
        let unframed = Array("HTTP/1.1 200 OK\r\n\r\nhello".utf8)
        #expect(try HTTPResponseParser.parse(unframed, atEndOfStream: false) == nil)
        #expect(try HTTPResponseParser.parse(unframed, atEndOfStream: true)?.body == Data("hello".utf8))
        #expect(throws: DockerError.malformedResponse) {
            try HTTPResponseParser.parse(Array("SPDY/3 200 OK\r\n\r\n".utf8), atEndOfStream: false)
        }
    }

    @Test("A chunked listing over the socket arrives whole")
    func chunkedOverSocket() async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.route("GET", "/containers/json?all=1", .chunkedFixture("docker-containers.json", chunkSize: 128))
        let response = try await UnixSocketHTTPClient(socketPath: daemon.socketPath).get("/containers/json?all=1")
        #expect(response.status == 200)
        #expect(Array(response.body) == FakeDockerDaemon.fixture("docker-containers.json"))
    }

    @Test("The request is HTTP/1.1 with a Host and Connection: close")
    func requestShape() {
        let text = String(bytes: UnixSocketHTTPClient.request(method: "POST", path: "/containers/x/stop?t=10"), encoding: .utf8) ?? ""
        #expect(text.hasPrefix("POST /containers/x/stop?t=10 HTTP/1.1\r\n"))
        #expect(text.contains("\r\nHost: docker\r\n"))
        #expect(text.contains("\r\nContent-Length: 0\r\n"))
        #expect(text.hasSuffix("\r\nConnection: close\r\n\r\n"))
    }

    @Test("A daemon that never answers times out after 2 s")
    func timeout() async throws {
        let daemon = try FakeDockerDaemon()
        defer { daemon.stop() }
        daemon.route("GET", "/containers/json?all=1", .stall)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: DockerError.timedOut) {
            try await UnixSocketHTTPClient(socketPath: daemon.socketPath).get("/containers/json?all=1")
        }
        let elapsed = clock.now - start
        #expect(elapsed >= .milliseconds(1950), "Gave up early: \(elapsed)")
        #expect(elapsed < .milliseconds(2750), "Gave up late: \(elapsed)")
        #expect(UnixSocketHTTPClient.defaultTimeout == .seconds(2))
    }

    @Test("A socket path longer than sun_path is refused before connecting")
    func longPath() async {
        let path = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        await #expect(throws: DockerError.socketPathTooLong) {
            try await UnixSocketHTTPClient(socketPath: path).get("/_ping")
        }
    }
}
