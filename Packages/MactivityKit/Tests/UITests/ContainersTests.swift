import AppKit
import Core
import Docker
import SwiftUI
import Testing
@testable import UI

@MainActor
@Suite("Containers")
struct ContainersUITests {
    private func model(_ source: SimulatedContainerSource = SimulatedContainerSource()) async -> ContainersModel {
        let model = ContainersModel(source: source, restarter: source)
        await model.refresh()
        return model
    }

    @Test("Header wording", arguments: [
        (4, 0, "Docker Desktop · 4 running"),
        (1, 2, "Docker Desktop · 1 running · 2 stopped"),
        (0, 0, "Docker Desktop · nothing running"),
    ])
    func header(running: Int, stopped: Int, expected: String) {
        let engine = DockerEngine(kind: .dockerDesktop, socketPath: "/x")
        #expect(ContainerText.header(engine: engine, running: running, stopped: stopped) == expected)
    }

    @Test("No engine is a quiet note, not an error")
    func noEngine() async {
        let model = await model(SimulatedContainerSource(engine: nil))
        #expect(model.availability == .noEngine)
        #expect(ContainerText.unavailable(model.availability)?.hasPrefix("No Docker engine found.") == true)
        #expect(model.groups.isEmpty)
    }

    @Test("Stopped containers are counted and hidden until asked for")
    func stoppedHidden() async {
        let model = await model()
        #expect(model.runningCount == 5 && model.stoppedCount == 1)
        #expect(!model.groups.flatMap(\.containers).contains { $0.state == .exited })
        model.showsStopped = true
        #expect(model.groups.flatMap(\.containers).count == 6)
        #expect(model.containers(inProjectAt: "/Users/demo/Developer/storefront-web").count == 3)
    }

    @Test("Stop and Restart go through the confirmation, and nothing happens without it")
    func confirmation() async throws {
        let source = SimulatedContainerSource()
        let model = await model(source)
        let stopAction = ConfirmedAction(terminator: ContainerRoutingTerminator(containers: source, everythingElse: source))
        let db = try #require(model.containers.first { $0.name == "storefront-web-db-1" })

        model.stop(db, through: stopAction)
        #expect(stopAction.pending?.targets == [db.target])
        #expect(stopAction.pending?.confirmTitle == "Stop")
        #expect(await source.requests.isEmpty, "Asking sends nothing")
        stopAction.cancel()
        #expect(await source.requests.isEmpty, "Cancelling sends nothing")

        model.stop(db, through: stopAction)
        await stopAction.confirm()
        #expect(await source.requests.map(\.target) == [db.target])
        #expect(await source.requests.first?.mode == .quit)

        model.restart(db)
        #expect(model.restartAction.pending?.confirmTitle == "Restart")
        #expect(await source.requests.count == 1, "Asking to restart sends nothing")
        await model.restartAction.confirm()
        #expect(await source.requests.count == 2)
        #expect(try await source.containers().first { $0.id == db.id }?.state == .running)
    }
}

/// Renders the containers section in light and dark for docs/screenshots/E5. Runs only when
/// `MACTIVITY_SNAPSHOT_DIR` is set; a normal `make test` skips it.
///
/// `Table` is AppKit underneath, which `ImageRenderer` doesn't draw, so this hosts the view in an
/// offscreen window and caches its display instead.
@MainActor
@Suite("Containers snapshot renders", .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] != nil))
struct ContainersSnapshotRenderTests {
    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACTIVITY_SNAPSHOT_DIR"] ?? "/tmp")
    }

    private func write(_ view: some View, name: String, size: CGSize) async throws {
        for (scheme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let framed = view
                .padding(Tokens.Spacing.l)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: framed)
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFrontRegardless()
            // Let the table load its rows and the model's first refresh land.
            for _ in 0 ..< 10 {
                host.layoutSubtreeIfNeeded()
                host.display()
                try await Task.sleep(for: .milliseconds(50))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            window.orderOut(nil)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @Test("Containers grouped by compose project")
    func containers() async throws {
        let source = SimulatedContainerSource()
        let model = ContainersModel(source: source, restarter: source)
        await model.refresh()
        let section = ContainersSection(model: model, confirmedAction: ConfirmedAction(terminator: source))
        try await write(section, name: "containers", size: CGSize(width: 1000, height: 520))

        model.showsStopped = true
        try await write(section, name: "containers-with-stopped", size: CGSize(width: 1000, height: 565))
    }

    @Test("No engine: one quiet line")
    func noEngine() async throws {
        let source = SimulatedContainerSource(engine: nil)
        let model = ContainersModel(source: source, restarter: source)
        await model.refresh()
        let section = ContainersSection(model: model, confirmedAction: ConfirmedAction(terminator: source))
        try await write(section, name: "containers-no-engine", size: CGSize(width: 1000, height: 72))
    }
}
