import Core
import Foundation
@testable import Sampling
import Testing

@Suite("Reading interfaces (D-264)")
struct LiveNetworkInterfacesTests {
    @Test("Media words, as net/if_media.h defines them")
    func media() {
        let gigabit = LiveNetworkInterfaces.mediaFrom(current: 0x20, active: 0x20 | 16 | 0x0010_0000, status: 3)
        #expect(gigabit.name == "1000baseT" && gigabit.isActive == true && gigabit.isFullDuplex == true)
        // Nothing plugged in: ifconfig's "media: none, status: inactive".
        let none = LiveNetworkInterfaces.mediaFrom(current: 0x20 | 2, active: 0x20 | 2, status: 1)
        #expect(none.name == nil && none.isActive == false && none.isFullDuplex == nil)
        // No valid status bit: the link doesn't say.
        #expect(LiveNetworkInterfaces.mediaFrom(current: 0x20, active: 0, status: 0).isActive == nil)
    }

    @Test("The media request's number is the header's macro")
    func request() {
        #expect(LiveNetworkInterfaces.getMedia == 0xC02C_6938)
    }

    @Test("A DHCP entry, as the Mac's configuration store holds it")
    func lease() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let found = LiveNetworkInterfaces.lease([
            "LeaseStartTime": start, "Option_51": Data([0x00, 0x01, 0x51, 0x80]), "Option_54": Data([192, 168, 1, 1]),
        ])
        #expect(found.server == "192.168.1.1")
        #expect(found.ends == start.addingTimeInterval(86400))
        #expect(LiveNetworkInterfaces.lease(["LeaseStartTime": start, "Option_51": Data([0xFF, 0xFF, 0xFF, 0xFF])]).ends == nil)
        #expect(LiveNetworkInterfaces.lease([:]).server == nil)
    }

    @Test("A bridge's members")
    func bridges() {
        let found = LiveNetworkInterfaces.bridgeMembers(["Bridge": ["bridge0": ["Interfaces": ["en1", "en6"], "Options": [:]]]])
        #expect(found == ["bridge0": ["en1", "en6"]])
        #expect(LiveNetworkInterfaces.bridgeMembers([:]).isEmpty)
    }
}
