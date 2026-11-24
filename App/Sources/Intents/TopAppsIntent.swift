import AppIntents
import Core
import Foundation
import Readouts

/// The busiest apps by one metric (E6). Processes are summed per app, as in Mactivity's lists;
/// the macOS row is left out.
struct TopAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Top Apps"
    static let description = IntentDescription(
        "Lists the apps using the most CPU, memory, energy, disk, or network, with every helper process counted under its app.",
        categoryName: "System"
    )

    @Parameter(title: "Metric", default: .cpu)
    var metric: AppMetric

    @Parameter(title: "Number of Apps", default: 5, inclusiveRange: (1, 20))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Get the top \(\.$limit) apps by \(\.$metric)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[AppUsageEntity]> & ProvidesDialog {
        let snapshot = try await IntentData.snapshot()
        let ranking = metric.ranking
        let apps = ranking.rank(snapshot.apps, limit: limit, includingSystem: false)
        let entities = apps.map { AppUsageEntity($0, ranking: ranking) }
        return .result(value: entities, dialog: "\(Summaries.topApps(apps, by: ranking))")
    }
}

/// `AppRanking` as Shortcuts sees it.
enum AppMetric: String, AppEnum {
    case cpu, memory, energy, disk, network

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Metric")
    static let caseDisplayRepresentations: [AppMetric: DisplayRepresentation] = [
        .cpu: "CPU",
        .memory: "Memory",
        .energy: "Energy",
        .disk: "Disk",
        .network: "Network",
    ]

    var ranking: AppRanking {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .energy: .energy
        case .disk: .disk
        case .network: .network
        }
    }
}

/// One app's figures at the time of the reading.
struct AppUsageEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "App Usage")

    @Property(title: "Name")
    var name: String

    @Property(title: "Bundle Identifier")
    var bundleID: String?

    @Property(title: "Processes")
    var processCount: Int

    @Property(title: "CPU (%)")
    var cpuPercent: Double

    @Property(title: "Memory (bytes)")
    var memoryBytes: Int

    /// The ranked figure, formatted ("6.2 GB", "13%").
    @Property(title: "Value")
    var value: String

    init() {
        name = ""
        bundleID = nil
        processCount = 0
        cpuPercent = 0
        memoryBytes = 0
        value = ""
    }

    init(_ app: AppAggregate, ranking: AppRanking) {
        self.init()
        name = app.app.name
        bundleID = app.app.bundleID
        processCount = app.processCount
        cpuPercent = (app.cpuPercent * 10).rounded() / 10
        memoryBytes = Int(clamping: app.memoryBytes)
        value = ranking.formatted(app)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(value)")
    }
}
