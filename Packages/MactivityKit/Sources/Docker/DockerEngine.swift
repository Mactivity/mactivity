import Darwin
import Foundation
import os

/// The Docker engine Mactivity found, and the socket it talks to.
public struct DockerEngine: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case dockerDesktop, orbStack, colima, other

        /// "Docker Desktop", "OrbStack", "Colima", "Docker".
        public var title: String {
            switch self {
            case .dockerDesktop: "Docker Desktop"
            case .orbStack: "OrbStack"
            case .colima: "Colima"
            case .other: "Docker"
            }
        }

        /// Which engine owns a socket path. Symlinks should be resolved first:
        /// `/var/run/docker.sock` usually points into one of the others.
        public init(socketPath path: String) {
            if path.contains("/.orbstack/") {
                self = .orbStack
            } else if path.contains("/.colima/") {
                self = .colima
            } else if path.contains("/.docker/") {
                self = .dockerDesktop
            } else {
                self = .other
            }
        }
    }

    public let kind: Kind
    public let socketPath: String

    public init(kind: Kind, socketPath: String) {
        self.kind = kind
        self.socketPath = socketPath
    }

    public var name: String {
        kind.title
    }
}

/// Finds the Docker socket, in order:
/// 1. `$DOCKER_HOST`, if it's `unix://` (a TCP or SSH host is ignored: Unix sockets only);
/// 2. `~/.docker/run/docker.sock` (Docker Desktop);
/// 3. `~/.orbstack/run/docker.sock` (OrbStack);
/// 4. `~/.colima/default/docker.sock` (Colima);
/// 5. `/var/run/docker.sock` (whatever linked it there).
///
/// Only checks that a socket file exists (one `stat` each); whether the engine answers is the
/// first request's business.
public enum DockerSocketDiscovery {
    public struct Candidate: Hashable, Sendable {
        public let path: String
        public let kind: DockerEngine.Kind

        public init(path: String, kind: DockerEngine.Kind) {
            self.path = path
            self.kind = kind
        }
    }

    private static let log = Logger(subsystem: "app.mactivity.docker", category: "discovery")

    /// Every place to look, first match wins.
    public static func candidates(environment: [String: String], home: String) -> [Candidate] {
        var list: [Candidate] = []
        if let host = environment["DOCKER_HOST"], !host.isEmpty {
            if host.hasPrefix("unix://") {
                let path = String(host.dropFirst("unix://".count))
                if !path.isEmpty {
                    list.append(Candidate(path: path, kind: DockerEngine.Kind(socketPath: path)))
                }
            } else {
                log.notice("Ignoring DOCKER_HOST that isn't a Unix socket")
            }
        }
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        list += [
            Candidate(path: "\(home)/.docker/run/docker.sock", kind: .dockerDesktop),
            Candidate(path: "\(home)/.orbstack/run/docker.sock", kind: .orbStack),
            Candidate(path: "\(home)/.colima/default/docker.sock", kind: .colima),
        ]
        // Colima's other profiles, and Rancher Desktop (D-145).
        let profiles = (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.colima")) ?? []
        list += profiles.filter { $0 != "default" && !$0.hasPrefix(".") && !$0.hasPrefix("_") }.sorted()
            .map { Candidate(path: "\(home)/.colima/\($0)/docker.sock", kind: .colima) }
        list += [
            Candidate(path: "\(home)/.rd/docker.sock", kind: .other),
            Candidate(path: "/var/run/docker.sock", kind: .other),
        ]
        return list
    }

    /// The first candidate that is a socket something answers on, else the first that is a socket
    /// at all (so the view can say that engine isn't running). A socket file outlives the engine
    /// that made it: a dead Docker Desktop socket used to hide a running OrbStack for good (D-145).
    /// A candidate whose kind is `.other` takes its kind from where its symlink points.
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        isSocket: (String) -> Bool = isSocket,
        isListening: (String) -> Bool = acceptsConnections,
        resolve: (String) -> String = resolvingSymlinks
    ) -> DockerEngine? {
        let sockets = candidates(environment: environment, home: home).filter { isSocket($0.path) }
        guard let candidate = sockets.first(where: { isListening($0.path) }) ?? sockets.first else {
            return nil
        }
        let kind = candidate.kind == .other ? DockerEngine.Kind(socketPath: resolve(candidate.path)) : candidate.kind
        return DockerEngine(kind: kind, socketPath: candidate.path)
    }

    /// Whether something accepts connections on the Unix socket at `path`: a leftover file
    /// refuses at once (ECONNREFUSED).
    public static func acceptsConnections(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, length) == 0 }
        }
    }

    /// `stat` follows symlinks, so a link to a live socket counts.
    public static func isSocket(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return false
        }
        return info.st_mode & S_IFMT == S_IFSOCK
    }

    public static func resolvingSymlinks(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
