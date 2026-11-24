import Core
import Testing

@Suite("Wi-Fi signal quality (D-149)")
struct NetworkDetailsTests {
    @Test("RSSI bands, with a poor margin over the noise counting against it")
    func quality() {
        #expect(NetworkDetails.quality(rssi: -40, noise: -95) == .excellent)
        #expect(NetworkDetails.quality(rssi: -60, noise: -95) == .good)
        #expect(NetworkDetails.quality(rssi: -72, noise: -95) == .fair)
        #expect(NetworkDetails.quality(rssi: -80, noise: -95) == .weak)
        // Strong, but in a noisy room.
        #expect(NetworkDetails.quality(rssi: -50, noise: -62) == .fair)
        // No noise figure: RSSI alone.
        #expect(NetworkDetails.quality(rssi: -50, noise: 0) == .excellent)
    }
}
