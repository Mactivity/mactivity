import Core
import SwiftUI

/// Test run times (D-278): how long each project's test command takes, its last run and how that
/// ended, and whether it's got slower. Beside Build times in History, and in Projects → Dev Tools.
struct TestTimesCard: View {
    let services: AppServices
    /// Render tests: this instead of the services' model.
    var model: BuildsModel?
    /// How many projects to list; the rest are in History.
    var limit = 8

    var body: some View {
        let model = model ?? services.builds
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Test runs", bundle: .strings, comment: "Test run times: the card's title")
                .font(Tokens.Typography.rowTitle)
            Text(
                "swift test, npm test, pytest and cargo test, each run timed by project, building included.",
                bundle: .strings
            )
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .help(Self.limits)
            if model.isLoaded, model.tests.isEmpty {
                Text("No test runs yet. They appear here once a project's tests run while Mactivity runs.", bundle: .strings)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Tokens.Spacing.xs)
            }
            Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.l, verticalSpacing: Tokens.Spacing.s) {
                ForEach(model.tests.prefix(limit)) { project in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(project.project.isEmpty ? String(localized: "Other test runs", bundle: .strings) : project.project)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(
                                "\(project.tool) · Finished runs: \(project.count)",
                                bundle: .strings,
                                comment: "Test run times: the command, and how many whole runs finished in 4 weeks"
                            )
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(BuildTimesCard.duration(project.last.duration)).monospacedDigit()
                            Text(Self.lastRun(project.last))
                                .font(Tokens.Typography.secondary)
                                .foregroundStyle(
                                    Self.endedEarly(project.last) ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary)
                                )
                        }
                        Text(BuildTimesCard.trend(project))
                            .font(Tokens.Typography.secondary)
                            .monospacedDigit()
                            .foregroundStyle(project.isSlower ? AnyShapeStyle(Tokens.Colors.strainLabel) : project
                                .isFaster ? AnyShapeStyle(Tokens.Colors.goodLabel) : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: services.historyGeneration) {
            if self.model == nil {
                await services.builds.refresh(services)
            }
        }
    }

    private static let limits = Text(
        """
        Timed from the test command's own process, start to exit. Mactivity looks every 10 seconds with its window closed, so a \
        shorter run can go unseen. Failed and cancelled runs, and runs of only some tests, don't count towards how long tests usually take.
        """,
        bundle: .strings
    )

    private static func endedEarly(_ run: BuildRun) -> Bool {
        run.outcome == .failed || run.outcome == .cancelled
    }

    /// "last, 2 hours ago", "failed, 2 hours ago", "cancelled, 2 hours ago", "only some tests, 2 hours ago".
    nonisolated static func lastRun(_ run: BuildRun) -> String {
        let when = run.end.formatted(.relative(presentation: .named))
        switch run.outcome {
        case .failed:
            return String(
                localized: "failed, \(when)",
                bundle: .strings,
                comment: "Test run times: the last run failed, e.g. failed, 2 hours ago"
            )
        case .cancelled:
            return String(
                localized: "cancelled, \(when)",
                bundle: .strings,
                comment: "Test run times: the last run was stopped, e.g. cancelled, 2 hours ago"
            )
        default:
            if run.isPartial {
                return String(
                    localized: "only some tests, \(when)",
                    bundle: .strings,
                    comment: "Test run times: every run so far was told to run a few tests, e.g. only some tests, 2 hours ago"
                )
            }
            return String(
                localized: "last, \(when)",
                bundle: .strings,
                comment: "Build times: when the last build finished, e.g. last, 2 hours ago"
            )
        }
    }
}
