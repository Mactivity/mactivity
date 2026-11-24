import Charts
import Core
import Observation
import SwiftUI

/// Wi-Fi over time and network changes' state (D-233, D-234): read when the Network tab shows,
/// then every 5 minutes while it does.
@MainActor
@Observable
final class NetworkHistoryModel {
    struct Stretch: Identifiable {
        let session: NetworkSession
        /// Bytes down and up while on it.
        let bytes: Double
        let apps: [AppTotal]

        var id: Date {
            session.start
        }
    }

    enum Span: String, CaseIterable, Identifiable {
        case day, week

        var id: String {
            rawValue
        }

        var seconds: TimeInterval {
            self == .day ? 86400 : 7 * 86400
        }
    }

    private(set) var wifi: [WiFiReading] = []
    private(set) var stretches: [Stretch] = []
    private(set) var loaded = false
    var span = Span.day

    func load(_ history: any HistoryStore, now: Date = Date()) async {
        guard let network = history as? any NetworkHistoryStore else {
            loaded = true
            return
        }
        wifi = await (try? network.wifiReadings(from: now.addingTimeInterval(-span.seconds), to: now)) ?? []
        let changes = await (try? network.networkChanges(from: now.addingTimeInterval(-7 * 86400), to: now)) ?? []
        let all = NetworkSession.sessions(changes, from: now.addingTimeInterval(-7 * 86400), now: now)
        let sessions = Array(NetworkSession.listed(all, now: now).prefix(8))
        var read: [Stretch] = []
        let daily = history as? any DailyHistoryStore
        for session in sessions {
            let end = session.end ?? now
            let bytes = session.kind == .offline ? 0
                : await (try? daily?.systemTotal(metrics: [.netIn, .netOut], from: session.start, to: end)) ?? 0
            let apps = session.kind == .offline ? []
                : await (try? daily?.totals(metrics: [.netIn, .netOut], from: session.start, to: end, limit: 3)) ?? []
            read.append(Stretch(session: session, bytes: bytes, apps: apps.filter { $0.value > 0 }))
        }
        stretches = read
        loaded = true
    }
}

/// On the Network tab: the Wi-Fi signal over the day or week, and each network the Mac was on,
/// with the data used and the apps that used it most.
struct NetworkHistoryCard: View {
    let model: NetworkHistoryModel
    let services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                Text("Wi-Fi and networks", bundle: .strings, comment: "Network tab card: Wi-Fi signal history and network changes")
                    .font(Tokens.Typography.cardTitle)
                if let summary = WiFiText.summary(model.wifi) {
                    Text(summary)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(
                    String(localized: "Span", bundle: .strings, comment: "Wi-Fi chart: the last day or week"),
                    selection: Binding(get: { model.span }, set: { model.span = $0 })
                ) {
                    Text("Day", bundle: .strings, comment: "Wi-Fi chart span: 24 hours").tag(NetworkHistoryModel.Span.day)
                    Text("Week", bundle: .strings, comment: "Wi-Fi chart span: 7 days").tag(NetworkHistoryModel.Span.week)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if !model.loaded {
                ProgressView().controlSize(.small)
            } else {
                if model.wifi.count >= 2 {
                    chart
                } else {
                    Text("Wi-Fi's signal is recorded each minute the Mac is on Wi-Fi. Check back in a while.", bundle: .strings)
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.tertiary)
                }
                if !model.stretches.isEmpty {
                    stretches
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: model.span) {
            while !Task.isCancelled {
                await model.load(services.history)
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Signal in dBm, with the line for a weak one.
    private var chart: some View {
        Chart {
            // A new line after a gap (asleep, on Ethernet), so a night isn't drawn as a signal.
            ForEach(WiFiText.runs(model.wifi), id: \.offset) { run in
                ForEach(run.element, id: \.at) { reading in
                    LineMark(
                        x: .value(String(localized: "Time", bundle: .strings), reading.at),
                        y: .value(String(localized: "Signal", bundle: .strings, comment: "Wi-Fi signal strength, dBm"), reading.rssi),
                        series: .value(WiFiText.runLabel, run.offset)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Tokens.SidebarTint.network)
                }
            }
            RuleMark(y: .value(String(localized: "Weak", bundle: .strings, comment: "Wi-Fi: a weak signal"), WiFiText.weak))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(Tokens.Colors.strain.opacity(0.7))
        }
        .chartXAxis {
            AxisMarks {
                AxisGridLine()
                AxisTick()
                AxisValueLabel().font(Tokens.Typography.chartLabel)
            }
        }
        .chartYScale(domain: -95 ... -30)
        .chartYAxis {
            AxisMarks(values: [-90, -70, -50]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let dBm = value.as(Int.self) {
                        Text(verbatim: "\(dBm) dBm").font(Tokens.Typography.caption)
                    }
                }
            }
        }
        .frame(height: 120)
        .accessibilityLabel(Text("Wi-Fi signal over time", bundle: .strings))
    }

    private var stretches: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("Networks this week", bundle: .strings, comment: "Network tab: the list of networks the Mac was on")
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
            ForEach(model.stretches) { stretch in
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                    Image(systemName: WiFiText.symbol(stretch.session.kind))
                        .foregroundStyle(stretch.session.kind == .offline ? AnyShapeStyle(Tokens.Colors.strain) : AnyShapeStyle(.secondary))
                        .frame(width: Tokens.IconSize.row)
                    Text(stretch.session.kind.title)
                        .frame(minWidth: 110, alignment: .leading)
                    Text(WiFiText.when(stretch.session))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    if stretch.bytes > 0 {
                        Text(stretch.apps.map(\.app.name).formatted(.list(type: .and)))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Text(Formatters.bytes(stretch.bytes))
                            .monospacedDigit()
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                }
                .font(Tokens.Typography.secondary)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Wi-Fi over time's words.
enum WiFiText {
    /// Below this, a connection struggles.
    static let weak = -75

    /// The chart's series name: not shown, not localized.
    static let runLabel: String = "run"

    /// Readings split where more than two minutes pass between them.
    static func runs(_ readings: [WiFiReading]) -> [(offset: Int, element: [WiFiReading])] {
        var runs: [[WiFiReading]] = []
        for reading in readings {
            if let last = runs.last?.last, reading.at.timeIntervalSince(last.at) <= 120 {
                runs[runs.count - 1].append(reading)
            } else {
                runs.append([reading])
            }
        }
        return Array(runs.enumerated()).map { ($0.offset, $0.element) }
    }

    /// "Signal −58 dBm on average, weak for 12 minutes".
    static func summary(_ readings: [WiFiReading]) -> String? {
        guard !readings.isEmpty else {
            return nil
        }
        let average = readings.reduce(0) { $0 + $1.rssi } / readings.count
        let weakMinutes = readings.filter { $0.rssi < weak }.count
        let base = String(
            localized: "Signal \(average) dBm on average",
            bundle: .strings,
            comment: "Wi-Fi summary: the average signal, e.g. Signal -58 dBm on average"
        )
        guard weakMinutes > 0 else {
            return base
        }
        let time = Formatters.duration(.seconds(weakMinutes * 60))
        return base + String(
            localized: ", weak for \(time)",
            bundle: .strings,
            comment: "Wi-Fi summary, after the average: how long it was weak"
        )
    }

    /// "Today 9:12 – 11:40 (2h 28m)", "Since 9:12".
    static func when(_ session: NetworkSession) -> String {
        let start = session.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        guard let end = session.end else {
            return String(localized: "Since \(start)", bundle: .strings, comment: "Network stretch still going, e.g. Since Thu 9:12 AM")
        }
        let length = Formatters.duration(.seconds(max(0, end.timeIntervalSince(session.start))))
        return "\(start) · \(length)"
    }

    static func symbol(_ kind: NetworkKind) -> String {
        switch kind {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .hotspot: "personalhotspot"
        case .vpn: "lock.shield"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .other: "network"
        case .offline: "wifi.slash"
        case .asleep: "moon.zzz"
        }
    }
}
