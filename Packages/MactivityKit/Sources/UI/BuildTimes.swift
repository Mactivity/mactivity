import Core
import Observation
import SwiftUI

/// Build times (D-209): each project's builds over four weeks, the last one, and whether they've
/// got slower, from the compilers Mactivity saw.
@MainActor
@Observable
public final class BuildsModel {
    public private(set) var projects: [ProjectBuilds] = []
    /// Test run times (D-278): the same figures for test commands.
    public private(set) var tests: [ProjectBuilds] = []
    public private(set) var isLoaded = false

    public init() {}

    /// Already worked out: render tests.
    init(projects: [ProjectBuilds], tests: [ProjectBuilds] = []) {
        self.projects = projects
        self.tests = tests
        isLoaded = true
    }

    /// Projects whose builds got slower this week, for Checkup.
    public var slower: [ProjectBuilds] {
        projects.filter(\.isSlower)
    }

    func refresh(_ services: AppServices, now: Date = Date()) async {
        guard let store = services.history as? any BuildHistoryStore else {
            isLoaded = true
            return
        }
        let runs = await (try? store.buildRuns(from: now.addingTimeInterval(-28 * 86400), to: now)) ?? []
        projects = BuildStats.byProject(runs, now: now)
        let testRuns = await (try? store.testRuns(from: now.addingTimeInterval(-28 * 86400), to: now)) ?? []
        tests = TestStats.byProject(testRuns, now: now)
        isLoaded = true
    }
}

struct BuildTimesCard: View {
    let services: AppServices
    /// Render tests: this instead of the services' model.
    var model: BuildsModel?

    var body: some View {
        let model = model ?? services.builds
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Timed from the compilers Mactivity sees, by project: Xcode and Swift, Rust, Go, C and C++.", bundle: .strings)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            if model.isLoaded, model.projects.isEmpty {
                Text("No builds yet. They appear here once a project compiles while Mactivity runs.", bundle: .strings)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Tokens.Spacing.s)
            }
            Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.l, verticalSpacing: Tokens.Spacing.s) {
                ForEach(model.projects.prefix(8)) { project in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(project.project.isEmpty ? String(localized: "Other builds", bundle: .strings) : project.project)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(
                                "\(project.tool) · Builds: \(project.count)",
                                bundle: .strings,
                                comment: "Build times: the tool, and how many builds in 4 weeks"
                            )
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Self.duration(project.last.duration)).monospacedDigit()
                            Text(
                                "last, \(project.last.end.formatted(.relative(presentation: .named)))",
                                bundle: .strings,
                                comment: "Build times: when the last build finished, e.g. last, 2 hours ago"
                            )
                            .font(Tokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                        }
                        Text(Self.trend(project))
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

    /// The tool family's name; the two with an "and" in it translated.
    nonisolated static func toolName(_ family: String) -> String {
        switch family {
        case "C and C++": String(localized: "C and C++", bundle: .strings, comment: "Build times: the tool family")
        case "Java and Kotlin": String(localized: "Java and Kotlin", bundle: .strings, comment: "Build times: the tool family")
        default: family
        }
    }

    /// "1m 35s", "48s".
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }

    /// "Slower: 1m 35s this week, was 58s", "Usually 1m 2s", or nothing yet to compare.
    nonisolated static func trend(_ project: ProjectBuilds) -> String {
        guard let recent = project.recentMedian else {
            return ""
        }
        let now = duration(recent)
        guard let earlier = project.earlierMedian else {
            return String(localized: "Usually \(now)", bundle: .strings, comment: "Build times: the median build this week")
        }
        let was = duration(earlier)
        if project.isSlower {
            return String(
                localized: "Slower: \(now) this week, was \(was)",
                bundle: .strings,
                comment: "Build times: median this week and before"
            )
        }
        if project.isFaster {
            return String(
                localized: "Faster: \(now) this week, was \(was)",
                bundle: .strings,
                comment: "Build times: median this week and before"
            )
        }
        return String(localized: "Usually \(now)", bundle: .strings, comment: "Build times: the median build this week")
    }
}
