import Core
import Docker
import Foundation
import Observation

/// Docker containers for the Projects tab (expansion E5): refreshes every 5 s while a
/// `ContainersSection` is visible, and asks the engine nothing otherwise.
///
/// Stop… goes through the shared `ConfirmedAction` (its terminator must route `.container`
/// targets to `DockerTerminator`). Restart… goes through `restartAction`, a `ConfirmedAction` of
/// its own whose terminator restarts, because `TerminationMode` has no restart case.
@MainActor
@Observable
public final class ContainersModel {
    public static let refreshInterval: Duration = .seconds(5)

    public enum Availability: Equatable, Sendable {
        /// Not asked yet.
        case unknown
        /// No socket in any of the usual places.
        case noEngine
        /// The socket is there but the engine didn't answer (Docker Desktop quit, VM stopped).
        case notRunning(DockerEngine)
        case available(DockerEngine)
    }

    public private(set) var availability: Availability = .unknown
    /// Every container, running or not.
    public private(set) var containers: [Container] = []
    /// Stopped containers are counted in the header and hidden from the table unless this is on.
    public var showsStopped = false
    /// "storefront-web-db-1 stopped." Clears itself.
    public private(set) var toast: String?
    /// The confirmation path for Restart… (CLAUDE.md rule 4). Attach its dialog where the
    /// section is shown; `ContainersSection` does.
    public let restartAction: ConfirmedAction

    @ObservationIgnored private var source: any ContainerSource
    @ObservationIgnored private var visibleViews = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    public init(source: any ContainerSource, restarter: any ContainerRestarter) {
        self.source = source
        restartAction = ConfirmedAction(terminator: ContainerRestartTerminator(restarter))
    }

    /// Docker's disk use, from the same engine (D-224).
    var diskSource: (any DockerDiskSource)? {
        source as? any DockerDiskSource
    }

    /// Swaps the source and the restarter together (simulated vs. real).
    public func replace(source: any ContainerSource, restarter: any ContainerRestarter) {
        self.source = source
        restartAction.setTerminator(ContainerRestartTerminator(restarter))
        containers = []
        availability = .unknown
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
        guard let engine = await source.engine() else {
            containers = []
            availability = .noEngine
            return
        }
        do {
            containers = try await source.containers()
            availability = .available(engine)
        } catch {
            containers = []
            availability = .notRunning(engine)
        }
    }

    // MARK: Derived

    public var runningCount: Int {
        containers.count(where: { $0.state.isActive })
    }

    public var stoppedCount: Int {
        containers.count - runningCount
    }

    /// What the table shows, grouped by compose project.
    public var groups: [ContainerGrouping.Group] {
        ContainerGrouping.groups(showsStopped ? containers : containers.filter(\.state.isActive))
    }

    /// Containers whose compose folder is inside the Mactivity project at `rootPath`.
    public func containers(inProjectAt rootPath: String) -> [Container] {
        containers.filter { $0.belongs(toProjectAt: rootPath) }
    }

    // MARK: Actions

    /// Asks to stop `container` through the shared confirmation path, then rescans.
    public func stop(_ container: Container, through action: ConfirmedAction) {
        guard container.state.isActive else {
            return
        }
        let name = container.name
        let explanation = String(
            localized: """
            Docker sends the container its stop signal and kills it if it's still running after \
            \(DockerTerminator.stopGraceSeconds) seconds.
            """,
            bundle: .strings
        )
        action.ask(ConfirmedAction.Request(
            title: String(localized: "Stop \(name)?", bundle: .strings, comment: "Confirmation title: a project's or container's name"),
            message: ContainerText.describe(container) + "\n\n" + explanation,
            confirmTitle: String(localized: "Stop", bundle: .strings, comment: "Button: stops a scan, a dev server, or a container"),
            targets: [container.target],
            mode: .quit
        ) { [weak self] results in
            Task {
                await self?.finish(
                    succeeded: !results.isEmpty,
                    success: String(localized: "\(name) stopped.", bundle: .strings, comment: "Toast: a project's or container's name"),
                    failure: String(localized: "Couldn't stop \(name).", bundle: .strings, comment: "Toast: a container's name")
                )
            }
        })
    }

    /// Asks to restart `container` through `restartAction`, then rescans.
    public func restart(_ container: Container) {
        let name = container.name
        let ports = ProjectText.ports(container.ports)
        let explanation = container.ports.isEmpty
            ? String(localized: "The container stops, then starts again.", bundle: .strings)
            : String(
                localized: "The container stops, then starts again. Connections to \(ports) drop while it restarts.",
                bundle: .strings,
                comment: "Restart confirmation; the argument is a port phrase such as “port 5432”"
            )
        restartAction.ask(ConfirmedAction.Request(
            title: String(localized: "Restart \(name)?", bundle: .strings, comment: "Confirmation title: a container's name"),
            message: ContainerText.describe(container) + "\n\n" + explanation,
            confirmTitle: String(localized: "Restart", bundle: .strings, comment: "Button: restarts a container"),
            targets: [container.target],
            mode: .quit
        ) { [weak self] results in
            Task {
                await self?.finish(
                    succeeded: !results.isEmpty,
                    success: String(localized: "\(name) restarted.", bundle: .strings, comment: "Toast: a container's name"),
                    failure: String(localized: "Couldn't restart \(name).", bundle: .strings, comment: "Toast: a container's name")
                )
            }
        })
    }

    private func finish(succeeded: Bool, success: String, failure: String) async {
        await refresh()
        show(toast: succeeded ? success : failure)
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

/// Wording for the containers section.
public enum ContainerText {
    /// "Docker Desktop · 4 running", "OrbStack · 2 running · 3 stopped", "Colima · nothing running".
    /// Segments joined by " · "; the engine's name is verbatim.
    public static func header(engine: DockerEngine, running: Int, stopped: Int) -> String {
        var parts = [
            engine.name,
            running == 0
                ? String(localized: "nothing running", bundle: .strings, comment: "Containers header segment: no container is running")
                : String(localized: "\(running) running", bundle: .strings, comment: "Containers header segment: running containers"),
        ]
        if stopped > 0 {
            parts.append(
                String(localized: "\(stopped) stopped", bundle: .strings, comment: "Containers header segment: stopped containers")
            )
        }
        return parts.joined(separator: " · ")
    }

    /// The quiet note when there's no engine to show.
    public static func unavailable(_ availability: ContainersModel.Availability) -> String? {
        switch availability {
        case .unknown, .available: nil
        case .noEngine:
            String(
                localized: "No Docker engine found. Containers show up here while Docker Desktop, OrbStack, or Colima runs.",
                bundle: .strings
            )
        case let .notRunning(engine):
            String(localized: "\(engine.name) isn't running.", bundle: .strings, comment: "A container engine's name, like OrbStack")
        }
    }

    /// "postgres:16-alpine · port 5432".
    static func describe(_ container: Container) -> String {
        container.ports.isEmpty ? container.image : "\(container.image) · \(ProjectText.ports(container.ports))"
    }

    /// "Running", "Exited". Docker's state names, as words.
    public static func state(_ state: Container.State) -> String {
        switch state {
        case .created: String(localized: "Created", bundle: .strings, comment: "Docker container state")
        case .running: String(localized: "Running", bundle: .strings, comment: "Docker container state")
        case .paused: String(localized: "Paused", bundle: .strings, comment: "Docker container state")
        case .restarting: String(localized: "Restarting", bundle: .strings, comment: "Docker container state")
        case .removing: String(localized: "Removing", bundle: .strings, comment: "Docker container state")
        case .exited: String(localized: "Exited", bundle: .strings, comment: "Docker container state")
        case .dead: String(localized: "Dead", bundle: .strings, comment: "Docker container state")
        }
    }

    /// ":5432", ":9000 :9001", "–".
    public static func ports(_ ports: [UInt16]) -> String {
        ports.isEmpty ? "–" : ports.map { ":\($0)" }.joined(separator: " ")
    }
}
