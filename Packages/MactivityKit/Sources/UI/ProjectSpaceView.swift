import Core
import Storage
import SwiftUI

/// Projects → Space (D-223): each project's rebuildable folders, largest project first, with the
/// ones untouched for two months marked. Move to Trash goes through the storage confirm step.
struct ProjectSpaceView: View {
    let model: ProjectSpaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.gridGutter) {
            header
            if let docker = model.docker, docker.bytes > 0 {
                DockerDiskCard(usage: docker)
            }
            content
                .layoutPriority(1)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(text: toast)
            }
        }
        .animation(Tokens.Motion.figure, value: model.toast)
        .storageTrashDialog(model.trashStep, trasher: model.trasher)
        .onAppear { model.appeared() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                Text(ProjectSpaceText.summary(model.spaces))
                    .font(Tokens.Typography.cardTitle)
                    .monospacedDigit()
                Spacer()
                controls
            }
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                if let stale = ProjectSpaceText.staleSummary(model.spaces, now: Date()) {
                    Text(stale)
                        .foregroundStyle(Tokens.Colors.strainLabel)
                    // The roadmap's promise: untouched projects offered for the Trash (D-229).
                    Button(String(
                        localized: "Move Untouched to Trash…",
                        bundle: .strings,
                        comment: "Moves every untouched project's build folders to the Trash, after a confirmation"
                    )) { model.askToTrashUntouched() }
                        .controlSize(.small)
                        .disabled(model.isScanning)
                }
                Spacer()
                if let scannedAt = model.scannedAt {
                    Text(
                        "Sized \(scannedAt.formatted(.relative(presentation: .named)))",
                        bundle: .strings,
                        comment: "Space per project: when the folders were last sized, e.g. Sized 2 hours ago"
                    )
                    .foregroundStyle(.tertiary)
                }
            }
            .font(Tokens.Typography.secondary)
        }
        .cardStyle()
    }

    private var controls: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Picker(
                String(localized: "Show", bundle: .strings, comment: "Space per project: all projects, or only untouched ones"),
                selection: Binding(get: { model.staleOnly }, set: { model.staleOnly = $0 })
            ) {
                Text("All", bundle: .strings, comment: "Space per project: every project").tag(false)
                Text("Untouched", bundle: .strings, comment: "Space per project: projects with no work in two months").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(Text("Untouched: no commit, no `git status`, no new file in two months", bundle: .strings))
            Button(String(localized: "Rescan", bundle: .strings, comment: "Space per project: look again")) { model.rescan() }
                .disabled(model.isScanning)
        }
    }

    @ViewBuilder private var content: some View {
        let shown = model.shown()
        if case let .scanning(done, total) = model.phase, model.spaces.isEmpty {
            VStack(spacing: Tokens.Spacing.s) {
                ProgressView().controlSize(.small)
                Text(
                    total > 0
                        ? String(localized: "Sizing project \(done) of \(total)…", bundle: .strings, comment: "Space per project: progress")
                        : String(localized: "Looking for projects…", bundle: .strings)
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            ContentUnavailableView {
                Label(
                    model.staleOnly
                        ? String(localized: "Every project has been worked on lately", bundle: .strings)
                        : String(localized: "No project build folders", bundle: .strings),
                    systemImage: "folder.badge.gearshape"
                )
            } description: {
                if model.staleOnly {
                    Text("Projects with no commit, no `git status` and no new file in two months show here.", bundle: .strings)
                } else {
                    Text(
                        """
                        Projects in ~/Developer, ~/Projects, ~/Code and the other usual folders, and every project Xcode has built, \
                        show here with the folders their tools rebuild: node_modules, .build, target, a Python environment.
                        """,
                        bundle: .strings
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(shown) { space in
                    Section {
                        ForEach(space.artifacts) { artifact in
                            ArtifactRow(artifact: artifact, space: space, model: model)
                        }
                    } header: {
                        ProjectSpaceHeader(space: space)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .clipShape(Tokens.Shapes.card)
        }
    }
}

private struct ProjectSpaceHeader: View {
    let space: ProjectSpace

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Text(space.name)
                .font(Tokens.Typography.rowTitle)
                .foregroundStyle(.primary)
            Text(Formatters.displayPath(space.root, home: NSHomeDirectory()))
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let touched = space.lastTouched {
                Text(
                    "Last worked on \(touched.formatted(.relative(presentation: .named)))",
                    bundle: .strings,
                    comment: "Space per project: e.g. Last worked on 3 months ago"
                )
                .font(Tokens.Typography.secondary)
                .foregroundStyle(space.isStale(now: Date()) ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.tertiary))
            }
            Spacer()
            Text(Formatters.bytes(space.totalBytes))
                .font(Tokens.Typography.rowTitle)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ArtifactRow: View {
    let artifact: ProjectArtifact
    let space: ProjectSpace
    let model: ProjectSpaceModel

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: ProjectSpaceText.symbol(artifact.kind))
                .foregroundStyle(.secondary)
                .frame(width: Tokens.IconSize.row)
            VStack(alignment: .leading, spacing: Tokens.Spacing.lineGap) {
                Text(ProjectSpaceRules.title(artifact.kind))
                Text(ProjectSpaceText.place(artifact, in: space))
                    .font(Tokens.Typography.codeSecondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(Formatters.bytes(artifact.size))
                .monospacedDigit()
            // A quiet icon: a bordered button on every row was loud with a hundred rows.
            Button {
                model.askToTrash(artifact, in: space)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(Text("Move to Trash…", bundle: .strings))
            .accessibilityLabel(Text("Move to Trash…", bundle: .strings))
        }
        .help(ProjectSpaceRules.note(artifact.kind))
        .contextMenu {
            Button(String(localized: "Show in Finder", bundle: .strings)) { model.reveal(artifact.path) }
            Button(String(localized: "Move to Trash…", bundle: .strings)) { model.askToTrash(artifact, in: space) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Space per project's words and symbols.
enum ProjectSpaceText {
    /// "12.4 GB of build folders in 6 projects".
    static func summary(_ spaces: [ProjectSpace]) -> String {
        let total = Formatters.bytes(spaces.reduce(0) { $0 &+ $1.totalBytes })
        switch spaces.count {
        case 0:
            return String(localized: "Space per project", bundle: .strings, comment: "Projects tab: the Space view's title")
        case 1:
            return String(
                localized: "\(total) of build folders in \(spaces[0].name)",
                bundle: .strings,
                comment: "Space per project: total size, one project's name"
            )
        default:
            return String(
                localized: "\(total) of build folders in \(spaces.count) projects",
                bundle: .strings,
                comment: "Space per project: total size, how many projects"
            )
        }
    }

    /// "4.6 GB in projects untouched for two months", or nil when none are.
    static func staleSummary(_ spaces: [ProjectSpace], now: Date) -> String? {
        let stale = spaces.filter { $0.isStale(now: now) }.reduce(0) { $0 &+ $1.totalBytes }
        guard stale > 0 else {
            return nil
        }
        return String(
            localized: "\(Formatters.bytes(stale)) in projects untouched for two months",
            bundle: .strings,
            comment: "Space per project: size of the stale projects' build folders"
        )
    }

    /// Where it is: "packages/web/node_modules" in the project, or "~/Library/…" outside it.
    static func place(_ artifact: ProjectArtifact, in space: ProjectSpace) -> String {
        artifact.path.hasPrefix(space.root + "/")
            ? artifact.relativePath(in: space.root)
            : Formatters.displayPath(artifact.path, home: NSHomeDirectory())
    }

    static func symbol(_ kind: ProjectArtifact.Kind) -> String {
        switch kind {
        case .nodeModules, .pods: "shippingbox"
        case .frameworkCache, .zigCache: "bolt.horizontal"
        case .swiftBuild: "swift"
        case .rustTarget, .mavenTarget, .gradleBuild, .cmakeBuild, .derivedData: "hammer"
        case .gradleCache, .pythonCaches, .elixirBuild: "archivebox"
        case .pythonEnvironment: "cube"
        case .dartTool: "wrench.and.screwdriver"
        case .terraform: "server.rack"
        }
    }
}
