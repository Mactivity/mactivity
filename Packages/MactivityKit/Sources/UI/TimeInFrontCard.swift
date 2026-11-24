import AppKit
import Core
import SwiftUI

/// History → Time in front (D-098): how long each app was the one in use over the range.
struct TimeInFrontCard: View {
    let store: any FocusStore
    let range: HistoryRange
    let generation: Int

    @State private var apps: [AppTotal] = []
    @State private var active: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(summary)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            let longest = apps.first?.value ?? 0
            ForEach(apps, id: \.app.id) { app in
                HStack(spacing: Tokens.Spacing.xs) {
                    AppIconView(app.app, size: Tokens.IconSize.small)
                    Text(app.app.name)
                        .lineLimit(1)
                        .frame(width: 180, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(2, proxy.size.width * (longest > 0 ? app.value / longest : 0)))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 6)
                    Text(Self.duration(app.value))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
        .cardStyle()
        .task(id: "\(range.rawValue)-\(generation)") {
            while !Task.isCancelled {
                let end = Date()
                let start = end.addingTimeInterval(-TimeInterval(range.duration.components.seconds))
                let found = await (try? store.focusTotals(from: start, to: end, limit: 8)) ?? []
                let total = await (try? store.activeSeconds(from: start, to: end)) ?? 0
                guard !Task.isCancelled else {
                    return
                }
                apps = found
                active = total
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var summary: String {
        guard active > 0 else {
            return String(localized: "Mactivity notes which app is in front while you use your Mac. Nothing yet.", bundle: .strings)
        }
        return String(
            localized: "In use for \(Self.duration(active)) · \(range.label)", bundle: .strings,
            comment: "Time in front: how long the Mac was in use over the history range"
        )
    }

    nonisolated static func duration(_ seconds: Double) -> String {
        Duration.seconds(max(60, seconds)).formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2))
    }
}

/// History → Crashes and hangs (D-098): per app over the range, and the latest reports.
struct CrashesCard: View {
    let source: any CrashReportSource
    let range: HistoryRange
    let generation: Int

    @State private var reports: [CrashReport] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            if reports.isEmpty {
                Text("No crashes or hangs in this range.", bundle: .strings)
                    .foregroundStyle(.secondary)
            }
            ForEach(Self.byApp(reports), id: \.name) { app in
                HStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tokens.Colors.strain)
                    Text(app.name)
                        .frame(width: 180, alignment: .leading)
                    Text(Self.counts(crashes: app.crashes, hangs: app.hangs))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(app.latest.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                    // Says where it goes; "Open Report" also opens Your next Mac (D-196).
                    Button(String(
                        localized: "Show in Console",
                        bundle: .strings,
                        comment: "Crashes: opens the latest crash report in Console"
                    )) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Opens the latest report in Console", bundle: .strings))
                }
            }
        }
        .cardStyle()
        .task(id: "\(range.rawValue)-\(generation)") {
            let start = Date().addingTimeInterval(-TimeInterval(range.duration.components.seconds))
            reports = await source.reports(since: start)
        }
    }

    struct AppCrashes {
        let name: String
        let crashes: Int
        let hangs: Int
        let latest: Date
        let path: String
    }

    /// Most first; `reports` is newest first, so the first seen is the latest.
    nonisolated static func byApp(_ reports: [CrashReport]) -> [AppCrashes] {
        var order: [String] = []
        var grouped: [String: [CrashReport]] = [:]
        for report in reports {
            if grouped[report.appName] == nil {
                order.append(report.appName)
            }
            grouped[report.appName, default: []].append(report)
        }
        return order.compactMap { name in
            guard let list = grouped[name], let latest = list.first else {
                return nil
            }
            return AppCrashes(
                name: name, crashes: list.count { $0.kind == .crash }, hangs: list.count { $0.kind == .hang },
                latest: latest.at, path: latest.path
            )
        }
        .sorted { ($0.crashes + $0.hangs, $0.latest) > ($1.crashes + $1.hangs, $1.latest) }
    }

    nonisolated static func counts(crashes: Int, hangs: Int) -> String {
        var parts: [String] = []
        if crashes > 0 {
            parts.append(String(localized: "Crashes: \(crashes)", bundle: .strings))
        }
        if hangs > 0 {
            parts.append(String(localized: "Hangs: \(hangs)", bundle: .strings))
        }
        return parts.joined(separator: " · ")
    }
}
