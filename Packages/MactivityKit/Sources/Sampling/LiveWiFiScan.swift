import Core
import CoreWLAN
import Foundation

/// Crowded Wi-Fi channels' real source (D-286). Public CoreWLAN, with no Location permission and
/// no prompt, so a scan has channels, bands and signals but no names or addresses.
public struct LiveWiFiScan: WiFiScanSource {
    public init() {}

    public func scan() async -> WiFiScanReading {
        await Task.detached(priority: .utility) { Self.scanNow() }.value
    }

    /// Blocks while Wi-Fi listens on each channel: a few seconds, 7 s measured.
    static func scanNow() -> WiFiScanReading {
        guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn(), wifi.rssiValue() != 0,
              let own = wifi.wlanChannel().flatMap(info)
        else {
            return .notJoined
        }
        guard let found = try? wifi.scanForNetworks(withName: nil) else {
            return .failed
        }
        let heard = found.compactMap { network in
            network.wlanChannel.flatMap(info).map { NearbyNetwork(channel: $0, rssi: network.rssiValue) }
        }
        let allowed = (wifi.supportedWLANChannels() ?? []).compactMap { channel in
            info(channel).map { WiFiChannelInfo(channel: $0.channel, band: $0.band) }
        }
        return .scanned(WiFiScan(at: Date(), own: own, ownRSSI: wifi.rssiValue(), heard: heard, allowed: Set(allowed)))
    }

    static func info(_ channel: CWChannel) -> WiFiChannelInfo? {
        let band: NetworkDetails.Band? = switch channel.channelBand {
        case .band2GHz: .ghz2
        case .band5GHz: .ghz5
        case .band6GHz: .ghz6
        default: nil
        }
        let width = switch channel.channelWidth {
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        default: 20
        }
        return band.map { WiFiChannelInfo(channel: channel.channelNumber, band: $0, widthMHz: width) }
    }
}
