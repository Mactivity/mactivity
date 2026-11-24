import AppKit
import Core
import SwiftUI

/// History's Flagged by macOS (D-212): what macOS itself caught in the last 30 days, newest first.
/// Heavy disk writers, processor hogs and wake-up storms past macOS's own limits, apps closed
/// because memory ran out, and restarts the Mac didn't choose. Routine reports are left out.
struct FlaggedCard: View {
    let services: AppServices
    let generation: Int
    /// Render tests: these instead of reading.
    var sample: [MacReport]?

    @State private var reports: [MacReport] = []
    @State private var before: [String: [String]] = [:]
    /// Owning apps' names, looked up once per load rather than on every redraw.
    @State private var owners: [String: String] = [:]

    var body: some View {
        let shown = sample ?? reports
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("What macOS caught past its own limits in the last 30 days. Routine reports are left out.", bundle: .strings)
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            if shown.isEmpty {
                Text("Nothing flagged. macOS hasn't caught anything out of line.", bundle: .strings)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Tokens.Spacing.xs)
            }
            ForEach(shown.prefix(12)) { report in
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                    Image(systemName: Self.symbol(report.kind))
                        .foregroundStyle(report.isRestart || report.kind == .memoryKill ? Tokens.Colors.strain : .secondary)
                        .frame(width: Tokens.IconSize.small)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(MacReportText.describe(report, owner: report.ownerBundleID.flatMap { owners[$0] }))
                            .lineLimit(2)
                            // A panic's own explanation, for the curious.
                            .help(Self.detail(report.kind))
                        if let apps = before[report.id], !apps.isEmpty {
                            Text("Busiest just before: \(apps.formatted(.list(type: .and)))", bundle: .strings)
                                .font(Tokens.Typography.secondary)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: Tokens.Spacing.s)
                    Text(report.at.formatted(.relative(presentation: .named)))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Button(String(
                        localized: "Show in Console",
                        bundle: .strings,
                        comment: "Crashes: opens the latest crash report in Console"
                    )) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: report.path))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: generation) {
            guard sample == nil else {
                return
            }
            let now = Date()
            let found = await MacReport.collapsed(services.recentMacReports(days: 30, now: now)).filter(\.isNotable)
            var names: [String: String] = [:]
            for id in Set(found.compactMap(\.ownerBundleID)) {
                names[id] = Self.ownerName(id)
            }
            owners = names
            reports = found
            // What was running before each restart, from history. The panic report is written after
            // the reboot, so the restart was at the last minute history recorded before it.
            guard let daily = services.history as? any DailyHistoryStore else {
                return
            }
            for report in found where report.isRestart {
                let recorded = await (try? daily.series(
                    metric: .cpu,
                    app: nil,
                    from: report.at.addingTimeInterval(-6 * 3600),
                    to: report.at
                )) ?? []
                let down = recorded.last?.at ?? report.at
                let apps = await (try? daily.topApps(
                    metric: .cpu,
                    from: down.addingTimeInterval(-600),
                    to: down.addingTimeInterval(60),
                    limit: 3
                )) ?? []
                before[report.id] = apps.map(\.app.name)
            }
        }
    }

    static func detail(_ kind: MacReport.Kind) -> String {
        if case let .panic(summary) = kind {
            return summary
        }
        return ""
    }

    static func symbol(_ kind: MacReport.Kind) -> String {
        switch kind {
        case .diskWrites: "internaldrive"
        case .cpu: "cpu"
        case .wakeups: "alarm"
        case .memoryKill: "memorychip"
        case .panic: "exclamationmark.octagon"
        case .shutdownStall: "power"
        }
    }

    /// "Claude" for "com.anthropic.claudefordesktop": the installed app's name, else nothing.
    static func ownerName(_ bundleID: String?) -> String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
