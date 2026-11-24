import Core
import SwiftUI

/// History's App launch times (D-215): the apps slowest to open lately, each against how long it
/// took before, from launches Mactivity saw.
struct LaunchTimesCard: View {
    let services: AppServices
    let generation: Int
    /// Render tests: these instead of reading.
    var sample: [AppLaunchTimes]?

    @State private var apps: [AppLaunchTimes] = []

    var body: some View {
        let shown = (sample ?? apps).filter { $0.recent != nil }.prefix(8)
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("From an app starting to it being ready, the median of the last two weeks.", bundle: .strings)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            if shown.isEmpty {
                Text("Launch times appear once apps have opened a few times while Mactivity runs.", bundle: .strings)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Tokens.Spacing.xs)
            }
            Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.l, verticalSpacing: Tokens.Spacing.xs) {
                ForEach(Array(shown)) { app in
                    GridRow {
                        Text(app.name).lineLimit(1)
                        Text(app.recent.map(Formatters.seconds) ?? "–").monospacedDigit()
                        Text(Self.trend(app))
                            .font(Tokens.Typography.secondary)
                            .monospacedDigit()
                            .foregroundStyle(app.isSlower ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: generation) {
            guard sample == nil, let store = services.history as? any AppLaunchStore else {
                return
            }
            let now = Date()
            let launches = await (try? store.launches(from: now.addingTimeInterval(-35 * 86400), to: now)) ?? []
            apps = AppLaunchTimes.byApp(launches, now: now)
        }
    }

    /// "Slower: was 0.9s", "was 1.2s", or nothing to compare yet.
    nonisolated static func trend(_ app: AppLaunchTimes) -> String {
        guard let earlier = app.earlier else {
            return ""
        }
        let was = Formatters.seconds(earlier)
        return app.isSlower
            ? String(localized: "Slower: was \(was)", bundle: .strings, comment: "App launch times: before, when it got slower")
            : String(localized: "was \(was)", bundle: .strings, comment: "App launch times: the median before")
    }
}
