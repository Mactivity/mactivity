import Core
import Foundation
import Observation

/// Dev servers for the Projects views: scans every 5 s while any is visible (spec 5.5).
@MainActor
@Observable
public final class ProjectsModel {
    public static let refreshInterval: Duration = .seconds(5)

    @ObservationIgnored private var sourceGeneration = 0
    public private(set) var projects: [Project] = []
    public private(set) var hasScanned = false
    /// "storefront-web stopped. 458 MB and port 4322 are free." Clears itself.
    public private(set) var toast: String?

    @ObservationIgnored private var source: any ProjectSource
    @ObservationIgnored private var visibleViews = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    public init(source: any ProjectSource) {
        self.source = source
    }

    public func replaceSource(_ source: any ProjectSource) {
        sourceGeneration += 1
        self.source = source
        projects = []
        hasScanned = false
        if visibleViews > 0 {
            startLoop()
        }
    }

    public func appeared() {
        visibleViews += 1
        if visibleViews == 1 {
            startLoop()
        }
    }

    public func disappeared() {
        visibleViews = max(0, visibleViews - 1)
        if visibleViews == 0 {
            loop?.cancel()
            loop = nil
        }
    }

    public func refresh() async {
        let source = source
        let generation = sourceGeneration
        let scanned = await (try? source.projects()) ?? []
        // The source changed while scanning (simulated → real): this list is the old source's.
        guard generation == sourceGeneration else {
            return
        }
        projects = scanned
        hasScanned = true
    }

    public var idleServers: [DevServer] {
        projects.flatMap(\.servers).filter(\.activity.isIdle)
    }

    /// What a stop covers, so the confirmation and the toast can each be one sentence.
    enum StopScope {
        /// One project, by its name.
        case named(String)
        /// Stop All: this many dev servers.
        case all(Int)
        /// Stop Idle: this many idle dev servers.
        case idle(Int)

        var title: String {
            switch self {
            case let .named(name):
                String(localized: "Stop \(name)?", bundle: .strings, comment: "Confirmation title: a project's or container's name")
            case let .all(count):
                String(localized: "Stop all \(count) dev servers?", bundle: .strings)
            case let .idle(count):
                String(localized: "Stop \(count) idle dev servers?", bundle: .strings, comment: "Idle: running but unused lately")
            }
        }

        var stopped: String {
            switch self {
            case let .named(name):
                // A project's name, capitalized as the start of the sentence ("Storefront-web stopped.").
                String(
                    localized: "\(name.prefix(1).uppercased() + name.dropFirst()) stopped.",
                    bundle: .strings,
                    comment: "Toast: a project's or container's name"
                )
            case let .all(count):
                String(localized: "All \(count) dev servers stopped.", bundle: .strings)
            case let .idle(count):
                String(localized: "\(count) idle dev servers stopped.", bundle: .strings, comment: "Idle: running but unused lately")
            }
        }
    }

    /// Asks to stop `servers` through the confirmation path, then rescans and reports what the
    /// rescan shows is actually free (spec 5.5, M6 done-when). `label` is the project's name.
    public func stop(_ servers: [DevServer], label: String, through action: ConfirmedAction) {
        stop(servers, scope: .named(label), through: action)
    }

    func stop(_ servers: [DevServer], scope: StopScope, through action: ConfirmedAction) {
        guard !servers.isEmpty else {
            return
        }
        let ports = Array(Set(servers.flatMap(\.ports))).sorted()
        let memory = servers.reduce(0) { $0 + $1.memoryBytes }
        var lines = servers.prefix(6).map { "\($0.command.isEmpty ? $0.name : $0.command) (\(ProjectText.ports($0.ports)))" }
        if servers.count > 6 {
            lines.append(String(localized: "and \(servers.count - 6) more", bundle: .strings, comment: "After a list of dev servers"))
        }
        let frees = String(
            localized: "Frees \(Formatters.memory(memory)) and \(ProjectText.ports(ports)).",
            bundle: .strings,
            comment: "Stop confirmation: memory, then a port phrase such as “ports 3000 and 4321”"
        )
        action.ask(ConfirmedAction.Request(
            title: scope.title,
            message: lines.joined(separator: "\n") + "\n\n" + frees,
            confirmTitle: servers.count == 1
                ? String(localized: "Stop", bundle: .strings, comment: "Button: stops a scan, a dev server, or a container")
                : String(localized: "Stop \(servers.count)", bundle: .strings, comment: "Button: stops this many dev servers"),
            targets: Array(Set(servers.map(\.stopTarget))),
            mode: .quit
        ) { [weak self] _ in
            Task { await self?.finishStop(scope, ports: ports, memory: memory) }
        })
    }

    private func finishStop(_ scope: StopScope, ports: [UInt16], memory: UInt64) async {
        await refresh()
        let stillHeld = Set(projects.flatMap(\.ports)).intersection(ports).sorted()
        let freed = ports.filter { !stillHeld.contains($0) }
        var sentences = [scope.stopped]
        if !freed.isEmpty {
            let memory = Formatters.memory(memory)
            let ports = ProjectText.ports(freed)
            sentences.append(freed.count == 1
                ? String(localized: "\(memory) and \(ports) is free.", bundle: .strings, comment: "Toast: memory, then “port 3000”")
                : String(
                    localized: "\(memory) and \(ports) are free.",
                    bundle: .strings,
                    comment: "Toast: memory, then a port phrase such as “ports 80 and 443”"
                ))
        }
        if let port = stillHeld.first {
            sentences.append(stillHeld.count == 1
                ? String(localized: "Port \(String(port)) is still in use.", bundle: .strings)
                : String(localized: "Ports \(ProjectText.portList(stillHeld)) are still in use.", bundle: .strings))
        }
        show(toast: sentences.joined(separator: " "))
    }

    private func show(toast text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else {
                return
            }
            self?.toast = nil
        }
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }
}

/// Wording for the Projects views (spec 5.5).
public enum ProjectText {
    /// ":5173 :8787 +14": the first ports and how many more, so a project with dozens (a
    /// Cloudflare dev setup holds 16) can't widen a row past its window.
    public static func portList(_ ports: [UInt16], limit: Int) -> String {
        let shown = ports.prefix(limit).map { ":\($0)" }.joined(separator: " ")
        let more = ports.count - min(limit, ports.count)
        return more > 0 ? shown + " +\(more)" : shown
    }

    /// Every port, for a tooltip.
    public static func allPorts(_ ports: [UInt16]) -> String {
        ports.map { ":\($0)" }.joined(separator: " ")
    }

    /// "port 3000", "ports 3000 and 4321", "ports 3000, 4321, and 8000". A phrase that goes
    /// inside a sentence ("frees 1.3 GB and ports 3000 and 4321"). Port numbers stay ungrouped.
    public static func ports(_ ports: [UInt16]) -> String {
        switch ports.count {
        case 0:
            String(localized: "no ports", bundle: .strings, comment: "Mid-sentence, as in “frees 1 GB and no ports”")
        case 1:
            String(localized: "port \(String(ports[0]))", bundle: .strings, comment: "Mid-sentence: one TCP port number")
        default:
            String(localized: "ports \(portList(ports))", bundle: .strings, comment: "Mid-sentence: a list of TCP port numbers")
        }
    }

    /// "3000, 4321, and 8000", in the locale's list style.
    static func portList(_ ports: [UInt16]) -> String {
        ports.map { String($0) }.formatted(.list(type: .and))
    }

    /// "5 dev servers · 4 idle · stop the idle ones to get back 1.3 GB and ports 3000, 4321, and 8000."
    /// Segments joined by " · "; each segment is one localized phrase.
    public static func summary(_ projects: [Project]) -> String {
        let servers = projects.flatMap(\.servers)
        guard !servers.isEmpty else {
            return String(localized: "No dev servers running", bundle: .strings)
        }
        let count = String(localized: "\(servers.count) dev servers", bundle: .strings, comment: "Projects summary segment")
        let idle = servers.filter(\.activity.isIdle)
        if idle.isEmpty {
            let working = servers.count == 1
                ? String(localized: "working", bundle: .strings, comment: "Projects summary segment: the one dev server is in use")
                : String(localized: "all working", bundle: .strings, comment: "Projects summary segment: every dev server is in use")
            return [count, working].joined(separator: " · ")
        }
        let memory = Formatters.memory(idle.reduce(0) { $0 + $1.memoryBytes })
        let ports = Self.ports(Array(Set(idle.flatMap(\.ports))).sorted())
        let idleCount: String
        let frees: String
        if idle.count == servers.count {
            idleCount = String(
                localized: "all idle",
                bundle: .strings,
                comment: "Projects summary segment: every dev server is idle (running but unused lately)"
            )
            frees = String(
                localized: "stop them to get back \(memory) and \(ports).",
                bundle: .strings,
                comment: "Projects summary segment: memory, then a port phrase such as “ports 3000 and 4321”"
            )
        } else {
            idleCount = String(
                localized: "\(idle.count) idle",
                bundle: .strings,
                comment: "Projects summary segment: how many dev servers are idle (running but unused lately)"
            )
            frees = idle.count == 1
                ? String(
                    localized: "stop it to get back \(memory) and \(ports).",
                    bundle: .strings,
                    comment: "Projects summary segment: memory, then a port phrase such as “port 3000”"
                )
                : String(
                    localized: "stop the idle ones to get back \(memory) and \(ports).",
                    bundle: .strings,
                    comment: "Projects summary segment: memory, then a port phrase such as “ports 3000 and 4321”"
                )
        }
        return [count, idleCount, frees].joined(separator: " · ")
    }
}
