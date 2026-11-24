import Core
import Darwin
import Foundation
import os

/// Reads `ProcessDetails` from the kernel with public calls only: `proc_pidinfo`,
/// `proc_pidfdinfo`, `proc_pid_rusage`, `sysctl(KERN_PROCARGS2)`, and `getpwuid_r` (E12, E1).
///
/// Nothing here samples on its own. The inspector calls `details` while it is open (every 2 s)
/// and `connections` while an app's connections are shown.
public actor LiveProcessDetailsSource: ProcessDetailsSource {
    /// Runs on the shared sampling thread, like the other readers (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    private static let log = Logger(subsystem: "app.mactivity.projects", category: "inspector")

    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    public func details(pid: Int32) async -> ProcessDetails? {
        guard pid >= 0, let identity = ProcessInspector.identity(pid) else {
            return nil
        }
        let user = ProcessInspector.userName(identity.uid)
        let chain = ProcessInspector.parentChain(of: pid, parentPID: identity.parentPID)
        let descriptors = ProcessInspector.descriptors(pid)
        let threads = ProcessInspector.threadCount(pid)
        var refusal: POSIXError?
        if case let .failure(error) = descriptors {
            refusal = error
        } else if case let .failure(error) = threads {
            refusal = error
        }
        if refusal?.code == .ESRCH {
            // It exited between the reads.
            return nil
        }
        let readable = refusal == nil
        if let refusal {
            Self.log.debug("PID \(pid, privacy: .public) is not readable: \(refusal.code.rawValue, privacy: .public)")
        }
        let files = (try? descriptors.get()) ?? ProcessInspector.Descriptors()
        let usage = ProcessInspector.usage(pid)
        return ProcessDetails(
            pid: pid,
            name: identity.name,
            executablePath: ProcessInspector.executablePath(pid),
            // argv only: `parseProcArgs` stops after argc strings and never reads the environment.
            arguments: readable ? ProcessInspector.arguments(pid) : [],
            workingDirectory: readable ? ProcessInspector.workingDirectory(pid) : nil,
            uid: identity.uid,
            user: user,
            startedAt: identity.startedAt,
            parentChain: chain,
            threadCount: try? threads.get(),
            footprintBytes: usage?.footprint,
            cpuTime: usage?.cpu,
            openFiles: files.openFiles.sorted { $0.fd < $1.fd },
            sockets: files.sockets.sorted { $0.fd < $1.fd },
            unixSocketCount: files.unixSockets,
            otherDescriptorCount: files.other,
            isReadable: readable,
            unreadableReason: refusal.map { Self.reason(for: $0, name: identity.name, user: user, uid: identity.uid) },
            sampledAt: clock()
        )
    }

    public func connections(pids: [Int32]) async -> [Connection] {
        var sockets: [(pid: Int32, socket: SocketEntry)] = []
        for pid in Set(pids) {
            sockets += ProcessInspector.inetSockets(pid).map { (pid, $0) }
        }
        return Connection.aggregate(sockets)
    }

    /// Off the sampling thread: `getnameinfo` blocks for as long as DNS takes.
    @concurrent
    public nonisolated func hostName(for address: String) async -> String? {
        await ReverseDNS.lookUp(address)
    }

    static func reason(for error: POSIXError, name: String, user: String?, uid: UInt32) -> String {
        switch error.code {
        case .EPERM, .EACCES:
            guard let user else {
                return String(
                    localized: "“\(name)” runs as uid \(uid). Its open files, sockets, and command line need the privileged helper.",
                    bundle: .strings, comment: "Process inspector. The arguments are a process name and a numeric Unix user ID."
                )
            }
            return String(
                localized: "“\(name)” runs as \(user). Its open files, sockets, and command line need the privileged helper.",
                bundle: .strings, comment: "Process inspector. The arguments are a process name and a Unix user name, e.g. root."
            )
        default:
            let code = error.code.rawValue
            return String(
                localized: "macOS didn't return “\(name)”'s files and sockets (error \(code)).", bundle: .strings,
                comment: "Process inspector. The arguments are a process name and a numeric POSIX error code."
            )
        }
    }
}

/// Host names for addresses, behind a flag that is **off by default**.
///
/// `getnameinfo` asks the configured DNS server, which is a network request, and CLAUDE.md rule 3
/// allows only the update check to leave the Mac. So the
/// inspector shows IP addresses, and a "Look up name" button appears only when the
/// `allowReverseDNSLookups` default is set. Each lookup is one address the user clicked.
public enum ReverseDNS {
    /// `UserDefaults` key. Absent means off.
    public static let allowLookupsKey = "allowReverseDNSLookups"

    public static var isAllowed: Bool {
        UserDefaults.standard.bool(forKey: allowLookupsKey)
    }

    private static let log = Logger(subsystem: "app.mactivity.projects", category: "reverse-dns")

    /// The name for one numeric address, or nil when there is none, the address isn't numeric,
    /// or lookups aren't allowed.
    public static func lookUp(_ address: String, allowed: Bool = isAllowed) async -> String? {
        guard allowed else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            resolve(address)
        }.value
    }

    /// `getnameinfo(NI_NAMEREQD)` on a numeric IPv4 or IPv6 address. Blocking.
    static func resolve(_ address: String) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var status: Int32 = EAI_NONAME
        var v4 = sockaddr_in()
        var v6 = sockaddr_in6()
        if inet_pton(AF_INET, address, &v4.sin_addr) == 1 {
            v4.sin_family = sa_family_t(AF_INET)
            v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            status = withUnsafePointer(to: &v4) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        } else if inet_pton(AF_INET6, address, &v6.sin6_addr) == 1 {
            v6.sin6_family = sa_family_t(AF_INET6)
            v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            status = withUnsafePointer(to: &v6) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        } else {
            return nil
        }
        guard status == 0 else {
            log.debug("No name for an address: \(status, privacy: .public)")
            return nil
        }
        let name = String(bytes: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
        return name?.isEmpty == false ? name : nil
    }
}
