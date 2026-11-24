import Darwin
import Dispatch
import Foundation
import os

/// A tiny HTTP/1.1 client over a Unix domain socket, for the Docker Engine API (expansion E5).
///
/// This is local IPC with the Docker daemon, not the network: it opens `socket(AF_UNIX)` to a
/// socket file on this Mac and never speaks TCP. It deliberately doesn't use Foundation's URL
/// loading system (no URL session, which is what rule 3 fences in), and nothing leaves the Mac
/// (CLAUDE.md rule 3).
///
/// One request per connection (`Connection: close`). Handles `Content-Length`, chunked, and
/// read-until-close bodies. Every exchange has a deadline, 2 s unless the caller asks for more
/// (a container stop waits for the container's own grace period). The blocking socket calls run
/// on a private dispatch queue, never on the Swift concurrency pool.
public struct UnixSocketHTTPClient: Sendable {
    public static let defaultTimeout: Duration = .seconds(2)

    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func get(_ path: String, timeout: Duration = Self.defaultTimeout) async throws -> HTTPResponse {
        try await send(method: "GET", path: path, timeout: timeout)
    }

    public func post(_ path: String, timeout: Duration = Self.defaultTimeout) async throws -> HTTPResponse {
        try await send(method: "POST", path: path, timeout: timeout)
    }

    public func send(method: String, path: String, timeout: Duration = Self.defaultTimeout) async throws -> HTTPResponse {
        let request = Self.request(method: method, path: path)
        let socketPath = socketPath
        let deadline = ContinuousClock.now + timeout
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result {
                    try Self.exchange(socketPath: socketPath, request: request, deadline: deadline)
                })
            }
        }
    }

    // MARK: Request

    static func request(method: String, path: String) -> [UInt8] {
        // The Engine API ignores Host, but HTTP/1.1 requires one.
        var text = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nUser-Agent: Mactivity\r\nAccept: application/json\r\n"
        if method == "POST" {
            text += "Content-Length: 0\r\n"
        }
        text += "Connection: close\r\n\r\n"
        return Array(text.utf8)
    }

    // MARK: Socket I/O

    private static let queue = DispatchQueue(label: "app.mactivity.docker.socket", attributes: .concurrent)
    private static let log = Logger(subsystem: "app.mactivity.docker", category: "http")

    private static func exchange(socketPath: String, request: [UInt8], deadline: ContinuousClock.Instant) throws -> HTTPResponse {
        let descriptor = try connect(to: socketPath, deadline: deadline)
        defer { close(descriptor) }
        try writeAll(request, to: descriptor, until: deadline)

        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let response = try HTTPResponseParser.parse(buffer, atEndOfStream: false) {
                return response
            }
            try wait(for: Int16(POLLIN), on: descriptor, until: deadline)
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0 ..< count])
            } else if count == 0 {
                guard let response = try HTTPResponseParser.parse(buffer, atEndOfStream: true) else {
                    throw DockerError.connectionClosed
                }
                return response
            } else if errno != EAGAIN, errno != EINTR {
                throw DockerError.cannotConnect(errno: errno)
            }
        }
    }

    private static func connect(to path: String, deadline: ContinuousClock.Instant) throws -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw DockerError.socketPathTooLong
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw DockerError.cannotConnect(errno: errno)
        }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if status != 0 {
            let error = errno
            guard error == EINPROGRESS else {
                close(descriptor)
                throw DockerError.cannotConnect(errno: error)
            }
            do {
                try wait(for: Int16(POLLOUT), on: descriptor, until: deadline)
            } catch {
                close(descriptor)
                throw error
            }
            var pending: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &pending, &length)
            if pending != 0 {
                close(descriptor)
                throw DockerError.cannotConnect(errno: pending)
            }
        }
        return descriptor
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32, until deadline: ContinuousClock.Instant) throws {
        var offset = 0
        while offset < bytes.count {
            try wait(for: Int16(POLLOUT), on: descriptor, until: deadline)
            let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0, errno != EAGAIN, errno != EINTR {
                throw DockerError.cannotConnect(errno: errno)
            }
        }
    }

    /// Waits until `descriptor` is ready for `events`, or throws `timedOut` at the deadline.
    private static func wait(for events: Int16, on descriptor: Int32, until deadline: ContinuousClock.Instant) throws {
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else {
                log.notice("Docker request timed out")
                throw DockerError.timedOut
            }
            let milliseconds = Int32(clamping: remaining.milliseconds + 1)
            var poller = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&poller, 1, milliseconds)
            if ready > 0 {
                return
            }
            if ready < 0, errno != EINTR {
                throw DockerError.cannotConnect(errno: errno)
            }
        }
    }
}

/// A complete HTTP response, body already de-chunked.
public struct HTTPResponse: Hashable, Sendable {
    public let status: Int
    /// Lowercased names.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool {
        (200 ..< 300).contains(status)
    }
}

/// Parses an HTTP/1.1 response from the bytes read so far. Pure, so the framing rules are tested
/// without a socket.
enum HTTPResponseParser {
    private static let headerEnd: [UInt8] = [13, 10, 13, 10]
    private static let lineEnd: [UInt8] = [13, 10]

    /// The response, or nil when more bytes are needed. At the end of the stream, a body without
    /// framing is whatever arrived; a truncated framed body is an error.
    static func parse(_ bytes: [UInt8], atEndOfStream: Bool) throws -> HTTPResponse? {
        guard let split = find(headerEnd, in: bytes, from: 0) else {
            return try incomplete(atEndOfStream)
        }
        let (status, headers) = try head(bytes[0 ..< split])
        let rest = Array(bytes[(split + headerEnd.count)...])
        guard let body = try body(rest, status: status, headers: headers, atEndOfStream: atEndOfStream) else {
            return try incomplete(atEndOfStream)
        }
        return HTTPResponse(status: status, headers: headers, body: Data(body))
    }

    /// The status code and lowercased headers.
    private static func head(_ bytes: ArraySlice<UInt8>) throws -> (Int, [String: String]) {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw DockerError.malformedResponse
        }
        let lines = text.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."), let status = Int(statusParts[1]) else {
            throw DockerError.malformedResponse
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (status, headers)
    }

    /// The body by the response's framing, or nil while it's still arriving.
    private static func body(_ rest: [UInt8], status: Int, headers: [String: String], atEndOfStream: Bool) throws -> [UInt8]? {
        if (100 ..< 200).contains(status) || status == 204 || status == 304 {
            return []
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return try dechunk(rest)
        }
        if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else {
                throw DockerError.malformedResponse
            }
            return rest.count >= length ? Array(rest[0 ..< length]) : nil
        }
        return atEndOfStream ? rest : nil
    }

    /// More bytes are needed; at the end of the stream there won't be any.
    private static func incomplete(_ atEndOfStream: Bool) throws -> HTTPResponse? {
        if atEndOfStream {
            throw DockerError.connectionClosed
        }
        return nil
    }

    /// The decoded body, or nil until the terminating zero-size chunk has arrived.
    static func dechunk(_ bytes: [UInt8]) throws -> [UInt8]? {
        var body: [UInt8] = []
        var index = 0
        while true {
            guard let lineEnd = find(lineEnd, in: bytes, from: index) else {
                return nil
            }
            guard let line = String(bytes: bytes[index ..< lineEnd], encoding: .ascii) else {
                throw DockerError.malformedResponse
            }
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw DockerError.malformedResponse
            }
            let dataStart = lineEnd + 2
            if size == 0 {
                // Trailers (none from Docker) end at the next blank line; the body is already complete.
                return body
            }
            guard bytes.count >= dataStart + size + 2 else {
                return nil
            }
            body.append(contentsOf: bytes[dataStart ..< dataStart + size])
            index = dataStart + size + 2
        }
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard haystack.count >= needle.count, start <= haystack.count - needle.count else {
            return nil
        }
        var index = start
        while index <= haystack.count - needle.count {
            if haystack[index ..< index + needle.count].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }
}

public enum DockerError: Error, Hashable, Sendable {
    /// No Docker socket in any of the usual places.
    case noEngine
    /// `sun_path` holds 104 bytes.
    case socketPathTooLong
    /// The socket exists but nothing accepted (the engine isn't running), or I/O failed.
    case cannotConnect(errno: Int32)
    case timedOut
    /// The daemon closed the connection before a whole response arrived.
    case connectionClosed
    case malformedResponse
    /// The Engine API answered with an error: `{"message": "..."}`.
    case http(status: Int, message: String)
    /// Not a container target, or a container ID that isn't one.
    case refused
}
