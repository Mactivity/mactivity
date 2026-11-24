import Core
import Foundation
import Testing

@Suite("Drive health (D-157)")
struct DriveHealthTests {
    private func drive(used: Int = 3, spare: Int = 100, threshold: Int = 10, warning: Int = 0, errors: UInt64 = 0) -> DriveHealth {
        DriveHealth(
            index: 0, model: "APPLE SSD", isInternal: true, percentUsed: used, availableSpare: spare, spareThreshold: threshold,
            criticalWarning: warning, temperatureCelsius: 40, bytesRead: 0, bytesWritten: 0, powerOnHours: 100,
            unsafeShutdowns: 1, mediaErrors: errors
        )
    }

    @Test("Good, worn at 80% of rated life, failing on its own warnings, low spare or lost data")
    func verdicts() {
        #expect(drive().verdict == .good)
        #expect(drive().problem == nil)
        #expect(drive(used: 85).verdict == .worn)
        #expect(drive(spare: 5).verdict == .failing)
        #expect(drive(warning: 0x08).verdict == .failing)
        #expect(drive(warning: 0x08).problem?.contains("read-only") == true)
        #expect(drive(errors: 2).verdict == .failing)
        // Bit 5 (persistent memory region) isn't a fault.
        #expect(drive(warning: 0x20).verdict == .good)
    }

    @Test("Checkup: a failing drive is urgent, a worn one a suggestion, a good one nothing")
    func checkup() {
        var inputs = CheckupInputs()
        inputs.drives = [drive(), drive(used: 90), drive(errors: 1)]
        let items = Checkup.items(inputs).filter { $0.id.hasPrefix("drive:") }
        #expect(items.count == 2)
        #expect(items.first?.severity == .attention)
        #expect(items.last?.severity == .suggestion)
    }
}
