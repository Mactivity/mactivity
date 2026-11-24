import Foundation

// Crowded Wi-Fi channels (D-286): whether nearby networks share or overlap the channel this Mac
// is on, from a scan the person asks for. Channels and signal strengths only: names need Location
// permission, which Mactivity never asks for. Advice only, since the channel is the router's
// setting.

/// A channel, in a band, at a width.
public struct WiFiChannelInfo: Hashable, Sendable {
    public let channel: Int
    public let band: NetworkDetails.Band
    public let widthMHz: Int

    public init(channel: Int, band: NetworkDetails.Band, widthMHz: Int = 20) {
        self.channel = channel
        self.band = band
        self.widthMHz = widthMHz
    }

    /// 5 GHz's runs of adjacent 20 MHz channels: wide channels are bonded inside a run.
    static let runs5GHz = [
        Array(stride(from: 36, through: 64, by: 4)),
        Array(stride(from: 100, through: 144, by: 4)),
        Array(stride(from: 149, through: 177, by: 4)),
    ]
    static let run6GHz = Array(stride(from: 1, through: 233, by: 4))

    /// Pure: the 20 MHz channels this one covers. A wide channel is a fixed block, whichever of
    /// its channels is the primary: 149 at 40 MHz is 149 and 153, and so is 153 at 40 MHz.
    public var block: [Int] {
        let run: [Int]? = switch band {
        case .ghz2: nil
        case .ghz5: Self.runs5GHz.first { $0.contains(channel) }
        case .ghz6: Self.run6GHz.contains(channel) ? Self.run6GHz : nil
        }
        guard let run, let index = run.firstIndex(of: channel) else {
            return [channel]
        }
        let size = max(1, widthMHz / 20)
        let start = index / size * size
        return Array(run[start ..< min(start + size, run.count)])
    }

    private static func frequency(_ channel: Int, _ band: NetworkDetails.Band) -> Int {
        switch band {
        case .ghz2: channel == 14 ? 2484 : 2407 + 5 * channel
        case .ghz5: 5000 + 5 * channel
        case .ghz6: 5950 + 5 * channel
        }
    }

    /// Pure: the frequencies it occupies, in MHz. On 2.4 GHz channels are only 5 MHz apart and a
    /// signal is about 22 MHz wide, so neighbors overlap unless they're five channels apart: why
    /// 1, 6 and 11 are the usual three. A 40 MHz channel there may reach above or below its
    /// primary, and the scan doesn't say which, so it counts as reaching both.
    var span: ClosedRange<Int> {
        if band == .ghz2 {
            let center = Self.frequency(channel, band)
            let reach = widthMHz >= 40 ? 31 : 11
            return (center - reach) ... (center + reach)
        }
        let channels = block
        return (Self.frequency(channels.first ?? channel, band) - 10) ... (Self.frequency(channels.last ?? channel, band) + 10)
    }

    /// Pure: whether two channels use any of the same frequencies.
    public func overlaps(_ other: WiFiChannelInfo) -> Bool {
        band == other.band && span.lowerBound < other.span.upperBound && other.span.lowerBound < span.upperBound
    }
}

/// One network the scan heard. A router's second network (a guest network, say) is another one.
public struct NearbyNetwork: Hashable, Sendable {
    public let channel: WiFiChannelInfo
    /// dBm, e.g. -62.
    public let rssi: Int

    public init(channel: WiFiChannelInfo, rssi: Int) {
        self.channel = channel
        self.rssi = rssi
    }
}

/// What a scan found.
public struct WiFiScan: Hashable, Sendable {
    public let at: Date
    /// The channel this Mac is joined on.
    public let own: WiFiChannelInfo
    public let ownRSSI: Int
    /// Everything heard, which may include this Mac's own network.
    public let heard: [NearbyNetwork]
    /// The 20 MHz channels this Mac may use where it is; empty when it doesn't say.
    public let allowed: Set<WiFiChannelInfo>

    public init(at: Date, own: WiFiChannelInfo, ownRSSI: Int, heard: [NearbyNetwork], allowed: Set<WiFiChannelInfo> = []) {
        self.at = at
        self.own = own
        self.ownRSSI = ownRSSI
        self.heard = heard
        self.allowed = allowed
    }
}

public enum WiFiScanReading: Hashable, Sendable {
    /// Wi-Fi is off or not joined to a network, so there's no channel to compare.
    case notJoined
    /// macOS refused or the scan failed; it can when Wi-Fi is busy.
    case failed
    case scanned(WiFiScan)
}

/// Where scans come from (D-286): the real Mac, or Simulated.
public protocol WiFiScanSource: Sendable {
    /// Scans now. This briefly takes Wi-Fi off its channel: call it only when the person asks.
    func scan() async -> WiFiScanReading
}

/// How crowded this Mac's channel is, from one scan. Pure.
public struct WiFiCrowding: Hashable, Sendable {
    public enum Level: Hashable, Sendable {
        /// Nothing heard on or overlapping the channel.
        case clear
        /// Something's there, but not enough to compete much.
        case light
        case crowded
    }

    /// One channel in this Mac's band, for the card's table.
    public struct ChannelLoad: Hashable, Sendable, Identifiable {
        public let channel: Int
        public let networks: Int
        public let strongest: Int
        public let isYours: Bool
        public let overlapsYours: Bool

        public var id: Int {
            channel
        }
    }

    public let own: WiFiChannelInfo
    /// On exactly this channel.
    public let sameChannel: [NearbyNetwork]
    /// On another channel that reaches into this one.
    public let overlapping: [NearbyNetwork]
    public let level: Level
    /// Heard in this band, by channel, the Mac's own network left out.
    public let channels: [ChannelLoad]
    /// Heard in other bands.
    public let otherBands: Int
    /// A clearly quieter channel in the same band, when there is one.
    public let suggestion: Int?

    /// Strong enough to compete for the air, and to be counted as strong on the card.
    static let loud = -67
    static let audible = -80
    /// The score from which a channel reads as crowded: one loud network, or three audible.
    static let crowdedScore = 3.0
    /// How much quieter another channel must be to be worth a trip to the router's settings.
    static let worthMoving = 2.0

    public var competing: [NearbyNetwork] {
        sameChannel + overlapping
    }

    public var loudCount: Int {
        competing.count { $0.rssi >= Self.loud }
    }

    public static func analyze(_ scan: WiFiScan) -> WiFiCrowding {
        let others = withoutOwn(scan)
        let band = others.filter { $0.channel.band == scan.own.band }
        let same = band.filter { $0.channel.channel == scan.own.channel }
        let overlapping = band.filter { $0.channel.channel != scan.own.channel && $0.channel.overlaps(scan.own) }
        let ownScore = score(scan.own, band)
        let level: Level = same.isEmpty && overlapping.isEmpty ? .clear : ownScore >= crowdedScore ? .crowded : .light
        let channels = Dictionary(grouping: band) { $0.channel.channel }.map { channel, networks in
            ChannelLoad(
                channel: channel, networks: networks.count, strongest: networks.map(\.rssi).max() ?? 0,
                isYours: channel == scan.own.channel,
                overlapsYours: channel != scan.own.channel && networks.contains { $0.channel.overlaps(scan.own) }
            )
        }.sorted { $0.channel < $1.channel }
        return WiFiCrowding(
            own: scan.own, sameChannel: same, overlapping: overlapping, level: level, channels: channels,
            otherBands: others.count - band.count, suggestion: suggestion(scan, band: band, ownScore: ownScore, level: level)
        )
    }

    /// The scan has no names or addresses to tell this Mac's own network by, and it isn't always
    /// listed. So: the network on the same channel nearest the signal this Mac reports, if that's
    /// within 10 dB. At most one is left out.
    static func withoutOwn(_ scan: WiFiScan) -> [NearbyNetwork] {
        let nearest = scan.heard
            .enumerated()
            .filter { $0.element.channel.band == scan.own.band && $0.element.channel.channel == scan.own.channel }
            .min { abs($0.element.rssi - scan.ownRSSI) < abs($1.element.rssi - scan.ownRSSI) }
        guard let nearest, abs(nearest.element.rssi - scan.ownRSSI) <= 10 else {
            return scan.heard
        }
        var others = scan.heard
        others.remove(at: nearest.offset)
        return others
    }

    /// How much competition a channel has: a loud network counts 3, an audible one 1, a faint one
    /// a quarter.
    static func score(_ channel: WiFiChannelInfo, _ networks: [NearbyNetwork]) -> Double {
        networks.filter { $0.channel.overlaps(channel) }.reduce(0) { total, network in
            total + (network.rssi >= loud ? 3 : network.rssi >= audible ? 1 : 0.25)
        }
    }

    /// The channels worth suggesting at the Mac's width. On 5 GHz, not the ones shared with radar,
    /// which a router has to leave if it hears any; none in a block this Mac may not use here.
    static func candidates(_ scan: WiFiScan) -> [WiFiChannelInfo] {
        let allowed = { (channel: Int) in
            scan.allowed.isEmpty || scan.allowed.contains(WiFiChannelInfo(channel: channel, band: scan.own.band))
        }
        let width = scan.own.widthMHz
        switch scan.own.band {
        case .ghz2:
            return [1, 6, 11].filter(allowed).map { WiFiChannelInfo(channel: $0, band: .ghz2) }
        case .ghz5:
            let radar = 52 ... 144
            return WiFiChannelInfo.runs5GHz.flatMap { blocks($0, width: width) }
                .filter { block in block.contains { !radar.contains($0) } && block.allSatisfy(allowed) }
                .compactMap(\.first)
                .map { WiFiChannelInfo(channel: $0, band: .ghz5, widthMHz: width) }
        case .ghz6:
            return blocks(WiFiChannelInfo.run6GHz, width: width)
                .filter { $0.allSatisfy(allowed) }
                .compactMap(\.first)
                .map { WiFiChannelInfo(channel: $0, band: .ghz6, widthMHz: width) }
        }
    }

    private static func blocks(_ run: [Int], width: Int) -> [[Int]] {
        let size = max(1, width / 20)
        return stride(from: 0, to: run.count, by: size).compactMap { start in
            start + size <= run.count ? Array(run[start ..< start + size]) : nil
        }
    }

    private static func suggestion(_ scan: WiFiScan, band: [NearbyNetwork], ownScore: Double, level: Level) -> Int? {
        guard level != .clear else {
            return nil
        }
        let best = candidates(scan)
            .filter { !$0.overlaps(scan.own) }
            .map { (channel: $0, score: score($0, band)) }
            // On a tie, the lowest channel, so the answer doesn't change from scan to scan.
            .min { ($0.score, $0.channel.channel) < ($1.score, $1.channel.channel) }
        guard let best, best.score <= ownScore - worthMoving else {
            return nil
        }
        return best.channel.channel
    }
}
