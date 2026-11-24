import Darwin
import Foundation
import os

/// A fake Docker daemon: an HTTP/1.1 server on a Unix socket in the temp folder, serving fixture
/// JSON from `Tests/Fixtures/docker-*.json`. Each test makes its own, so tests run in parallel.
final class FakeDockerDaemon: Sendable {
    enum Reply: Sendable {
        /// A fixture with `Content-Length`.
        case fixture(String, status: Int = 200)
        /// A fixture sent `Transfer-Encoding: chunked`, `chunkSize` bytes a chunk, with pauses so
        /// the client sees it arrive in pieces.
        case chunkedFixture(String, chunkSize: Int)
        case body(String, status: Int)
        /// A bodyless status, like 204 after a stop.
        case empty(status: Int)
        /// Accepts, reads the request, and never answers.
        case stall
    }

    struct Request: Sendable, Hashable {
        let method: String
        let path: String

        var line: String {
            "\(method) \(path)"
        }
    }

    private struct State {
        var routes: [String: Reply] = [:]
        var requests: [Request] = []
        var stopped = false
    }

    let socketPath: String
    private let listener: Int32
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() throws {
        // `sun_path` is 104 bytes; the per-user temp folder plus a short name fits.
        socketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mdk-\(UUID().uuidString.prefix(8)).sock")
        listener = try Self.listen(at: socketPath)
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    deinit {
        stop()
    }

    /// Every later `method path` (path including the query) gets `reply`.
    func route(_ method: String, _ path: String, _ reply: Reply) {
        state.withLock { $0.routes["\(method) \(path)"] = reply }
    }

    var requests: [Request] {
        state.withLock(\.requests)
    }

    func stop() {
        let wasStopped = state.withLock { state in
            defer { state.stopped = true }
            return state.stopped
        }
        guard !wasStopped else {
            return
        }
        close(listener)
        unlink(socketPath)
    }

    // MARK: Server

    private static func listen(at path: String) throws -> Int32 {
        struct SocketError: Error {
            let call: String
            let code: Int32
        }
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SocketError(call: "socket", code: errno)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw SocketError(call: "bind", code: errno)
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            close(descriptor)
            throw SocketError(call: "listen", code: errno)
        }
        return descriptor
    }

    private func acceptLoop() {
        while !state.withLock(\.stopped) {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else {
                continue
            }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else {
                continue
            }
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let handler = Thread { [self] in serve(connection) }
            handler.start()
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        guard let request = readRequest(connection) else {
            return
        }
        let reply = state.withLock { state -> Reply? in
            state.requests.append(request)
            return state.routes[request.line]
        }
        switch reply ?? .body(#"{"message":"page not found"}"#, status: 404) {
        case let .fixture(name, status):
            send(
                Self.head(status: status, headers: ["Content-Type: application/json", "Content-Length: \(Self.fixture(name).count)"]),
                connection
            )
            send(Self.fixture(name), connection)
        case let .chunkedFixture(name, size):
            send(Self.head(status: 200, headers: ["Content-Type: application/json", "Transfer-Encoding: chunked"]), connection)
            let body = Self.fixture(name)
            var offset = 0
            while offset < body.count {
                let piece = body[offset ..< min(body.count, offset + size)]
                // An extension on the first chunk, which clients must ignore.
                let extensionText = offset == 0 ? ";name=value" : ""
                send(Array("\(String(piece.count, radix: 16))\(extensionText)\r\n".utf8) + piece + [13, 10], connection)
                offset += size
                usleep(1000)
            }
            send(Array("0\r\n\r\n".utf8), connection)
        case let .body(text, status):
            let body = Array(text.utf8)
            send(Self.head(status: status, headers: ["Content-Type: application/json", "Content-Length: \(body.count)"]), connection)
            send(body, connection)
        case let .empty(status):
            send(Self.head(status: status, headers: []), connection)
        case .stall:
            // Longer than the client's timeout; the client gives up first.
            Thread.sleep(forTimeInterval: 3.5)
        }
    }

    private func readRequest(_ connection: Int32) -> Request? {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        let end: [UInt8] = [13, 10, 13, 10]
        while buffer.count < 65536 {
            let count = chunk.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
            guard count > 0 else {
                return nil
            }
            buffer.append(contentsOf: chunk[0 ..< count])
            if buffer.count >= 4, (0 ... buffer.count - 4).contains(where: { buffer[$0 ..< $0 + 4].elementsEqual(end) }) {
                break
            }
        }
        let head = String(bytes: buffer, encoding: .utf8) ?? ""
        let parts = head.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            return nil
        }
        return Request(method: String(parts[0]), path: String(parts[1]))
    }

    private func send(_ bytes: [UInt8], _ connection: Int32) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            guard written > 0 else {
                return
            }
            offset += written
        }
    }

    private static func head(status: Int, headers: [String]) -> [UInt8] {
        let reason = [200: "OK", 204: "No Content", 304: "Not Modified", 404: "Not Found", 409: "Conflict", 500: "Internal Server Error"]
        let lines = ["HTTP/1.1 \(status) \(reason[status] ?? "Status")", "Api-Version: 1.47", "Server: Docker/27.3.1 (linux)"]
            + headers + ["", ""]
        return Array(lines.joined(separator: "\r\n").utf8)
    }

    static func fixture(_ name: String) -> [UInt8] {
        (try? Array(Data(contentsOf: DockerFixtures.directory.appendingPathComponent(name)))) ?? []
    }
}

enum DockerFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
}
