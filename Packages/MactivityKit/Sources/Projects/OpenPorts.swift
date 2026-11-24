import Core
import Darwin
import Foundation

/// Open to the network (1.5, D-230): TCP ports listening on every interface or a network
/// address, not just this Mac (127.0.0.1, ::1), so anyone on the same Wi-Fi can reach them. With
/// the macOS firewall's state. This user's processes only: root's sockets need the helper.
public struct OpenPort: Sendable, Hashable, Identifiable {
    public let pid: Int32
    public let processName: String
    public let port: UInt16
    /// "*" for every interface, else the address it's bound to.
    public let address: String
    public let transport: ListeningPort.Transport

    public var id: String {
        "\(pid):\(transport.rawValue):\(address):\(port)"
    }

    public init(pid: Int32, processName: String, port: UInt16, address: String, transport: ListeningPort.Transport) {
        self.pid = pid
        self.processName = processName
        self.port = port
        self.address = address
        self.transport = transport
    }
}

public struct OpenPortsReading: Sendable, Hashable {
    public let ports: [OpenPort]
    /// The macOS firewall: on, off, or nil when it couldn't be read.
    public let firewallOn: Bool?
    /// Stealth mode: no answer to pings and probes.
    public let stealthOn: Bool?

    public init(ports: [OpenPort], firewallOn: Bool?, stealthOn: Bool? = nil) {
        self.ports = ports
        self.firewallOn = firewallOn
        self.stealthOn = stealthOn
    }
}

public protocol OpenPortSource: Sendable {
    /// `firewall`: also ask the firewall, two short processes; once a visit is enough (D-236).
    func read(firewall: Bool) async -> OpenPortsReading
}

/// Pure rules.
public enum OpenPortRules {
    /// Reachable from other machines: every interface, or an address that isn't loopback.
    public static func isOpen(_ address: String) -> Bool {
        if address == "*" {
            return true
        }
        return !(address.hasPrefix("127.") || address == "::1" || address.lowercased().hasPrefix("::ffff:127."))
    }

    /// What a few of macOS's own listeners are, in plain words, and where to turn them off.
    public static func known(processName: String, port: UInt16) -> String? {
        switch (processName, port) {
        case ("ControlCenter", 5000), ("ControlCenter", 7000):
            String(
                localized: "AirPlay Receiver. Turn it off in System Settings → General → AirDrop & Handoff.",
                bundle: .strings,
                comment: "Open ports: what ControlCenter's listener is"
            )
        case ("rapportd", _):
            String(localized: "Continuity and Handoff between your Apple devices.", bundle: .strings, comment: "Open ports: rapportd")
        case ("sharingd", _):
            String(localized: "AirDrop and sharing.", bundle: .strings, comment: "Open ports: sharingd")
        default:
            nil
        }
    }

    /// `socketfilterfw --getglobalstate` and `--getstealthmode` print "(State = 1)" or "is on".
    /// The number, or the last word, whatever language the rest is in.
    public static func firewallState(_ output: String) -> Bool? {
        if let range = output.range(of: #"State = (\d)"#, options: .regularExpression) {
            return output[range].last.map { $0 != "0" }
        }
        let lowered = output.lowercased()
        if lowered.contains("enabled") || lowered.contains(" is on") {
            return true
        }
        if lowered.contains("disabled") || lowered.contains(" is off") {
            return false
        }
        return nil
    }
}

public struct LiveOpenPorts: OpenPortSource {
    public init() {}

    public func read(firewall: Bool) async -> OpenPortsReading {
        await Task.detached(priority: .utility) { () -> OpenPortsReading in
            OpenPortsReading(
                ports: Self.ports(),
                firewallOn: firewall ? Self.firewall("--getglobalstate") : nil,
                stealthOn: firewall ? Self.firewall("--getstealthmode") : nil
            )
        }.value
    }

    static func ports() -> [OpenPort] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: max(capacity, 64))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else {
            return []
        }
        let me = getuid()
        var found: [OpenPort] = []
        for pid in pids.prefix(Int(count)) where pid > 1 {
            guard let identity = ProcessInspector.identity(pid), identity.uid == me else {
                continue
            }
            for listener in ProcessInspector.listeningPorts(pid) where OpenPortRules.isOpen(listener.address) {
                found.append(OpenPort(
                    pid: pid, processName: identity.name, port: listener.port, address: listener.address, transport: listener.transport
                ))
            }
        }
        // One row per process and port: IPv4 and IPv6 sockets on the same port are one opening.
        var seen = Set<String>()
        return found.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }.filter { seen.insert("\($0.pid):\($0.port)").inserted }
    }

    /// The firewall's state from Apple's own tool, which answers without an administrator.
    static func firewall(_ flag: String) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
        process.arguments = [flag]
        process.environment = ["LANG": "C", "LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return OpenPortRules.firewallState(String(bytes: data, encoding: .utf8) ?? "")
    }
}

public struct SimulatedOpenPorts: OpenPortSource {
    public init() {}

    public func read(firewall _: Bool) async -> OpenPortsReading {
        OpenPortsReading(
            ports: [
                OpenPort(pid: 4321, processName: "node", port: 3000, address: "*", transport: .tcp6),
                OpenPort(pid: 612, processName: "ControlCenter", port: 5000, address: "*", transport: .tcp4),
                OpenPort(pid: 612, processName: "ControlCenter", port: 7000, address: "*", transport: .tcp4),
                OpenPort(pid: 5120, processName: "Python", port: 8080, address: "192.168.1.24", transport: .tcp4),
            ],
            firewallOn: false,
            stealthOn: false
        )
    }
}
