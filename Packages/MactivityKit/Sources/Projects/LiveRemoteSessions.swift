import Core
import Darwin
import Foundation

/// Remote sessions from the process table (D-280): this user's `ssh` processes, their arguments
/// and their sockets. Reads nothing in `~/.ssh`, connects to nothing, and keeps nothing from a
/// command line but what `SSHArguments` parses out of it. Runs only while the view shows.
public struct LiveRemoteSessions: RemoteSessionSource {
    public init() {}

    public func sessions() async -> [RemoteSession] {
        await Task.detached(priority: .utility) { Self.read() }.value
    }

    static func read() -> [RemoteSession] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: max(capacity, 64))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else {
            return []
        }
        let me = getuid()
        var found: [RemoteSession] = []
        for pid in pids.prefix(Int(count)) where pid > 1 {
            guard let identity = ProcessInspector.identity(pid), identity.uid == me, identity.name == "ssh" else {
                continue
            }
            let sockets = ProcessInspector.inetSockets(pid)
            let session = RemoteSessionRules.session(
                pid: pid, arguments: ProcessInspector.arguments(pid), startedAt: identity.startedAt,
                listeningPorts: ProcessInspector.listeningPorts(pid).map(\.port),
                peerAddress: sockets.first { $0.state == .established && $0.remotePort > 0 }?.remoteAddress,
                ancestors: ProcessInspector.parentChain(of: pid, parentPID: identity.parentPID).prefix(3).map(\.name)
            )
            if let session {
                found.append(session)
            }
        }
        return RemoteSessionRules.sorted(found)
    }
}
