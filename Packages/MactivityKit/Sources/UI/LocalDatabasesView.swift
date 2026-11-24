import Core
import Observation
import SwiftUI

/// Projects → Databases' state (D-277): the servers every 30 seconds while the view shows; each
/// data folder walked when first seen and again after 10 minutes, never with the view away; when
/// each was last busy from History, once an hour.
@MainActor
@Observable
final class LocalDatabasesModel {
    private let source: any LocalDatabaseSource
    private(set) var databases: [LocalDatabase] = []
    /// Data folder → what its walk found. Missing: not walked yet, or not readable.
    private(set) var disk: [String: DatabaseDiskUse] = [:]
    /// Data folders already walked with no answer: they said no, so it's not "still sizing".
    private(set) var unreadable = Set<String>()
    /// Process name → the newest hour History saw it busy; missing when it never was.
    private(set) var lastBusy: [String: Date] = [:]
    private(set) var historySince: Date?
    private(set) var loaded = false
    @ObservationIgnored private var walkedAt: [String: Date] = [:]
    @ObservationIgnored private var historyReadAt: Date?
    @ObservationIgnored private var historyRead = Set<String>()

    static let walkEvery: TimeInterval = 10 * 60

    /// `historySince`: render tests, which have no History to ask.
    init(source: any LocalDatabaseSource, historySince: Date? = nil) {
        self.source = source
        self.historySince = historySince
    }

    func load(history: (any HistoryStore)?, now: Date = Date()) async {
        let found = await source.databases()
        databases = found
        loaded = true
        await readHistory(found, history: history, now: now)
        for database in found {
            guard let folder = database.dataDirectory, !Task.isCancelled else {
                continue
            }
            if let walked = walkedAt[folder], now.timeIntervalSince(walked) < Self.walkEvery, now >= walked {
                continue
            }
            walkedAt[folder] = now
            let use = await source.diskUse(of: database)
            // The view went away mid-walk: a part of a folder isn't its size. Again next time.
            guard !Task.isCancelled else {
                walkedAt[folder] = nil
                return
            }
            if let use {
                disk[folder] = use
                unreadable.remove(folder)
            } else {
                disk[folder] = nil
                unreadable.insert(folder)
            }
        }
    }

    private func readHistory(_ found: [LocalDatabase], history: (any HistoryStore)?, now: Date) async {
        guard let daily = history as? any DailyHistoryStore else {
            return
        }
        let stale = historyReadAt.map { now.timeIntervalSince($0) >= 3600 || now < $0 } ?? true
        if stale {
            historySince = await (try? daily.firstRecorded()).flatMap(\.self)
            historyRead = []
            historyReadAt = now
        }
        for name in Set(found.map(\.processName)).subtracting(historyRead) {
            let points = await (try? daily.series(
                metric: .cpu, app: "other:" + name, from: now.addingTimeInterval(-60 * 86400), to: now
            )) ?? []
            lastBusy[name] = LocalDatabaseRules.lastBusy(points)
            historyRead.insert(name)
        }
    }

    func use(of database: LocalDatabase) -> DatabaseDiskUse? {
        database.dataDirectory.flatMap { disk[$0] }
    }

    func activity(_ database: LocalDatabase, now: Date = Date()) -> LocalDatabaseRules.Activity {
        LocalDatabaseRules.activity(
            connections: database.connections, isReadable: database.isReadable, lastWrite: use(of: database)?.lastWrite,
            dataKnown: use(of: database) != nil, lastBusy: lastBusy[database.processName], historySince: historySince, now: now
        )
    }
}

/// Projects → Databases (D-277): each database server running on this Mac, its memory, its data
/// on disk, and whether anything has used it lately. Only ever shows: it connects to none.
struct LocalDatabasesView: View {
    let model: LocalDatabasesModel
    let history: (any HistoryStore)?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                Text(summary)
                    .font(Tokens.Typography.cardTitle)
                    .monospacedDigit()
                if let quiet = quietSummary {
                    Text(quiet)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(Tokens.Colors.strainLabel)
                }
                Spacer()
            }
            .cardStyle()
            if !model.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.databases.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No local databases running", bundle: .strings), systemImage: "cylinder.split.1x2")
                } description: {
                    Text(
                        """
                        PostgreSQL, MySQL, Redis and MongoDB show here while they run on this Mac. One inside Docker shows under \
                        Servers: its processes aren't this Mac's. Mactivity never connects to a database or reads what's in it.
                        """,
                        bundle: .strings
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
                    .clipShape(Tokens.Shapes.card)
                    .fittedTable(TableFit.height(twoLineRows: model.databases.count))
                    .layoutPriority(1)
                Text(
                    "Never connects to a database or reads what's in it: only process figures, and file names, sizes and dates.",
                    bundle: .strings
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            while !Task.isCancelled {
                await model.load(history: history)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var table: some View {
        Table(model.databases) {
            TableColumn(Text("Database", bundle: .strings, comment: "Databases column: PostgreSQL, Redis…")) { database in
                VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                    Text(verbatim: database.engine.title).font(Tokens.Typography.rowTitle)
                    Text(database.dataDirectory.map { Formatters.displayPath($0, home: NSHomeDirectory()) } ?? Self.noFolder(database))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Self.folderHelp(database))
                }
            }
            .width(min: 100, ideal: 120)
            TableColumn(Text("Ports", bundle: .strings)) { database in
                Text(database.ports.isEmpty ? "–" : database.ports.map { ":\($0)" }.joined(separator: " "))
                    .font(Tokens.Typography.code)
                    .lineLimit(1)
            }
            .width(min: 46, ideal: 50)
            TableColumn(Text("Memory", bundle: .strings)) { database in
                Text(database.isReadable ? Formatters.memory(database.memoryBytes) : "–")
                    .monospacedDigit()
                    .help(database.isReadable ? Text(verbatim: "") : HomebrewServicesView.rootHelp)
            }
            .width(56)
            .alignment(.numeric)
            TableColumn(Text("On disk", bundle: .strings, comment: "Databases column: the size of its data folder")) { database in
                Text(diskText(database))
                    .monospacedDigit()
                    .foregroundStyle(model.use(of: database) == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            .width(64)
            .alignment(.numeric)
            TableColumn(Text("Last used", bundle: .strings, comment: "Databases column: the last sign anything used it")) { database in
                let activity = model.activity(database)
                Text(Self.activityText(activity))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(Self.isQuiet(activity) ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .help(Self.activityHelp)
            }
            .width(min: 90, ideal: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private static func noFolder(_ database: LocalDatabase) -> String {
        database.isReadable
            ? String(localized: "Data folder not found", bundle: .strings, comment: "Databases: nothing says where its data is")
            : String(localized: "Runs as another user", bundle: .strings, comment: "Databases: its arguments and figures can't be read")
    }

    private static func folderHelp(_ database: LocalDatabase) -> Text {
        switch database.dataSource {
        case .arguments: Text("Named in its arguments", bundle: .strings, comment: "Databases: how its data folder was found")
        case .workingDirectory: Text("The folder it runs in", bundle: .strings, comment: "Databases: how its data folder was found")
        case .usualPlace: Text("Homebrew's usual folder for it", bundle: .strings, comment: "Databases: how its data folder was found")
        case nil: Text("Mactivity leaves this blank rather than guess at a folder", bundle: .strings)
        }
    }

    private func diskText(_ database: LocalDatabase) -> String {
        guard let folder = database.dataDirectory else {
            return "–"
        }
        if let use = model.disk[folder] {
            return Formatters.bytes(use.bytes)
        }
        return model.unreadable.contains(folder)
            ? String(localized: "Can't read", bundle: .strings, comment: "Databases: its data folder can't be read")
            : String(localized: "Sizing…", bundle: .strings, comment: "Databases: its data folder is being sized")
    }

    private static func isQuiet(_ activity: LocalDatabaseRules.Activity) -> Bool {
        if case .quiet = activity {
            return true
        }
        return false
    }

    static func activityText(_ activity: LocalDatabaseRules.Activity) -> String {
        switch activity {
        case .inUseNow:
            return String(localized: "In use now", bundle: .strings, comment: "Databases: something is connected to it")
        case let .lastUsed(date):
            return date.formatted(.relative(presentation: .named))
        case let .quiet(since):
            if let since {
                return String(
                    localized: "No sign of use since \(since.formatted(date: .abbreviated, time: .omitted))",
                    bundle: .strings,
                    comment: "Databases: no write to its data, no busy hour and no connection since this date"
                )
            }
            return String(localized: "No sign of use", bundle: .strings, comment: "Databases: no write, busy hour or connection")
        case .unknown:
            return String(localized: "Can't tell yet", bundle: .strings, comment: "Databases: too little to go on")
        }
    }

    private static let activityHelp = Text(
        """
        The newer of the last write to its data and the last hour it used 1% of a core or more. "No sign of use" means neither in two \
        weeks and nothing connected now. A database only ever read, gently, leaves no sign, so check before you remove one.
        """,
        bundle: .strings
    )

    private var summary: String {
        guard model.loaded, !model.databases.isEmpty else {
            return String(localized: "Local databases", bundle: .strings)
        }
        let memory = Formatters.memory(model.databases.reduce(0) { $0 &+ $1.memoryBytes })
        let onDisk = Formatters.bytes(model.databases.reduce(0) { $0 &+ (model.use(of: $1)?.bytes ?? 0) })
        return String(
            localized: "Running: \(model.databases.count), \(memory) of memory, \(onDisk) on disk",
            bundle: .strings,
            comment: "Databases summary: how many, the memory they hold, the size of their data"
        )
    }

    private var quietSummary: String? {
        let quiet = model.databases.filter { Self.isQuiet(model.activity($0)) }
        guard !quiet.isEmpty else {
            return nil
        }
        return String(
            localized: "No sign of use in two weeks: \(quiet.map(\.engine.title).formatted(.list(type: .and)))",
            bundle: .strings,
            comment: "Databases: the ones with no write, busy hour or connection in two weeks"
        )
    }
}
