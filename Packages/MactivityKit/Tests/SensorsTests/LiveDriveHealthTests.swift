import Core
import Foundation
@testable import Sensors
import Testing

@Suite("Drive health, read live (D-157)")
struct LiveDriveHealthTests {
    /// CI's virtual Macs have no NVMe drive; a real Mac lists its internal SSD first.
    @Test("Each drive that answers has sane figures, the internal one first")
    func live() async {
        let drives = await LiveDriveHealth().drives()
        for drive in drives {
            #expect(!drive.model.isEmpty)
            #expect((0 ... 255).contains(drive.percentUsed))
            #expect((0 ... 100).contains(drive.availableSpare))
        }
        if drives.count > 1 {
            #expect(drives.first?.isInternal == true)
        }
    }
}
