import Core
import Foundation
import Simulated

/// Fake process details for previews, render tests, and "Simulated data" mode (E12, E1).
///
/// PIDs come from the simulated catalog: Safari's processes and Terminal from `SimulatedCatalog`,
/// the storefront-web dev server from `SimulatedDevServers`. PID 1 is launchd and comes back
/// unreadable, the way it does without the helper. Any other PID gets a small generic process.
/// Remote addresses are from the documentation ranges (RFC 5737, RFC 3849).
public struct SimulatedProcessDetailsSource: ProcessDetailsSource {
    private let now: Date
    /// PIDs that have "exited": `details` returns nil for them.
    private let exited: Set<Int32>

    public init(now: Date = Date(), exited: Set<Int32> = []) {
        self.now = now
        self.exited = exited
    }

    public func details(pid: Int32) async -> ProcessDetails? {
        guard !exited.contains(pid), pid >= 1 else {
            return nil
        }
        switch pid {
        case 1: return launchd
        case SimulatedDevServers.storefrontPID: return devServer
        default: return Self.safariPIDs.firstIndex(of: pid).map { safari(pid, process: $0) } ?? generic(pid)
        }
    }

    public func connections(pids: [Int32]) async -> [Connection] {
        var sockets: [(pid: Int32, socket: SocketEntry)] = []
        for pid in Set(pids) {
            guard let details = await details(pid: pid) else {
                continue
            }
            sockets += details.sockets.map { (pid, $0) }
        }
        return Connection.aggregate(sockets)
    }

    public func hostName(for address: String) async -> String? {
        Self.names[address]
    }

    // MARK: Fixtures

    private static let home = "/Users/demo"
    /// Safari, Safari Networking, and two Safari Web Content processes.
    private static let safariPIDs = SimulatedCatalog.pids(of: "com.apple.Safari")
    private static let terminalPID = SimulatedCatalog.pids(of: "com.apple.Terminal").first ?? 1

    private static let names: [String: String] = [
        "192.0.2.10": "edge-1.cdn.example.net",
        "192.0.2.44": "api.example.com",
        "198.51.100.7": "images.example.org",
        "203.0.113.25": "push.example.com",
        "2001:db8:5::10": "static.example.net",
    ]

    private var launchd: ProcessDetails {
        ProcessDetails(
            pid: 1, name: "launchd", executablePath: "/sbin/launchd", arguments: [], workingDirectory: nil,
            uid: 0, user: "root", startedAt: now.addingTimeInterval(-6 * 86400), parentChain: [],
            threadCount: nil, footprintBytes: nil, cpuTime: nil, openFiles: [], sockets: [],
            unixSocketCount: 0, otherDescriptorCount: 0, isReadable: false,
            unreadableReason: "“launchd” runs as root. Its open files, sockets, and command line need the privileged helper.",
            sampledAt: now
        )
    }

    private var devServer: ProcessDetails {
        let root = Self.home + "/Developer/storefront-web"
        return ProcessDetails(
            pid: SimulatedDevServers.storefrontPID,
            name: "node",
            executablePath: "/opt/homebrew/Cellar/node/24.4.0/bin/node",
            arguments: ["node", root + "/node_modules/.bin/next", "dev", "-p", "4322"],
            workingDirectory: root,
            uid: 501,
            user: "demo",
            startedAt: now.addingTimeInterval(-5 * 3600 - 12 * 60),
            parentChain: [
                .init(pid: 4090, name: "zsh"), .init(pid: 4089, name: "login"), .init(pid: Self.terminalPID, name: "Terminal"),
                .init(pid: 1, name: "launchd"),
            ],
            threadCount: 11,
            footprintBytes: 458 * 1_048_576,
            cpuTime: .seconds(340),
            openFiles: [
                .init(fd: 0, path: "/dev/ttys004", access: .readWrite),
                .init(fd: 1, path: "/dev/ttys004", access: .readWrite),
                .init(fd: 2, path: "/dev/ttys004", access: .readWrite),
                .init(fd: 19, path: root + "/.next/cache/webpack/client-development/0.pack.gz", access: .read),
                .init(fd: 21, path: root + "/.next/trace", access: .write),
                .init(
                    fd: 24,
                    path: root + "/node_modules/.pnpm/next@15.5.0/node_modules/next/dist/compiled/next-server/app-page.runtime.dev.js",
                    access: .read
                ),
                .init(fd: 27, path: root + "/src/app/layout.tsx", access: .read),
                .init(fd: 28, path: root + "/src/app/page.tsx", access: .read),
            ],
            sockets: [
                SocketEntry(
                    fd: 22, transport: .tcp, isIPv6: true, localAddress: nil, localPort: 4322,
                    remoteAddress: nil, remotePort: 0, state: .listen
                ),
                SocketEntry(
                    fd: 25, transport: .tcp, isIPv6: false, localAddress: "127.0.0.1", localPort: 4322,
                    remoteAddress: "127.0.0.1", remotePort: 53144, state: .established
                ),
                SocketEntry(
                    fd: 26, transport: .tcp, isIPv6: false, localAddress: "192.168.1.20", localPort: 53290,
                    remoteAddress: "192.0.2.44", remotePort: 443, state: .established
                ),
                SocketEntry(
                    fd: 30, transport: .udp, isIPv6: false, localAddress: nil, localPort: 61020,
                    remoteAddress: nil, remotePort: 0, state: nil
                ),
            ],
            unixSocketCount: 2,
            otherDescriptorCount: 9,
            isReadable: true,
            unreadableReason: nil,
            sampledAt: now
        )
    }

    /// `process` is the index into Safari's processes: 0 Safari, 1 Networking, 2 and 3 Web Content.
    private func safari(_ pid: Int32, process: Int) -> ProcessDetails {
        let names = ["Safari", "Safari Networking", "Safari Web Content", "Safari Web Content"]
        let name = names.indices.contains(process) ? names[process] : "Safari Web Content"
        let bundle = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
        let service = "com.apple.WebKit." + (process == 1 ? "Networking" : "WebContent")
        let path = process == 0
            ? bundle + "/Contents/MacOS/Safari"
            : "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/\(service).xpc/Contents/MacOS/\(service)"
        let sockets: [SocketEntry] = process == 1
            ? [
                Self.tcp(40, "192.168.1.20", 52011, "192.0.2.10", 443, .established),
                Self.tcp(41, "192.168.1.20", 52012, "192.0.2.10", 443, .established),
                Self.tcp(42, "192.168.1.20", 52013, "192.0.2.10", 443, .established),
                Self.tcp(43, "192.168.1.20", 52020, "198.51.100.7", 443, .established),
                Self.tcp(44, "192.168.1.20", 52031, "203.0.113.25", 5223, .established),
                Self.tcp(45, "192.168.1.20", 52040, "192.0.2.44", 443, .timeWait),
                Self.tcp(46, "2001:db8:1::20", 52050, "2001:db8:5::10", 443, .established, ipv6: true),
                Self.tcp(47, "192.168.1.20", 52060, "198.51.100.90", 80, .synSent),
                SocketEntry(
                    fd: 48, transport: .udp, isIPv6: false, localAddress: "192.168.1.20", localPort: 60311,
                    remoteAddress: "192.0.2.10", remotePort: 443, state: nil
                ),
            ]
            : process == 2
            ? [Self.tcp(30, "192.168.1.20", 52100, "192.0.2.10", 443, .established)]
            : []
        return ProcessDetails(
            pid: pid,
            name: name,
            executablePath: path,
            arguments: [path] + (process == 0 ? [] : ["-ServiceName", service]),
            workingDirectory: "/",
            uid: 501,
            user: "demo",
            startedAt: now.addingTimeInterval(-Double(3 + process) * 3600),
            parentChain: [.init(pid: 1, name: "launchd")],
            threadCount: [0: 38, 1: 17, 2: 24, 3: 9][process],
            footprintBytes: UInt64([0: 380, 1: 96, 2: 1020, 3: 240][process] ?? 100) * 1_048_576,
            cpuTime: .seconds([0: 610, 1: 220, 2: 1830, 3: 45][process] ?? 10),
            openFiles: [
                .init(fd: 3, path: Self.home + "/Library/Safari/History.db", access: .readWrite),
                .init(fd: 4, path: Self.home + "/Library/Safari/History.db-wal", access: .readWrite),
                .init(fd: 5, path: Self.home + "/Library/Caches/com.apple.Safari/WebKitCache/Version 16/Records", access: .read),
                .init(fd: 6, path: "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit", access: .read),
                .init(fd: 7, path: "/private/var/db/timezone/tz/2025b.1.0/icutz/icutz44l.dat", access: .read),
            ],
            sockets: sockets,
            unixSocketCount: 6,
            otherDescriptorCount: 31,
            isReadable: true,
            unreadableReason: nil,
            sampledAt: now
        )
    }

    private func generic(_ pid: Int32) -> ProcessDetails {
        ProcessDetails(
            pid: pid, name: "process-\(pid)", executablePath: "/usr/local/bin/process-\(pid)",
            arguments: ["/usr/local/bin/process-\(pid)", "--serve"], workingDirectory: Self.home,
            uid: 501, user: "demo", startedAt: now.addingTimeInterval(-3600),
            parentChain: [.init(pid: 1, name: "launchd")], threadCount: 4, footprintBytes: 24 * 1_048_576,
            cpuTime: .seconds(3), openFiles: [.init(fd: 3, path: Self.home + "/.config/process/state.json", access: .readWrite)],
            sockets: [], unixSocketCount: 1, otherDescriptorCount: 3, isReadable: true, unreadableReason: nil, sampledAt: now
        )
    }

    private static func tcp(
        _ fd: Int32, _ local: String, _ localPort: UInt16, _ remote: String, _ remotePort: UInt16, _ state: TCPState,
        ipv6: Bool = false
    ) -> SocketEntry {
        SocketEntry(
            fd: fd, transport: .tcp, isIPv6: ipv6, localAddress: local, localPort: localPort,
            remoteAddress: remote, remotePort: remotePort, state: state
        )
    }
}
