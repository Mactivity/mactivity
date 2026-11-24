import Core
import Darwin
import Foundation
@testable import Projects
import Simulated
import Testing

/// The live inspector, pointed at the test process itself (E12).
@Suite("Process details, live")
struct LiveProcessDetailsTests {
    let source = LiveProcessDetailsSource()

    private func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test("The test process: name, owner, cwd, threads, memory, and a command line")
    func ownBasics() async throws {
        let details = try #require(await source.details(pid: getpid()))
        #expect(details.isReadable)
        #expect(details.unreadableReason == nil)
        #expect(details.uid == getuid())
        #expect(details.user == ProcessInfo.processInfo.userName)
        #expect(details.workingDirectory == realPath(FileManager.default.currentDirectoryPath))
        #expect((details.threadCount ?? 0) >= 1)
        #expect((details.footprintBytes ?? 0) > 0)
        #expect(details.cpuTime.map { $0 > .zero } == true)
        #expect(details.executablePath.map { !$0.isEmpty } == true)
        #expect(details.arguments.first.map { !$0.isEmpty } == true)
        #expect(details.startedAt < Date())
    }

    @Test("A temp file it holds open shows up with its descriptor and mode")
    func openTempFile() async throws {
        let path = NSTemporaryDirectory() + "mactivity-inspector-\(UUID().uuidString).txt"
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        try #require(fd >= 0)
        defer {
            close(fd)
            unlink(path)
        }
        let details = try #require(await source.details(pid: getpid()))
        let file = try #require(details.openFiles.first { $0.fd == fd })
        #expect(file.path == realPath(path))
        #expect(file.access == .readWrite)
    }

    @Test("A listening socket on 127.0.0.1:0, and a connection to it")
    func listeningSocket() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(listener, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        try #require(named == 0)
        let port = UInt16(bigEndian: address.sin_port)

        let client = socket(AF_INET, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(connected == 0)

        let details = try #require(await source.details(pid: getpid()))
        let listening = try #require(details.listeningPorts.first { $0.fd == listener })
        #expect(listening.localPort == port)
        #expect(listening.localAddress == "127.0.0.1")
        #expect(listening.transport == .tcp)
        #expect(listening.state == .listen)
        #expect(listening.localEndpoint == "127.0.0.1:\(port)")

        let outgoing = try #require(details.sockets.first { $0.fd == client })
        #expect(outgoing.remoteAddress == "127.0.0.1")
        #expect(outgoing.remotePort == port)
        #expect(outgoing.state == .established)

        let connections = await source.connections(pids: [getpid()])
        let connection = try #require(connections.first { $0.remotePort == port && $0.remoteAddress == "127.0.0.1" })
        #expect(connection.isLoopback)
        #expect(connection.pids == [getpid()])
        #expect(connection.state == .established)
    }

    @Test("The parent chain reaches launchd")
    func parentChain() async throws {
        let details = try #require(await source.details(pid: getpid()))
        let chain = details.parentChain
        #expect(!chain.isEmpty)
        #expect(chain.first?.pid == getppid())
        #expect(chain.last?.pid == 1)
        #expect(chain.last?.name == "launchd")
        #expect(Set(chain.map(\.pid)).count == chain.count)
    }

    @Test("launchd without the helper: unreadable with a reason, no crash")
    func launchdIsUnreadable() async throws {
        try #require(getuid() != 0, "Running as root reads everything")
        let details = try #require(await source.details(pid: 1))
        #expect(details.name == "launchd")
        #expect(details.uid == 0)
        #expect(details.user == "root")
        #expect(!details.isReadable)
        #expect(details.unreadableReason?.contains("helper") == true)
        #expect(details.arguments.isEmpty)
        #expect(details.openFiles.isEmpty)
        #expect(details.sockets.isEmpty)
        #expect(details.workingDirectory == nil)
        #expect(details.parentChain.isEmpty)
    }

    @Test("A PID that doesn't exist is nil")
    func missing() async {
        #expect(await source.details(pid: 99998) == nil)
        #expect(await source.details(pid: -4) == nil)
    }

    @Test("The environment never appears, even though KERN_PROCARGS2 carries it")
    func noEnvironment() async throws {
        let secret = "mactivity-secret-\(UUID().uuidString)"
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/cat")
        child.arguments = ["-u"]
        child.environment = ["MACTIVITY_TEST_TOKEN": secret, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        try child.run()
        defer {
            // EOF on stdin ends cat; nothing is signalled (CLAUDE.md rule 4).
            try? input.fileHandleForWriting.close()
            child.waitUntilExit()
        }
        let details = try #require(await source.details(pid: child.processIdentifier))
        #expect(details.arguments == ["/bin/cat", "-u"])
        #expect(details.commandLine == "/bin/cat -u")
        let json = try String(bytes: JSONEncoder().encode(details), encoding: .utf8) ?? ""
        let everything = String(describing: details) + json
        #expect(!everything.contains(secret))
        #expect(!everything.contains("MACTIVITY_TEST_TOKEN"))
        #expect(details.parentChain.first?.pid == getpid())
    }
}

@Suite("Process details, pure")
struct ProcessDetailsPureTests {
    @Test("KERN_PROCARGS2 parsing stops at argc; the environment after it is dropped")
    func procArgsDropEnvironment() throws {
        var data: [UInt8] = withUnsafeBytes(of: Int32(2).littleEndian) { Array($0) }
        data += Array("/usr/bin/tool".utf8) + [0, 0, 0, 0]
        data += Array("tool".utf8) + [0] + Array("--flag".utf8) + [0]
        data += Array("API_TOKEN=sk-secret".utf8) + [0] + Array("HOME=/Users/demo".utf8) + [0]
        let parsed = try #require(ProjectDetection.parseProcArgs(data))
        #expect(parsed.executable == "/usr/bin/tool")
        #expect(parsed.arguments == ["tool", "--flag"])
    }

    @Test("Command lines quote arguments with spaces")
    func commandLine() {
        #expect(ProcessDetails.displayCommandLine(["node", "server.js"]) == "node server.js")
        #expect(ProcessDetails.displayCommandLine(["open", "/Users/demo/My Folder"]) == "open '/Users/demo/My Folder'")
        #expect(ProcessDetails.displayCommandLine(["echo", "it's", ""]) == "echo 'it'\\''s' ''")
    }

    @Test("TCP states map from TSI_S_* values")
    func tcpStates() {
        #expect(TCPState(kernelValue: 1) == .listen)
        #expect(TCPState(kernelValue: 4) == .established)
        #expect(TCPState(kernelValue: 10) == .timeWait)
        #expect(TCPState(kernelValue: 11) == nil)
        #expect(TCPState(kernelValue: -1) == nil)
    }

    @Test("Socket addresses: IPv4 in in4in6_addr, IPv6, mapped IPv4, and unspecified")
    func addresses() {
        let v4 = [UInt8](repeating: 0, count: 12) + [192, 0, 2, 10]
        #expect(ProcessInspector.endpointAddress(bytes: v4, isIPv6: false) == "192.0.2.10")
        let v6: [UInt8] = [0x20, 0x01, 0x0D, 0xB8] + [UInt8](repeating: 0, count: 11) + [1]
        #expect(ProcessInspector.endpointAddress(bytes: v6, isIPv6: true) == "2001:db8::1")
        let mapped = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 127, 0, 0, 1]
        #expect(ProcessInspector.endpointAddress(bytes: mapped, isIPv6: true) == "127.0.0.1")
        #expect(ProcessInspector.endpointAddress(bytes: [UInt8](repeating: 0, count: 16), isIPv6: true) == nil)
        #expect(ProcessInspector.endpointAddress(bytes: [1, 2, 3], isIPv6: false) == nil)
    }

    @Test("Endpoints bracket IPv6 and show * for any address")
    func endpoints() {
        let any = SocketEntry(
            fd: 3, transport: .udp, isIPv6: false, localAddress: nil, localPort: 5353, remoteAddress: nil, remotePort: 0, state: nil
        )
        #expect(any.localEndpoint == "*:5353")
        #expect(!any.hasRemote)
        #expect(!any.isListening)
        let v6 = SocketEntry(
            fd: 4, transport: .tcp, isIPv6: true, localAddress: "::1", localPort: 8080,
            remoteAddress: "2001:db8::1", remotePort: 443, state: .established
        )
        #expect(v6.localEndpoint == "[::1]:8080")
        #expect(v6.remoteEndpoint == "[2001:db8::1]:443")
    }

    @Test("Reverse DNS is off unless allowed, and makes no lookup when off")
    func reverseDNSOff() async {
        #expect(await ReverseDNS.lookUp("192.0.2.1", allowed: false) == nil)
        #expect(ReverseDNS.allowLookupsKey == "allowReverseDNSLookups")
        if !ReverseDNS.isAllowed {
            #expect(await LiveProcessDetailsSource().hostName(for: "192.0.2.1") == nil)
        }
    }

    @Test("A non-numeric address is never resolved")
    func reverseDNSNumericOnly() {
        #expect(ReverseDNS.resolve("example.com") == nil)
    }
}

/// Connections per app (E1) on a fixture: three browser processes' sockets.
@Suite("Connection aggregation")
struct ConnectionAggregationTests {
    struct Entry: Decodable {
        let pid: Int32
        let socket: SocketEntry
    }

    struct Fixture: Decodable {
        let sockets: [Entry]
        let expected: [Connection]
    }

    @Test("Groups by endpoint and transport, skips listeners, remote hosts first, loopback last")
    func browser() throws {
        let fixture: Fixture = try Fixtures.load("connections-browser.json")
        let connections = Connection.aggregate(fixture.sockets.map { ($0.pid, $0.socket) })
        #expect(connections == fixture.expected)
        #expect(connections.allSatisfy { $0.remotePort != 0 })
        #expect(connections.last?.isLoopback == true)
    }

    @Test("The liveliest state wins for an endpoint")
    func liveliestState() throws {
        let fixture: Fixture = try Fixtures.load("connections-browser.json")
        let connections = Connection.aggregate(fixture.sockets.map { ($0.pid, $0.socket) })
        let cdn = try #require(connections.first { $0.remoteAddress == "192.0.2.10" && $0.transport == .tcp })
        // Two established sockets and one in TIME_WAIT.
        #expect(cdn.state == .established)
        #expect(cdn.socketCount == 3)
        #expect(cdn.endpoint == "192.0.2.10:443")
    }

    @Test("Nothing connected, nothing listed")
    func empty() {
        #expect(Connection.aggregate([]).isEmpty)
        let listener = SocketEntry(
            fd: 5, transport: .tcp, isIPv6: false, localAddress: nil, localPort: 3000, remoteAddress: nil, remotePort: 0, state: .listen
        )
        #expect(Connection.aggregate([(1, listener)]).isEmpty)
    }

    @Test("The simulated source aggregates Safari's processes")
    func simulated() async {
        let source = SimulatedProcessDetailsSource()
        let connections = await source.connections(pids: [400, 401, 402, 403])
        #expect(connections.first?.remoteAddress == "192.0.2.10")
        #expect(connections.first?.pids == [401, 402])
        #expect(await source.details(pid: 1)?.isReadable == false)
        let server = SimulatedDevServers.storefrontPID
        #expect(await SimulatedProcessDetailsSource(exited: [server]).details(pid: server) == nil)
    }
}

/// One full `details` call on a big process, for the cost note. Opt in with
/// `MACTIVITY_MEASURE_INSPECTOR=1` (optionally `MACTIVITY_MEASURE_PID=<pid>`); a normal run skips it.
@Suite("Inspector cost", .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_MEASURE_INSPECTOR"] != nil))
struct InspectorCostTests {
    @Test("Median of 50 full details calls")
    func measure() async throws {
        let source = LiveProcessDetailsSource()
        let pid = try await target(source)
        let first = try #require(await source.details(pid: pid))
        var samples: [Duration] = []
        let clock = ContinuousClock()
        for _ in 0 ..< 50 {
            let start = clock.now
            _ = await source.details(pid: pid)
            samples.append(clock.now - start)
        }
        let sorted = samples.sorted()
        let line = "inspector cost: pid \(pid) \(first.name): \(first.openFiles.count) files, \(first.sockets.count) sockets, "
            + "\(first.unixSocketCount) unix, \(first.otherDescriptorCount) other; median \(sorted[25]), max \(sorted[49])\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// The given PID, or this user's process with the most descriptors.
    private func target(_ source: LiveProcessDetailsSource) async throws -> Int32 {
        if let text = ProcessInfo.processInfo.environment["MACTIVITY_MEASURE_PID"], let pid = Int32(text) {
            return pid
        }
        let count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var best: (pid: Int32, descriptors: Int) = (getpid(), 0)
        for pid in pids.prefix(Int(filled)) where pid > 1 {
            guard let details = await source.details(pid: pid), details.isReadable else {
                continue
            }
            let total = details.openFiles.count + details.sockets.count + details.unixSocketCount + details.otherDescriptorCount
            if total > best.descriptors {
                best = (pid, total)
            }
        }
        return best.pid
    }
}
