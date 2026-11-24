import Core
import Foundation

// The process inspector (expansion E12) and connections per app (E1). Read-only, public APIs.

/// Everything the inspector shows about one process, read in one pass.
///
/// The command line is argv only. The environment that follows it in `KERN_PROCARGS2` is never
/// read into this value: it can hold tokens and passwords.
public struct ProcessDetails: Hashable, Sendable, Codable, Identifiable {
    /// One step up the parent chain.
    public struct Ancestor: Hashable, Sendable, Codable, Identifiable {
        public let pid: Int32
        public let name: String

        public var id: Int32 {
            pid
        }

        public init(pid: Int32, name: String) {
            self.pid = pid
            self.name = name
        }
    }

    /// A file (or directory, or device) the process holds open.
    public struct OpenFile: Hashable, Sendable, Codable, Identifiable {
        public let fd: Int32
        public let path: String
        public let access: OpenFileAccess

        public var id: Int32 {
            fd
        }

        public init(fd: Int32, path: String, access: OpenFileAccess) {
            self.fd = fd
            self.path = path
            self.access = access
        }
    }

    public let pid: Int32
    public let name: String
    public let executablePath: String?
    /// argv, from `KERN_PROCARGS2`. Empty when unreadable.
    public let arguments: [String]
    public let workingDirectory: String?
    public let uid: UInt32
    /// `getpwuid_r`; nil for a uid with no account.
    public let user: String?
    public let startedAt: Date
    /// Parent first, ending at launchd (PID 1). Empty for launchd itself.
    public let parentChain: [Ancestor]
    public let threadCount: Int?
    public let footprintBytes: UInt64?
    /// User + system CPU time since the process started.
    public let cpuTime: Duration?
    public let openFiles: [OpenFile]
    /// TCP and UDP sockets, IPv4 and IPv6.
    public let sockets: [SocketEntry]
    /// Unix-domain sockets, counted but not listed.
    public let unixSocketCount: Int
    /// Pipes, kqueues, shared memory, and the other descriptor kinds, counted.
    public let otherDescriptorCount: Int
    /// False when the kernel refused (EPERM): another user's process, before the helper (M9).
    public let isReadable: Bool
    /// Why `isReadable` is false, worded for the user.
    public let unreadableReason: String?
    public let sampledAt: Date

    public var id: Int32 {
        pid
    }

    /// TCP sockets in LISTEN.
    public var listeningPorts: [SocketEntry] {
        sockets.filter(\.isListening).sorted { $0.localPort < $1.localPort }
    }

    /// Sockets with a remote end: TCP connections and connected UDP.
    public var connectedSockets: [SocketEntry] {
        sockets.filter(\.hasRemote)
    }

    /// argv joined for display, quoting arguments that contain spaces.
    public var commandLine: String {
        ProcessDetails.displayCommandLine(arguments)
    }

    public init(
        pid: Int32,
        name: String,
        executablePath: String?,
        arguments: [String],
        workingDirectory: String?,
        uid: UInt32,
        user: String?,
        startedAt: Date,
        parentChain: [Ancestor],
        threadCount: Int?,
        footprintBytes: UInt64?,
        cpuTime: Duration?,
        openFiles: [OpenFile],
        sockets: [SocketEntry],
        unixSocketCount: Int,
        otherDescriptorCount: Int,
        isReadable: Bool,
        unreadableReason: String?,
        sampledAt: Date
    ) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.uid = uid
        self.user = user
        self.startedAt = startedAt
        self.parentChain = parentChain
        self.threadCount = threadCount
        self.footprintBytes = footprintBytes
        self.cpuTime = cpuTime
        self.openFiles = openFiles
        self.sockets = sockets
        self.unixSocketCount = unixSocketCount
        self.otherDescriptorCount = otherDescriptorCount
        self.isReadable = isReadable
        self.unreadableReason = unreadableReason
        self.sampledAt = sampledAt
    }

    /// argv as one line: arguments with spaces or quotes are single-quoted.
    public static func displayCommandLine(_ arguments: [String]) -> String {
        arguments.map { argument in
            guard argument.isEmpty || argument.contains(where: { $0 == " " || $0 == "'" || $0 == "\"" || $0 == "\t" }) else {
                return argument
            }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        .joined(separator: " ")
    }
}

/// The mode a file was opened with (`FREAD` / `FWRITE`).
public enum OpenFileAccess: String, Hashable, Sendable, Codable {
    case read, write, readWrite

    public var title: String {
        switch self {
        case .read: String(localized: "Read", bundle: .strings, comment: "How a process opened a file: read only.")
        case .write: String(localized: "Write", bundle: .strings, comment: "How a process opened a file: write only.")
        case .readWrite: String(localized: "Read/Write", bundle: .strings, comment: "How a process opened a file: read and write.")
        }
    }
}

public enum SocketTransport: String, Hashable, Sendable, Codable {
    case tcp, udp

    /// "TCP", "UDP": protocol names, verbatim.
    public var title: String {
        rawValue.uppercased()
    }
}

/// `tcpsi_state` (`TSI_S_*` in `<sys/proc_info.h>`).
public enum TCPState: String, Hashable, Sendable, Codable, CaseIterable {
    case closed, listen, synSent, synReceived, established, closeWait, finWait1, closing, lastAck, finWait2, timeWait

    /// The kernel's `TSI_S_*` value.
    public init?(kernelValue: Int32) {
        let states: [TCPState] = [
            .closed, .listen, .synSent, .synReceived, .established, .closeWait, .finWait1, .closing, .lastAck, .finWait2, .timeWait,
        ]
        guard kernelValue >= 0, Int(kernelValue) < states.count else {
            return nil
        }
        self = states[Int(kernelValue)]
    }

    public var title: String {
        switch self {
        case .closed: String(localized: "Closed", bundle: .strings, comment: "TCP connection state.")
        case .listen: String(localized: "Listening", bundle: .strings, comment: "TCP connection state: waiting for connections.")
        case .synSent: String(localized: "Connecting", bundle: .strings, comment: "TCP connection state (SYN sent).")
        case .synReceived: String(localized: "Accepting", bundle: .strings, comment: "TCP connection state (SYN received).")
        case .established: String(localized: "Established", bundle: .strings, comment: "TCP connection state: connected.")
        case .closeWait: String(localized: "Close wait", bundle: .strings, comment: "TCP connection state (CLOSE_WAIT).")
        case .finWait1, .closing, .lastAck, .finWait2:
            String(localized: "Closing", bundle: .strings, comment: "TCP connection state: shutting down.")
        case .timeWait: String(localized: "Time wait", bundle: .strings, comment: "TCP connection state (TIME_WAIT).")
        }
    }

    /// Which state wins when several sockets reach one endpoint: live beats connecting beats closing.
    var liveness: Int {
        switch self {
        case .established: 10
        case .synSent: 9
        case .synReceived: 8
        case .closeWait: 7
        case .finWait1: 6
        case .finWait2: 5
        case .closing: 4
        case .lastAck: 3
        case .timeWait: 2
        case .listen: 1
        case .closed: 0
        }
    }
}

/// One TCP or UDP socket of one process.
public struct SocketEntry: Hashable, Sendable, Codable, Identifiable {
    public let fd: Int32
    public let transport: SocketTransport
    public let isIPv6: Bool
    /// Nil means any address (`*`).
    public let localAddress: String?
    public let localPort: UInt16
    /// Nil when the socket has no remote end.
    public let remoteAddress: String?
    public let remotePort: UInt16
    /// TCP only.
    public let state: TCPState?

    public var id: Int32 {
        fd
    }

    public var isListening: Bool {
        transport == .tcp && state == .listen
    }

    public var hasRemote: Bool {
        remoteAddress != nil && remotePort != 0
    }

    /// "127.0.0.1:5173", "[::1]:443", "*:53".
    public var localEndpoint: String {
        SocketEntry.endpoint(localAddress ?? "*", localPort)
    }

    public var remoteEndpoint: String? {
        remoteAddress.map { SocketEntry.endpoint($0, remotePort) }
    }

    public init(
        fd: Int32,
        transport: SocketTransport,
        isIPv6: Bool,
        localAddress: String?,
        localPort: UInt16,
        remoteAddress: String?,
        remotePort: UInt16,
        state: TCPState?
    ) {
        self.fd = fd
        self.transport = transport
        self.isIPv6 = isIPv6
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.state = state
    }

    static func endpoint(_ address: String, _ port: UInt16) -> String {
        let host = address.contains(":") ? "[\(address)]" : address
        return port == 0 ? host : "\(host):\(port)"
    }
}

/// One remote endpoint an app is talking to (E1), across all of the app's processes.
public struct Connection: Hashable, Sendable, Codable, Identifiable {
    public let transport: SocketTransport
    public let remoteAddress: String
    public let remotePort: UInt16
    /// The liveliest state among the sockets (TCP only).
    public let state: TCPState?
    public let socketCount: Int
    /// Processes holding a socket to this endpoint, ascending.
    public let pids: [Int32]

    public var id: String {
        "\(transport.rawValue) \(endpoint)"
    }

    /// "192.0.2.10:443", "[2001:db8::1]:443".
    public var endpoint: String {
        SocketEntry.endpoint(remoteAddress, remotePort)
    }

    /// 127/8, ::1, and IPv4-mapped loopback.
    public var isLoopback: Bool {
        remoteAddress == "::1" || remoteAddress.hasPrefix("127.") || remoteAddress.hasPrefix("::ffff:127.")
    }

    public init(transport: SocketTransport, remoteAddress: String, remotePort: UInt16, state: TCPState?, socketCount: Int, pids: [Int32]) {
        self.transport = transport
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.state = state
        self.socketCount = socketCount
        self.pids = pids
    }

    /// Groups sockets by remote endpoint and transport. Sockets without a remote end (listeners,
    /// unconnected UDP) are left out. Remote hosts first, then loopback; within each, established
    /// before closing, then the most sockets, then by address. Pure, so fixtures test it.
    public static func aggregate(_ sockets: [(pid: Int32, socket: SocketEntry)]) -> [Connection] {
        struct Key: Hashable {
            let transport: SocketTransport
            let address: String
            let port: UInt16
        }
        var groups: [Key: [(pid: Int32, socket: SocketEntry)]] = [:]
        for entry in sockets where entry.socket.hasRemote {
            guard let address = entry.socket.remoteAddress else {
                continue
            }
            groups[Key(transport: entry.socket.transport, address: address, port: entry.socket.remotePort), default: []].append(entry)
        }
        return groups.map { key, entries in
            Connection(
                transport: key.transport,
                remoteAddress: key.address,
                remotePort: key.port,
                state: entries.compactMap(\.socket.state).max { $0.liveness < $1.liveness },
                socketCount: entries.count,
                pids: Array(Set(entries.map(\.pid))).sorted()
            )
        }
        .sorted { lhs, rhs in
            if lhs.isLoopback != rhs.isLoopback {
                return !lhs.isLoopback
            }
            let left = lhs.state?.liveness ?? TCPState.established.liveness
            let right = rhs.state?.liveness ?? TCPState.established.liveness
            if left != right {
                return left > right
            }
            if lhs.socketCount != rhs.socketCount {
                return lhs.socketCount > rhs.socketCount
            }
            if lhs.remoteAddress != rhs.remoteAddress {
                return lhs.remoteAddress < rhs.remoteAddress
            }
            if lhs.remotePort != rhs.remotePort {
                return lhs.remotePort < rhs.remotePort
            }
            return lhs.transport.rawValue < rhs.transport.rawValue
        }
    }
}

/// The process inspector's data source (E12, E1). The UI sees only this protocol (CLAUDE.md rule 1).
public protocol ProcessDetailsSource: Sendable {
    /// Nil when the process doesn't exist (it exited). A process that exists but belongs to
    /// another user comes back with `isReadable == false`.
    func details(pid: Int32) async -> ProcessDetails?

    /// The remote endpoints of these processes' sockets, aggregated (E1).
    func connections(pids: [Int32]) async -> [Connection]

    /// The host name for an address, from `getnameinfo`. That is a DNS query, which leaves the
    /// Mac (CLAUDE.md rule 3), so it returns nil unless `ReverseDNS.isAllowed`.
    func hostName(for address: String) async -> String?
}
