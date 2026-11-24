import Foundation
import Sampling
import Testing

@Suite("Disk sampler and network mounts (D-285)")
struct DiskLocalOnlyTests {
    @Test("The sampler's volumes don't include network mounts, so a dead one can't stop it")
    func skipsNetwork() {
        let volumes = ["/", "/Volumes/Backup", "/Volumes/Media"].map { URL(fileURLWithPath: $0) }
        #expect(DiskMath.localOnly(volumes, nonLocalMounts: ["/Volumes/Media"]).map(\.path) == ["/", "/Volumes/Backup"])
    }
}
