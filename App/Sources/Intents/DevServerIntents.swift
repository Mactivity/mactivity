import AppIntents
import Core
import Foundation
import Readouts
import UI

/// Dev servers with a listening port, by project (E6). Read-only.
struct ListDevServersIntent: AppIntent {
    static let title: LocalizedStringResource = "List Dev Servers"
    static let description = IntentDescription(
        "Lists the dev servers running on your Mac, their project, ports, memory, and whether they've gone idle.",
        categoryName: "Projects"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[DevServerEntity]> & ProvidesDialog {
        let projects = try await IntentData.projects()
        let entities = projects.flatMap { project in project.servers.map { DevServerEntity($0, project: project) } }
        return .result(value: entities, dialog: "\(Summaries.devServers(projects))")
    }
}

/// Opens Mactivity on the Projects tab, where idle servers can be stopped.
///
/// Stopping servers from Shortcuts is deliberately out of scope: every stop goes through
/// Mactivity's confirmation dialog (CLAUDE.md rule 4, D-031), and a Shortcut
/// can't show one. This intent only shows them; the user stops them in the app.
struct ShowIdleDevServersIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Idle Dev Servers"
    static let description = IntentDescription(
        "Opens Mactivity's Projects tab to review dev servers that have gone idle. Stopping them happens in Mactivity, after it asks.",
        categoryName: "Projects"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.services.navigation.show(.projects)
        let projects = try await IntentData.projects()
        return .result(dialog: "\(Summaries.idleServers(projects))")
    }
}

/// One dev server at the time of the reading.
struct DevServerEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Dev Server")

    @Property(title: "Project")
    var project: String

    @Property(title: "Project Folder")
    var projectPath: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Command")
    var command: String

    @Property(title: "Runtime")
    var runtime: String

    @Property(title: "Ports")
    var ports: [Int]

    @Property(title: "Memory (bytes)")
    var memoryBytes: Int

    @Property(title: "Process ID")
    var pid: Int

    @Property(title: "Idle")
    var isIdle: Bool

    /// "Working", "Idle 2h 5m", "Barely used".
    @Property(title: "Activity")
    var activity: String

    init() {
        project = ""
        projectPath = ""
        name = ""
        command = ""
        runtime = ""
        ports = []
        memoryBytes = 0
        pid = 0
        isIdle = false
        activity = ""
    }

    init(_ server: DevServer, project: Project) {
        self.init()
        self.project = project.name
        projectPath = project.rootPath
        name = server.name
        command = server.command
        runtime = server.runtime.title
        ports = server.ports.map(Int.init)
        memoryBytes = Int(clamping: server.memoryBytes)
        pid = Int(server.pid)
        isIdle = server.activity.isIdle
        activity = server.activity.title
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(project): \(name)",
            subtitle: "\(Summaries.ports(ports.compactMap { UInt16(exactly: $0) })) · \(activity)"
        )
    }
}
