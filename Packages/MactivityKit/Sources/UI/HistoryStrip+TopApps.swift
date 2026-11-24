import Charts
import Core
import SwiftUI

/// The strip's Top apps: the range's, or, with a bar clicked, the apps behind that moment
/// (Rewind, D-190).
extension HistoryStrip {
    var topAppsList: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            if let pinned = pinnedBin {
                momentHeader(pinned)
            } else {
                rangeHeader
            }
            let apps = pinned == nil ? topApps : momentApps ?? []
            if pinned == nil, comparesPrevious, changes.isEmpty, !topApps.isEmpty {
                Text("Not enough history to compare yet", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.tertiary)
            }
            if apps.isEmpty {
                Text(pinned != nil && momentApps == nil
                    ? String(localized: "Loading…", bundle: .strings)
                    : String(localized: "None yet", bundle: .strings, comment: "No top apps yet"))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.tertiary)
            }
            ForEach(apps) { total in
                row(total, compares: pinned == nil && comparesPrevious)
            }
            Spacer(minLength: 0)
        }
    }

    private var rangeHeader: some View {
        HStack {
            Text("Top apps · \(range.label)", bundle: .strings, comment: "History strip: top apps for a range")
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            Spacer(minLength: Tokens.Spacing.xs)
            Toggle(isOn: $comparesPrevious) {
                Text("vs previous", bundle: .strings, comment: "Toggle: compare with the previous period")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(Text("Compare with the \(range.label) before this", bundle: .strings, comment: "The range, e.g. 24 hours"))
        }
    }

    /// "Top apps · Tue 2:00 – 2:15 PM", and the way back to the whole range.
    private func momentHeader(_ bin: HistoryBin) -> some View {
        HStack {
            Text(
                "Top apps · \(Self.momentLabel(bin))",
                bundle: .strings,
                comment: "History strip: top apps for one clicked bar, e.g. Top apps · Tue 2:00 – 2:15 PM"
            )
            .font(Tokens.Typography.secondary.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            Spacer(minLength: Tokens.Spacing.xs)
            Button {
                pinned = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(Text("Back to the whole \(range.label)", bundle: .strings, comment: "Tooltip: leave the clicked moment, e.g. 24 h"))
            .accessibilityLabel(Text(
                "Back to the whole \(range.label)",
                bundle: .strings,
                comment: "Tooltip: leave the clicked moment, e.g. 24 h"
            ))
        }
    }

    private func row(_ total: AppTotal, compares: Bool) -> some View {
        HStack(spacing: Tokens.Spacing.xs) {
            AppIconView(total.app, size: Tokens.IconSize.small)
            Text(total.app.name)
                .lineLimit(1)
            Spacer(minLength: Tokens.Spacing.xs)
            Text(spec.topAppsMetric == .energyImpact
                ? Formatters.percent(total.value)
                : Formatters.metric(total.value, spec.topAppsMetric ?? spec.metrics[0]))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            // The column is there on every row, with or without a change, so the values
            // beside it line up.
            if compares {
                let change = changes[total.app.id]
                Text(verbatim: change?.label ?? "")
                    .monospacedDigit()
                    .foregroundStyle(change?.isIncrease == true ? AnyShapeStyle(Tokens.Colors.strainLabel) : AnyShapeStyle(.secondary))
                    .frame(minWidth: Tokens.Layout.changeColumnWidth, alignment: .trailing)
            }
        }
        .font(Tokens.Typography.secondary)
        .contentShape(.rect)
        // A click opens the app's own history page (D-168).
        .onTapGesture { services.appHistory.open(total.app) }
        .help(Text("Show \(total.app.name)’s history", bundle: .strings, comment: "Tooltip on a top app: opens its history page"))
        .accessibilityAddTraits(.isButton)
    }

    /// Pins the bar under the pointer; clicking the pinned bar again lets go.
    func pin(_ bin: HistoryBin?) {
        guard spec.topAppsMetric != nil, let bin else {
            return
        }
        pinned = pinned?.start == bin.start ? nil : bin
    }

    /// The apps behind the pinned bar, from the store's finest rows for that span.
    func loadMoment() async {
        momentApps = nil
        guard let pinned, let metric = spec.topAppsMetric, let daily = services.history as? any DailyHistoryStore else {
            return
        }
        // Energy Impact as each app's share of the moment's total, as the range list shows it.
        let shares = metric == .energyImpact
        let apps = await (try? daily.topApps(metric: metric, from: pinned.start, to: pinned.end, limit: shares ? 200 : 5)) ?? []
        guard !Task.isCancelled else {
            return
        }
        momentApps = shares ? Array(Self.shares(apps).prefix(5)) : apps
    }

    /// The time under a point in the chart's overlay, or nil off the plot.
    static func date(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
        guard let plot = proxy.plotFrame else {
            return nil
        }
        let frame = geometry[plot]
        guard frame.contains(point) else {
            return nil
        }
        return proxy.value(atX: point.x - frame.minX, as: Date.self)
    }

    /// "Tue 2:00 – 2:15 PM" within a week, "Sep 20" for a day's bar, "Sep 20 – 26" for longer.
    nonisolated static func momentLabel(_ bin: HistoryBin) -> String {
        let length = bin.end.timeIntervalSince(bin.start)
        if length >= 86400 {
            let lastDay = bin.end - 1
            return Calendar.current.isDate(bin.start, inSameDayAs: lastDay)
                ? bin.start.formatted(.dateTime.month(.abbreviated).day())
                : (bin.start ..< lastDay).formatted(.interval.month(.abbreviated).day())
        }
        return (bin.start ..< bin.end).formatted(.interval.weekday(.abbreviated).hour().minute())
    }
}
