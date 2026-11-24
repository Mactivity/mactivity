import Foundation

// Remote sessions (D-280): the `ssh` processes running on this Mac, the host each went to, how
// long it's been open, and what it forwards. From their arguments and their listening sockets.
//
// A command line can hold secrets, so nothing from one is kept as text except what's been parsed
// into a host name, a port or a socket path and checked against what those can contain. The
// remote command, identity files, ProxyCommand and every other option are read past and dropped.

/// One port or socket forward.
public struct SSHForward: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        /// `-L`: a port on this Mac reaches something from the far side.
        case local
        /// `-R`: a port on the far side reaches something from here.
        case remote
        /// `-D`: a SOCKS proxy on this Mac.
        case dynamic
    }

    public let kind: Kind
    /// The address it listens on, as written; nil for the default.
    public let bindAddress: String?
    public let listenPort: UInt16?
    public let listenSocket: String?
    public let targetHost: String?
    public let targetPort: UInt16?
    public let targetSocket: String?
    /// Seen only as a port this ssh listens on, not in its arguments: set in `~/.ssh/config`, or
    /// added to a running connection. Where it goes can't be seen.
    public let isFromSocketOnly: Bool
    /// Whether this Mac has the port open: nil where it can't tell (`-R`, sockets).
    public let isListening: Bool?

    public init(
        kind: Kind, bindAddress: String? = nil, listenPort: UInt16? = nil, listenSocket: String? = nil, targetHost: String? = nil,
        targetPort: UInt16? = nil, targetSocket: String? = nil, isFromSocketOnly: Bool = false, isListening: Bool? = nil
    ) {
        self.kind = kind
        self.bindAddress = bindAddress
        self.listenPort = listenPort
        self.listenSocket = listenSocket
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.targetSocket = targetSocket
        self.isFromSocketOnly = isFromSocketOnly
        self.isListening = isListening
    }

    public var id: String {
        [
            kind.rawValue, bindAddress ?? "", listenPort.map(String.init) ?? "", listenSocket ?? "", targetHost ?? "",
            targetPort.map(String.init) ?? "", targetSocket ?? "",
        ].joined(separator: "\u{1F}")
    }

    /// Reachable from other machines, not just this Mac. Only `-L` and `-D`: `-R` listens far away.
    public var isOpenToNetwork: Bool {
        guard kind != .remote, listenPort != nil, let bindAddress else {
            return false
        }
        let bind = bindAddress.lowercased()
        return bind != "localhost" && bind != "::1" && !bind.hasPrefix("127.")
    }

    func listening(in ports: Set<UInt16>) -> SSHForward {
        guard kind != .remote, let listenPort else {
            return self
        }
        return SSHForward(
            kind: kind, bindAddress: bindAddress, listenPort: listenPort, targetHost: targetHost, targetPort: targetPort,
            targetSocket: targetSocket, isListening: ports.contains(listenPort)
        )
    }
}

/// What an `ssh` command line asks for.
public struct SSHCommandLine: Hashable, Sendable {
    /// The destination's host: no user, no password, no scheme. Nil when none could be read.
    public var host: String?
    public var port: UInt16?
    /// The hosts it goes through (`-J`, ProxyJump), joined by a comma.
    public var jump: String?
    public var forwards: [SSHForward] = []
    /// Forwards that were there but couldn't be understood.
    public var unreadableForwards = 0
    /// `-N`: no remote command, so it's only for its forwards.
    public var hasNoRemoteCommand = false
    /// `-f`: went to the background after signing in.
    public var isInBackground = false
    /// Runs a command on the far side instead of a shell. The command itself isn't kept.
    public var hasRemoteCommand = false
    /// `-G`, `-V`, `-Q`, `-O`: asks something and exits; not a session.
    public var isOneShot = false
    /// `-W`: carries one connection for another ssh, as ProxyJump starts.
    public var isProxy = false
    /// A connection others share (a ControlMaster) that replaced its own arguments with a title.
    public var isSharedConnection = false
    /// `-w`: a network tunnel device.
    public var hasTunnelDevice = false

    public init() {}
}

/// One `ssh` running on this Mac.
public struct RemoteSession: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        /// A shell on the far side.
        case shell
        /// Only for its forwards (`-N`, or `-f` with forwards).
        case tunnel
        /// Running a command there; what `git` and `rsync` start.
        case command
        /// A connection other sessions share.
        case shared
        /// Carrying another ssh's connection (`-W`).
        case proxy
    }

    public let pid: Int32
    public let kind: Kind
    /// From the arguments; a shared connection's address comes from its open socket instead.
    public let host: String?
    public let port: UInt16?
    public let jump: String?
    public let startedAt: Date?
    public let forwards: [SSHForward]
    /// Forwards in its arguments that couldn't be understood.
    public let unreadableForwards: Int
    public let hasTunnelDevice: Bool
    /// What started it, when that says something: "git", "rsync".
    public let startedBy: String?

    public var id: Int32 {
        pid
    }

    public init(
        pid: Int32, kind: Kind, host: String?, port: UInt16? = nil, jump: String? = nil, startedAt: Date?, forwards: [SSHForward] = [],
        unreadableForwards: Int = 0, hasTunnelDevice: Bool = false, startedBy: String? = nil
    ) {
        self.pid = pid
        self.kind = kind
        self.host = host
        self.port = port
        self.jump = jump
        self.startedAt = startedAt
        self.forwards = forwards
        self.unreadableForwards = unreadableForwards
        self.hasTunnelDevice = hasTunnelDevice
        self.startedBy = startedBy
    }
}

/// Live reads the process table; Simulated has a fixed set.
public protocol RemoteSessionSource: Sendable {
    /// Every ssh session of this user's, the longest open first.
    func sessions() async -> [RemoteSession]
}

/// Pure: an ssh process's arguments and sockets into a session.
public enum RemoteSessionRules {
    /// Parents that say nothing about why it's running: a terminal's shell.
    private static let quietParents: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "login", "launchd", "tmux", "screen", "ssh"]

    /// The session this process is, or nil when it isn't one: `ssh -G` and the like, and a
    /// `-W` helper another ssh started for its ProxyJump, which that ssh's row already names.
    /// `arguments` empty means macOS wouldn't give them: the row still shows, with no host.
    public static func session(
        pid: Int32, arguments: [String], startedAt: Date?, listeningPorts: [UInt16], peerAddress: String?, ancestors: [String]
    ) -> RemoteSession? {
        let parsed = SSHArguments.parse(arguments) ?? SSHCommandLine()
        guard !parsed.isOneShot, !(parsed.isProxy && ancestors.contains("ssh")) else {
            return nil
        }
        let ports = Set(listeningPorts)
        var forwards = parsed.forwards.map { $0.listening(in: ports) }
        let named = Set(parsed.forwards.compactMap { $0.kind == .remote ? nil : $0.listenPort })
        // Listening, and not in its arguments: from `~/.ssh/config`, or added while it runs.
        forwards += ports.subtracting(named).sorted().map { port in
            SSHForward(kind: .local, listenPort: port, isFromSocketOnly: true, isListening: true)
        }
        return RemoteSession(
            pid: pid, kind: kind(parsed, forwards: forwards), host: parsed.host ?? (parsed.isSharedConnection ? peerAddress : nil),
            port: parsed.port, jump: parsed.jump, startedAt: startedAt, forwards: forwards,
            unreadableForwards: parsed.unreadableForwards, hasTunnelDevice: parsed.hasTunnelDevice,
            startedBy: ancestors.first.flatMap { quietParents.contains($0) ? nil : $0 }
        )
    }

    private static func kind(_ parsed: SSHCommandLine, forwards: [SSHForward]) -> RemoteSession.Kind {
        if parsed.isSharedConnection {
            return .shared
        }
        if parsed.isProxy {
            return .proxy
        }
        if parsed.hasRemoteCommand {
            return .command
        }
        if parsed.hasNoRemoteCommand || parsed.hasTunnelDevice || (parsed.isInBackground && !forwards.isEmpty) {
            return .tunnel
        }
        return .shell
    }

    public static func sorted(_ sessions: [RemoteSession]) -> [RemoteSession] {
        sessions.sorted { ($0.startedAt ?? .distantFuture, $0.pid) < ($1.startedAt ?? .distantFuture, $1.pid) }
    }
}
