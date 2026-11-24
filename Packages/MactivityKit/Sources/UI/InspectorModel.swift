import AppKit
import Core
import Foundation
import Observation
import Projects

/// Sizes the inspector names. They live here, not in `Tokens`, until the inspector is wired in;
/// then they move to `Tokens.Layout` with the rest.
enum InspectorLayout {
    static let idealSize = CGSize(width: 680, height: 620)
    static let minimumSize = CGSize(width: 560, height: 460)
    static let connectionsIdealSize = CGSize(width: 640, height: 420)
    /// The CPU and memory bars in Overview.
    static let trailWidth: CGFloat = 220
    static let trailHeight: CGFloat = 28
    static let fdColumn: CGFloat = 44
    static let modeColumn: CGFloat = 84
    static let protocolColumn: CGFloat = 52
    static let stateColumn: CGFloat = 96
    static let countColumn: CGFloat = 60
    static let pidsColumnMinimum: CGFloat = 70
    static let lookupColumn: CGFloat = 110
    static let endpointColumnMinimum: CGFloat = 180
    static let endpointColumnIdeal: CGFloat = 220
    static let commandLineLines = 6
    static let listeningTableMaxHeight: CGFloat = 150
}

/// What the inspector shows for one PID, refreshed every 2 s while it's on screen (E12).
@MainActor
@Observable
final class InspectorModel {
    static let refreshInterval: Duration = .seconds(2)

    enum Phase: Equatable {
        case loading
        case loaded
        /// The process is gone: it exited, or it was quit from here.
        case exited
    }

    /// The PID on screen. Clicking an ancestor pushes the current one onto `history`.
    private(set) var pid: Int32
    private(set) var history: [(pid: Int32, name: String)] = []
    private(set) var details: ProcessDetails?
    private(set) var phase: Phase = .loading
    let names: HostNameLookup

    @ObservationIgnored let source: any ProcessDetailsSource

    init(pid: Int32, source: any ProcessDetailsSource) {
        self.pid = pid
        self.source = source
        names = HostNameLookup(source: source)
    }

    func refresh() async {
        let requested = pid
        let fresh = await source.details(pid: requested)
        // An ancestor click may have moved on while the read was in flight.
        guard requested == pid else {
            return
        }
        if let fresh {
            details = fresh
            phase = .loaded
        } else {
            phase = .exited
        }
    }

    /// Refreshes until the task is cancelled (the view went away or changed PID).
    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func inspect(_ ancestor: Int32) {
        guard ancestor != pid else {
            return
        }
        history.append((pid, details?.name ?? String(pid)))
        show(ancestor)
    }

    func goBack() {
        guard let previous = history.popLast() else {
            return
        }
        show(previous.pid)
    }

    private func show(_ newPID: Int32) {
        pid = newPID
        details = nil
        phase = .loading
    }

    /// Whether Quit and Force Quit apply: a readable process that isn't launchd or Mactivity.
    var canQuit: Bool {
        guard let details, phase == .loaded else {
            return false
        }
        return details.isReadable && details.pid > 1 && details.pid != getpid()
    }

    var quitUnavailableReason: String? {
        guard let details, phase == .loaded, !canQuit else {
            return nil
        }
        if details.pid == getpid() {
            return String(localized: "This is Mactivity.", bundle: .strings, comment: "Why the inspector can't quit this process")
        }
        return String(
            localized: "This process belongs to macOS or another user, so Mactivity can't quit it.",
            bundle: .strings,
            comment: "Why the inspector can't quit this process"
        )
    }

    /// A `ProcessSample` for `AppServices.requestQuit(_:mode:)`, which only reads the PID and name.
    var quitTarget: ProcessSample? {
        guard let details else {
            return nil
        }
        return ProcessSample(
            pid: details.pid, app: "", name: details.name, cpuPercent: 0, footprintBytes: details.footprintBytes ?? 0,
            diskReadBPS: 0, diskWriteBPS: 0, energyMW: nil, netInBPS: nil, netOutBPS: nil, gpuPercent: nil
        )
    }
}

/// Host names the user clicked "Look up name" for, one address at a time. Nothing is looked up
/// unless `ReverseDNS.allowLookupsKey` is set in Settings → Privacy (D-051).
@MainActor
@Observable
final class HostNameLookup {
    private(set) var names: [String: String] = [:]
    private(set) var inFlight: Set<String> = []
    /// Looked up, and there was no name.
    private(set) var unnamed: Set<String> = []

    @ObservationIgnored private let source: any ProcessDetailsSource

    init(source: any ProcessDetailsSource) {
        self.source = source
    }

    func lookUp(_ address: String) async {
        guard names[address] == nil, !unnamed.contains(address), inFlight.insert(address).inserted else {
            return
        }
        let name = await source.hostName(for: address)
        inFlight.remove(address)
        if let name {
            names[address] = name
        } else {
            unnamed.insert(address)
        }
    }
}

/// Small helpers the inspector views share.
enum InspectorText {
    /// "293 files · 5 sockets · 1 Unix socket · 8 other"
    static func descriptorSummary(_ details: ProcessDetails) -> String {
        [
            String(localized: "\(details.openFiles.count) files", bundle: .strings),
            sockets(details.sockets.count),
            details.unixSocketCount > 0
                ? String(localized: "\(details.unixSocketCount) Unix sockets", bundle: .strings, comment: "Open file descriptors")
                : nil,
            details.otherDescriptorCount > 0
                ? String(localized: "\(details.otherDescriptorCount) other", bundle: .strings, comment: "Other open file descriptors")
                : nil,
        ]
        .compactMap(\.self)
        .joined(separator: " · ")
    }

    /// "1 socket", "5 sockets".
    static func sockets(_ count: Int) -> String {
        String(localized: "\(count) sockets", bundle: .strings, comment: "Network sockets a process has open")
    }

    /// "1 port", "3 ports": listening ports.
    static func ports(_ count: Int) -> String {
        String(localized: "\(count) ports", bundle: .strings, comment: "TCP or UDP ports a process listens on")
    }

    /// Home abbreviated to `~` (`Formatters.displayPath`).
    static func abbreviated(_ path: String) -> String {
        Formatters.displayPath(path, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// The outermost `.app` bundle in a path, for its icon.
    static func bundlePath(_ executable: String?) -> String? {
        guard let executable, let range = executable.range(of: ".app/") else {
            return nil
        }
        return String(executable[..<range.lowerBound]) + ".app"
    }

    /// Whether Finder can show this path: it exists and isn't a device node.
    static func canReveal(_ path: String?) -> Bool {
        guard let path, !path.hasPrefix("/dev/") else {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }

    @MainActor
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One process's recent CPU and memory, collected from the live snapshots while its inspector
/// is open (spec E12). No extra sampling: the snapshots already carry every process. Pure.
struct ProcessTrail: Equatable {
    private(set) var cpu: [LiveMetrics.Point] = []
    private(set) var memory: [LiveMetrics.Point] = []
    /// Snapshots in a row that didn't carry the process.
    private(set) var missedSnapshots = 0
    private var nextID = 0
    private var lastAt: Date?

    /// As many points as a card's sparkline keeps (`LiveMetrics.historyLength`).
    static let capacity = 120
    /// Snapshots without the process before the trail says "Not sampled" instead of "Measuring…".
    static let missesBeforeUnsampled = 2

    /// No line yet, and the latest snapshots haven't carried the process: Mactivity isn't
    /// sampling it (macOS's processes while the macOS row is collapsed, another user's without
    /// the helper), so "Measuring…" would never resolve.
    var isUnsampled: Bool {
        cpu.count < 2 && missedSnapshots >= Self.missesBeforeUnsampled
    }

    /// Adds the process's figures from a snapshot, once per snapshot; a snapshot without it adds
    /// nothing but counts as a miss. Keeps the last `capacity` points.
    mutating func add(_ snapshot: Snapshot, pid: Int32) {
        guard snapshot.at != lastAt else {
            return
        }
        lastAt = snapshot.at
        guard let sample = snapshot.processes.first(where: { $0.pid == pid }) else {
            missedSnapshots += 1
            return
        }
        missedSnapshots = 0
        cpu.append(LiveMetrics.Point(id: nextID, at: snapshot.at, value: sample.cpuPercent))
        memory.append(LiveMetrics.Point(id: nextID, at: snapshot.at, value: Double(sample.footprintBytes)))
        nextID += 1
        let excess = cpu.count - Self.capacity
        if excess > 0 {
            cpu.removeFirst(excess)
            memory.removeFirst(excess)
        }
    }
}
