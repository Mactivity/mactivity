import Core
import Observation
import SwiftUI

/// Crowded Wi-Fi channels' state (D-286). A scan takes Wi-Fi off its channel for a few seconds, so
/// it runs only when the person asks, at most once a minute, and the result stays until the next.
@MainActor
@Observable
public final class WiFiChannelsModel {
    public private(set) var reading: WiFiScanReading?
    public private(set) var scanning = false
    /// The last time a scan started: the minute counts from here.
    public private(set) var lastScan: Date?
    @ObservationIgnored private var source: any WiFiScanSource

    nonisolated static let minimumGap: TimeInterval = 60

    public init(source: any WiFiScanSource) {
        self.source = source
    }

    public func replaceSource(_ source: any WiFiScanSource) {
        self.source = source
        reading = nil
        lastScan = nil
    }

    func mayScan(now: Date = Date()) -> Bool {
        !scanning && Self.gapOver(lastScan, now: now)
    }

    /// Pure: whether the minute since the last scan has passed.
    nonisolated static func gapOver(_ last: Date?, now: Date) -> Bool {
        guard let last else {
            return true
        }
        return now.timeIntervalSince(last) >= minimumGap || now < last
    }

    func scan(now: Date = Date()) async {
        guard mayScan(now: now) else {
            return
        }
        scanning = true
        lastScan = now
        let source = source
        reading = await source.scan()
        scanning = false
    }
}

/// On the Network tab, under Wi-Fi over time (D-286): whether nearby networks share this Mac's
/// channel, from what it hears. Advice only.
struct WiFiChannelsCard: View {
    let model: WiFiChannelsModel

    /// Turns the button back on when the minute is up.
    @State private var gapOver = true

    static let rowsShown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                Text(
                    "Crowded channels", bundle: .strings,
                    comment: "Network tab card: whether nearby Wi-Fi networks share this Mac's channel"
                )
                .font(Tokens.Typography.cardTitle)
                if case let .scanned(scan)? = model.reading {
                    Text(scanned(at: scan.at))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.scanning {
                    ProgressView().controlSize(.small)
                }
                Button(buttonTitle) { Task { await model.scan() } }
                    .disabled(model.scanning || !gapOver)
                    .help(String(localized: "A scan pauses Wi-Fi for a few seconds. You can scan once a minute.", bundle: .strings))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .task(id: model.lastScan) {
            guard let last = model.lastScan else {
                gapOver = true
                return
            }
            gapOver = false
            let left = WiFiChannelsModel.minimumGap - Date().timeIntervalSince(last)
            try? await Task.sleep(for: .seconds(max(0, left)))
            if !Task.isCancelled {
                gapOver = true
            }
        }
    }

    private var buttonTitle: String {
        model.reading == nil
            ? String(localized: "Scan", bundle: .strings, comment: "Crowded channels: button that listens for nearby Wi-Fi networks")
            : String(
                localized: "Scan Again", bundle: .strings,
                comment: "Crowded channels: button that listens for nearby Wi-Fi networks again"
            )
    }

    private func scanned(at date: Date) -> String {
        String(
            localized: "Scanned at \(date.formatted(date: .omitted, time: .shortened))", bundle: .strings,
            comment: "Crowded channels: when the last scan ran"
        )
    }

    @ViewBuilder private var content: some View {
        switch model.reading {
        case nil:
            secondary(String(
                localized: """
                Whether nearby networks share your channel, from what your Mac hears. A scan pauses Wi-Fi for a few seconds, \
                so it only runs when you ask.
                """,
                bundle: .strings
            ))
        case .notJoined?:
            secondary(String(localized: "Join a Wi-Fi network to compare channels.", bundle: .strings))
        case .failed?:
            secondary(String(
                localized: "macOS didn't finish the scan, which can happen when Wi-Fi is busy. Try again in a minute.", bundle: .strings
            ))
        case let .scanned(scan)?:
            results(WiFiCrowding.analyze(scan))
        }
    }

    private func results(_ crowding: WiFiCrowding) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
                Image(systemName: crowding.level == .crowded ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(crowding.level == .crowded ? Tokens.Colors.strain : .secondary)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(WiFiChannelsText.verdict(crowding))
                    Text(WiFiChannelsText.own(crowding.own))
                        .font(Tokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if !crowding.channels.isEmpty {
                channels(crowding)
            }
            if let advice = WiFiChannelsText.advice(crowding) {
                Text(advice)
                    .font(Tokens.Typography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            secondary(WiFiChannelsText.note(crowding))
        }
    }

    private func channels(_ crowding: WiFiCrowding) -> some View {
        // The busiest when there are too many to list, always with this Mac's own.
        let shown = WiFiChannelsText.rows(crowding, limit: Self.rowsShown)
        return Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.l, verticalSpacing: Tokens.Spacing.xxs) {
            GridRow {
                Text("Channel", bundle: .strings, comment: "Crowded channels: column heading")
                Text("Networks", bundle: .strings, comment: "Crowded channels: column heading, how many networks were heard")
                Text("Strongest", bundle: .strings, comment: "Crowded channels: column heading, the strongest signal heard")
                Color.clear.frame(width: 1, height: 1)
            }
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            ForEach(shown) { load in
                GridRow {
                    Text(verbatim: String(load.channel))
                    Text(load.networks, format: .number)
                    Text(verbatim: "\(load.strongest) dBm")
                    Text(WiFiChannelsText.relation(load))
                        .foregroundStyle(load.isYours || load.overlapsYours ? .primary : .secondary)
                }
                .monospacedDigit()
                .fontWeight(load.isYours ? .semibold : .regular)
                .accessibilityElement(children: .combine)
            }
        }
        .font(Tokens.Typography.secondary)
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Crowded channels' words (D-286). Pure.
enum WiFiChannelsText {
    static func band(_ band: NetworkDetails.Band) -> String {
        switch band {
        case .ghz2: "2.4 GHz"
        case .ghz5: "5 GHz"
        case .ghz6: "6 GHz"
        }
    }

    static func own(_ own: WiFiChannelInfo) -> String {
        String(
            localized: "Your Wi-Fi is on channel \(String(own.channel)), \(band(own.band)), \(String(own.widthMHz)) MHz wide.",
            bundle: .strings, comment: "Crowded channels: channel number, band, width"
        )
    }

    static func verdict(_ crowding: WiFiCrowding) -> String {
        let count = crowding.competing.count
        switch crowding.level {
        case .clear:
            return String(localized: "No nearby network was heard on your channel.", bundle: .strings)
        case .light:
            return String(
                localized: "\(count) nearby networks share or overlap your channel, not loud enough to matter much.", bundle: .strings,
                comment: "Crowded channels: a few weak networks on the same channel"
            )
        case .crowded:
            return String(
                localized: "Your channel is crowded: \(count) nearby networks share or overlap it.", bundle: .strings,
                comment: "Crowded channels: strong networks on the same channel"
            )
        }
    }

    /// Which rows fit: this Mac's channel and those overlapping it first, then the most crowded,
    /// in channel order.
    static func rows(_ crowding: WiFiCrowding, limit: Int) -> [WiFiCrowding.ChannelLoad] {
        let ranked = crowding.channels.sorted {
            let first = ($0.isYours ? 0 : $0.overlapsYours ? 1 : 2, -$0.networks, $0.channel)
            let second = ($1.isYours ? 0 : $1.overlapsYours ? 1 : 2, -$1.networks, $1.channel)
            return first < second
        }
        return ranked.prefix(limit).sorted { $0.channel < $1.channel }
    }

    static func relation(_ load: WiFiCrowding.ChannelLoad) -> String {
        if load.isYours {
            return String(localized: "Your channel", bundle: .strings, comment: "Crowded channels: this row is the channel this Mac uses")
        }
        return load.overlapsYours
            ? String(
                localized: "Overlaps yours", bundle: .strings,
                comment: "Crowded channels: this channel's frequencies reach this Mac's"
            )
            : ""
    }

    static func advice(_ crowding: WiFiCrowding) -> String? {
        if let channel = crowding.suggestion {
            return String(
                localized: """
                Channel \(String(channel)) sounds quieter from here. The channel is a setting on your router; Mactivity doesn't \
                change anything.
                """,
                bundle: .strings
            )
        }
        return crowding.level == .crowded
            ? String(localized: "No channel in this band sounds clearly quieter from here.", bundle: .strings)
            : nil
    }

    static func note(_ crowding: WiFiCrowding) -> String {
        let base = String(
            localized: """
            One router can show up as more than one network. Without Location permission, which Mactivity doesn't ask for, \
            macOS gives channels and signal strengths but no names.
            """,
            bundle: .strings
        )
        guard crowding.otherBands > 0 else {
            return base
        }
        return String(
            localized: "\(crowding.otherBands) more heard on other bands, which don't compete with yours.", bundle: .strings,
            comment: "Crowded channels: networks heard on other Wi-Fi bands"
        ) + " " + base
    }
}
