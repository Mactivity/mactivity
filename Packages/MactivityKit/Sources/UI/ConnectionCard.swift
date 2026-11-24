import Core
import Foundation
import Observation
import SwiftUI

/// The connection now, under the Network tab's history (D-149): read every 5 s while it shows.
@MainActor
@Observable
public final class NetworkDetailsModel {
    public private(set) var details: NetworkDetails?
    @ObservationIgnored private var source: any NetworkDetailsSource
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var visibleViews = 0
    @ObservationIgnored private var sourceGeneration = 0

    public init(source: any NetworkDetailsSource) {
        self.source = source
    }

    public func replaceSource(_ source: any NetworkDetailsSource) {
        sourceGeneration += 1
        self.source = source
        details = nil
        if visibleViews > 0 {
            startLoop()
        }
    }

    func appeared() {
        visibleViews += 1
        if visibleViews == 1 {
            startLoop()
        }
    }

    func disappeared() {
        visibleViews = max(0, visibleViews - 1)
        if visibleViews == 0 {
            loop?.cancel()
            loop = nil
        }
    }

    func refresh() async {
        let source = source
        let generation = sourceGeneration
        let found = await source.details()
        guard generation == sourceGeneration else {
            return
        }
        details = found
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// One line: "Wi-Fi · 192.168.1.24 · Router 192.168.1.1 · Signal good (−58 dBm) · 866 Mb/s · Channel 149, 5 GHz".
struct ConnectionCard: View {
    let model: NetworkDetailsModel

    var body: some View {
        GroupBox {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: model.details?.wifi == nil ? "cable.connector" : "wifi")
                    .foregroundStyle(.secondary)
                Text(model.details.map(Self.line) ?? String(localized: "Not connected", bundle: .strings))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .help(Text(model.details.map(Self.line) ?? ""))
        }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
    }

    static func line(_ details: NetworkDetails) -> String {
        var parts = [details.name]
        if let address = details.localAddress {
            parts.append(address)
        }
        if let router = details.router {
            parts.append(String(localized: "Router \(router)", bundle: .strings, comment: "Network tab: the router's address"))
        }
        if let wifi = details.wifi {
            let quality = qualityName(NetworkDetails.quality(rssi: wifi.rssi, noise: wifi.noise))
            let dBm = wifi.rssi.formatted()
            parts.append(String(
                localized: "Signal \(quality) (\(dBm) dBm)",
                bundle: .strings,
                comment: "Wi-Fi signal: quality, then strength"
            ))
            if wifi.transmitRate > 0 {
                let rate = Int(wifi.transmitRate.rounded()).formatted()
                parts.append(String(localized: "\(rate) Mb/s", bundle: .strings, comment: "Wi-Fi link rate in megabits per second"))
            }
            if let channel = wifi.channel {
                let number = channel.formatted()
                parts.append(wifi.band.map {
                    String(localized: "Channel \(number), \(bandName($0))", bundle: .strings, comment: "Wi-Fi channel and band")
                } ?? String(localized: "Channel \(number)", bundle: .strings))
            }
        }
        return parts.joined(separator: " · ")
    }

    static func qualityName(_ quality: NetworkDetails.SignalQuality) -> String {
        switch quality {
        case .excellent: String(localized: "excellent", bundle: .strings, comment: "Wi-Fi signal quality")
        case .good: String(localized: "good", bundle: .strings, comment: "Wi-Fi signal quality")
        case .fair: String(localized: "fair", bundle: .strings, comment: "Wi-Fi signal quality")
        case .weak: String(localized: "weak", bundle: .strings, comment: "Wi-Fi signal quality")
        }
    }

    static func bandName(_ band: NetworkDetails.Band) -> String {
        switch band {
        case .ghz2: String(localized: "2.4 GHz", bundle: .strings)
        case .ghz5: String(localized: "5 GHz", bundle: .strings)
        case .ghz6: String(localized: "6 GHz", bundle: .strings)
        }
    }
}
