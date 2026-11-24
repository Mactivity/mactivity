import Core
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import UI

@MainActor
@Suite("Stay Awake (D-147, D-162)", .serialized)
struct KeepAwakeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func battery(_ percent: Double, unplugged: Bool) -> BatteryStats {
        BatteryStats(
            percent: percent, isCharging: false, source: unplugged ? .battery : .ac, timeRemaining: nil, cycleCount: nil,
            maxCapacityPercent: nil, powerDrawWatts: nil
        )
    }

    @Test("Ends at its time, on a low battery while unplugged, or when the Mac is hot")
    func reasons() {
        #expect(KeepAwakeModel.reasonToStop(mode: .indefinitely, now: now, battery: nil, thermal: .nominal) == nil)
        #expect(KeepAwakeModel.reasonToStop(mode: .until(now - 1), now: now, battery: nil, thermal: nil) != nil)
        #expect(KeepAwakeModel.reasonToStop(mode: .until(now + 60), now: now, battery: nil, thermal: nil) == nil)
        #expect(KeepAwakeModel.reasonToStop(mode: .indefinitely, now: now, battery: battery(8, unplugged: true), thermal: nil) != nil)
        #expect(KeepAwakeModel.reasonToStop(mode: .indefinitely, now: now, battery: battery(8, unplugged: false), thermal: nil) == nil)
        #expect(KeepAwakeModel.reasonToStop(mode: .indefinitely, now: now, battery: nil, thermal: .serious) != nil)
    }

    /// Mactivity's own assertions, from macOS's list.
    private func ownAssertionNames() -> [String] {
        var result: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess,
              let byProcess = result?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else {
            return []
        }
        let own = byProcess[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return own.compactMap { $0["AssertName"] as? String }
    }

    @Test("Turning it on asks macOS to stay awake; turning it off lets go")
    func assertion() {
        let model = KeepAwakeModel()
        model.set(.indefinitely)
        #expect(ownAssertionNames().contains(KeepAwakeModel.assertionName))
        model.set(.off)
        #expect(!ownAssertionNames().contains(KeepAwakeModel.assertionName))
    }

    @Test("It remembers when it was on, so a night it kept awake isn't flagged")
    func remembers() {
        let model = KeepAwakeModel()
        let before = Date()
        #expect(!model.wasOn(from: before.addingTimeInterval(-3600), to: before.addingTimeInterval(3600)))
        model.set(.indefinitely)
        model.set(.off)
        #expect(model.wasOn(from: before.addingTimeInterval(-3600), to: before.addingTimeInterval(3600)))
        #expect(!model.wasOn(from: before.addingTimeInterval(-7200), to: before.addingTimeInterval(-3600)))
    }
}
