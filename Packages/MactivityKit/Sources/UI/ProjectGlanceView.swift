import Core
import Observation
import SwiftUI

/// Projects → Folders' first view (D-279): one scan when it first shows, kept while the app runs,
/// again on Rescan, as Space per project.
@MainActor
@Observable
final class ProjectGlanceModel {
    private let source: any ProjectGlanceSource
    private(set) var projects: [ProjectGlance] = []
    private(set) var isScanning = false
    private(set) var scannedAt: Date?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Which of the Folders page's two views shows.
    var showsBuildFolders = false

    init(source: any ProjectGlanceSource) {
        self.source = source
    }

    func appeared() {
        if scannedAt == nil, !isScanning {
            rescan()
        }
    }

    /// Walking folders is only for while it shows. What's sized so far stays; it starts over next time.
    func disappeared() {
        scanTask?.cancel()
    }

    func rescan() {
        guard !isScanning else {
            return
        }
        isScanning = true
        let source = source
        let update: @Sendable ([ProjectGlance]) -> Void = { [weak self] projects in
            Task { @MainActor in
                if let self, self.isScanning {
                    self.projects = projects
                }
            }
        }
        scanTask = Task { [weak self] in
            let found = await source.scan(update: update)
            guard let self else {
                return
            }
            projects = found
            scannedAt = Task.isCancelled ? scannedAt : Date()
            isScanning = false
        }
    }
}

/// Projects → Folders: each project at a glance, or the build folders in each.
struct ProjectFoldersView: View {
    let glance: ProjectGlanceModel
    let space: ProjectSpaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Picker(
                String(localized: "Show", bundle: .strings, comment: "Space per project: all projects, or only untouched ones"),
                selection: Binding(get: { glance.showsBuildFolders }, set: { glance.showsBuildFolders = $0 })
            ) {
                Text("At a Glance", bundle: .strings, comment: "Projects → Folders: each project's language, version, size").tag(false)
                Text("Build Folders", bundle: .strings, comment: "Projects → Folders: each project's rebuildable folders").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if glance.showsBuildFolders {
                ProjectSpaceView(model: space)
            } else {
                ProjectGlanceView(model: glance)
            }
        }
    }
}

struct ProjectGlanceView: View {
    let model: ProjectGlanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            header
            if model.projects.isEmpty {
                if model.isScanning {
                    VStack(spacing: Tokens.Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Looking for projects…", bundle: .strings)
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(String(localized: "No project folders found", bundle: .strings), systemImage: "folder")
                    } description: {
                        Text(
                            """
                            Projects in ~/Developer, ~/Projects, ~/Code and the other usual folders, and every project Xcode has built, \
                            show here.
                            """,
                            bundle: .strings
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                table
                    .clipShape(Tokens.Shapes.card)
                    .layoutPriority(1)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Text(summary)
                .font(Tokens.Typography.cardTitle)
                .monospacedDigit()
            Spacer()
            if let scannedAt = model.scannedAt {
                Text(
                    "Sized \(scannedAt.formatted(.relative(presentation: .named)))",
                    bundle: .strings,
                    comment: "Space per project: when the folders were last sized, e.g. Sized 2 hours ago"
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.tertiary)
            }
            Button(String(localized: "Rescan", bundle: .strings, comment: "Space per project: look again")) { model.rescan() }
                .disabled(model.isScanning)
        }
        .cardStyle()
    }

    private var summary: String {
        guard !model.projects.isEmpty else {
            return String(localized: "Project folders", bundle: .strings)
        }
        let total = Formatters.bytes(model.projects.reduce(0) { $0 &+ ($1.sizeBytes ?? 0) })
        return String(
            localized: "Projects: \(model.projects.count), \(total)",
            bundle: .strings,
            comment: "Projects at a glance summary: how many projects, their size together"
        )
    }

    private var table: some View {
        Table(model.projects) {
            TableColumn(Text("Project", bundle: .strings)) { project in
                VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                    Text(project.name).font(Tokens.Typography.rowTitle).lineLimit(1)
                    Text(Formatters.displayPath(project.root, home: NSHomeDirectory()))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 100, ideal: 120)
            TableColumn(Text("Language", bundle: .strings, comment: "Projects at a glance column")) { project in
                Text(project.languages.first?.title ?? "–")
                    .foregroundStyle(project.languages.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .help(project.languages.isEmpty
                        ? Text("No marker file says", bundle: .strings, comment: "Projects at a glance: no Package.swift, package.json…")
                        : Text(verbatim: project.languages.map(\.title).formatted(.list(type: .and))))
            }
            .width(min: 64, ideal: 70)
            TableColumn(Text("Version", bundle: .strings, comment: "Projects at a glance column: the runtime it asks for")) { project in
                if let runtime = project.runtime {
                    Text(verbatim: "\(runtime.runtime) \(runtime.version)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(
                            "What \(runtime.file) asks for, not what's installed",
                            bundle: .strings,
                            comment: "Projects at a glance: the file that names the runtime version"
                        ))
                } else {
                    Text(verbatim: "–").foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 90)
            TableColumn(Text("Size", bundle: .strings)) { project in
                Text(project.sizeBytes.map { Formatters.bytes($0) } ?? (model.isScanning ? "…" : "–"))
                    .monospacedDigit()
            }
            .width(56)
            .alignment(.numeric)
            TableColumn(Text("Last worked", bundle: .strings, comment: "Projects at a glance column: the last sign of work")) { project in
                Text(project.lastWorked.map { $0.formatted(.relative(presentation: .named)) } ?? "–")
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(Self.lastWorkedHelp)
            }
            .width(min: 70, ideal: 76)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private static let lastWorkedHelp = Text(
        """
        The newest of its last commit, its last `git status`, and the files at the top of its folder. An edit deep inside with no git \
        involved doesn't show, and an editor running `git status` by itself does.
        """,
        bundle: .strings
    )
}
