import Core
import Foundation
import Testing

@Suite("Crowded Wi-Fi channels (D-286)")
struct WiFiChannelsTests {
    private func channel(_ number: Int, _ band: NetworkDetails.Band = .ghz2, width: Int = 20) -> WiFiChannelInfo {
        WiFiChannelInfo(channel: number, band: band, widthMHz: width)
    }

    private func network(_ number: Int, _ rssi: Int, _ band: NetworkDetails.Band = .ghz2, width: Int = 20) -> NearbyNetwork {
        NearbyNetwork(channel: channel(number, band, width: width), rssi: rssi)
    }

    private func scan(own: WiFiChannelInfo, rssi: Int = -50, heard: [NearbyNetwork], allowed: Set<WiFiChannelInfo> = []) -> WiFiScan {
        WiFiScan(at: Date(timeIntervalSince1970: 1_800_000_000), own: own, ownRSSI: rssi, heard: heard, allowed: allowed)
    }

    @Test("2.4 GHz: neighbors overlap unless five channels apart, which is why 1, 6 and 11")
    func overlap24() {
        #expect(!channel(1).overlaps(channel(6)))
        #expect(!channel(6).overlaps(channel(11)))
        #expect(channel(1).overlaps(channel(5)))
        #expect(channel(6).overlaps(channel(9)))
        #expect(channel(6).overlaps(channel(6)))
    }

    @Test("2.4 GHz at 40 MHz could reach either side, so it counts as reaching both")
    func wide24() {
        let wide = channel(6, width: 40)
        #expect(wide.overlaps(channel(1)))
        #expect(wide.overlaps(channel(11)))
        #expect(!channel(1, width: 40).overlaps(channel(11)))
    }

    @Test("5 GHz: wide channels are fixed blocks, whichever is the primary")
    func blocks5() {
        #expect(channel(36, .ghz5, width: 40).block == [36, 40])
        #expect(channel(40, .ghz5, width: 40).block == [36, 40])
        #expect(channel(44, .ghz5, width: 80).block == [36, 40, 44, 48])
        #expect(channel(149, .ghz5, width: 80).block == [149, 153, 157, 161])
        #expect(channel(100, .ghz5, width: 160).block == Array(stride(from: 100, through: 128, by: 4)))
        #expect(channel(132, .ghz5, width: 80).block == [132, 136, 140, 144])
        #expect(channel(36, .ghz5).block == [36])
    }

    @Test("5 GHz: overlap follows the blocks")
    func overlap5() {
        #expect(channel(36, .ghz5, width: 40).overlaps(channel(40, .ghz5)))
        #expect(!channel(36, .ghz5, width: 40).overlaps(channel(44, .ghz5)))
        #expect(channel(36, .ghz5, width: 80).overlaps(channel(48, .ghz5)))
        #expect(!channel(149, .ghz5, width: 80).overlaps(channel(165, .ghz5)))
        #expect(!channel(36, .ghz5).overlaps(channel(40, .ghz5)))
    }

    @Test("6 GHz: blocks start at channel 1; another band never overlaps")
    func sixGHz() {
        #expect(channel(5, .ghz6, width: 40).block == [1, 5])
        #expect(channel(37, .ghz6, width: 80).block == [33, 37, 41, 45])
        #expect(channel(1, .ghz6).overlaps(channel(1, .ghz6)))
        #expect(!channel(1, .ghz6).overlaps(channel(1)))
    }

    @Test("Real scan on this Mac: on 149 at 40 MHz, nothing near it, others on 2.4 GHz and 52")
    func realScan() {
        let found = WiFiCrowding.analyze(scan(own: channel(149, .ghz5, width: 40), rssi: -67, heard: [
            network(1, -78), network(52, -62, .ghz5, width: 40), network(56, -85, .ghz5, width: 40), network(6, -91), network(1, -65),
            network(6, -55), network(6, -54), network(11, -77), network(52, -60, .ghz5, width: 40),
        ]))
        #expect(found.level == .clear)
        #expect(found.competing.isEmpty)
        #expect(found.suggestion == nil)
        #expect(found.otherBands == 6)
        #expect(found.channels.map(\.channel) == [52, 56])
        #expect(found.channels.first?.networks == 2)
        #expect(found.channels.first?.strongest == -60)
    }

    @Test("The Mac's own network is left out when it's heard, and only that one")
    func ownLeftOut() {
        let same = [network(6, -50), network(6, -52)]
        #expect(WiFiCrowding.analyze(scan(own: channel(6), rssi: -50, heard: same)).sameChannel.map(\.rssi) == [-52])
        // Not listed, as on the real scan above: nothing's taken away.
        #expect(WiFiCrowding.analyze(scan(own: channel(6), rssi: -50, heard: [network(6, -80)])).sameChannel.count == 1)
        #expect(WiFiCrowding.analyze(scan(own: channel(6), rssi: -50, heard: [])).level == .clear)
    }

    @Test("Levels: nothing, a little, or a loud neighbor; overlap counts as well as the same channel")
    func levels() {
        func level(_ heard: NearbyNetwork...) -> WiFiCrowding.Level {
            WiFiCrowding.analyze(scan(own: channel(6), rssi: -40, heard: heard)).level
        }
        #expect(level(network(1, -60)) == .clear)
        #expect(level(network(6, -75)) == .light)
        #expect(level(network(4, -85), network(8, -85)) == .light)
        #expect(level(network(6, -60)) == .crowded)
        #expect(level(network(8, -60)) == .crowded)
        #expect(level(network(6, -75), network(7, -75), network(5, -75)) == .crowded)
    }

    @Test("Advice: a clearly quieter 1, 6 or 11, none when nothing's better or nothing's wrong")
    func suggestion24() {
        let busy = scan(own: channel(6), rssi: -40, heard: [network(6, -60), network(5, -62), network(1, -60), network(11, -85)])
        #expect(WiFiCrowding.analyze(busy).suggestion == 11)
        let everywhere = scan(own: channel(6), rssi: -40, heard: [network(1, -60), network(6, -60), network(11, -60)])
        #expect(WiFiCrowding.analyze(everywhere).suggestion == nil)
        let clear = scan(own: channel(6), rssi: -40, heard: [network(1, -60)])
        #expect(WiFiCrowding.analyze(clear).suggestion == nil)
    }

    @Test("Advice on 5 GHz: at the Mac's width, only where this Mac may go, and never a radar channel")
    func suggestion5() {
        let own = channel(36, .ghz5, width: 80)
        let heard = [network(36, -60, .ghz5, width: 80), network(44, -60, .ghz5, width: 80)]
        let allowed = Set([36, 40, 44, 48, 52, 56, 60, 64, 149, 153, 157, 161].map { channel($0, .ghz5) })
        #expect(WiFiCrowding.analyze(scan(own: own, rssi: -40, heard: heard, allowed: allowed)).suggestion == 149)
        // Where 149 isn't allowed, 52 is quiet but shared with radar: nothing to suggest.
        let noUpper = Set([36, 40, 44, 48, 52, 56, 60, 64].map { channel($0, .ghz5) })
        #expect(WiFiCrowding.analyze(scan(own: own, rssi: -40, heard: heard, allowed: noUpper)).suggestion == nil)
    }
}
