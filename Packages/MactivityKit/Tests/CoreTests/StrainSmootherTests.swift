import Core
import Foundation
import Testing

@Suite("Strain held steady (D-121)")
struct StrainSmootherTests {
    let start = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("A reason shows once it has held for 20 s, and clears after a minute without it")
    func onsetAndRelease() {
        var smoother = StrainSmoother()
        #expect(smoother.update(.memory, now: start) == nil)
        #expect(smoother.update(.memory, now: start + 10) == nil)
        #expect(smoother.update(.memory, now: start + 20) == .memory)
        #expect(smoother.update(nil, now: start + 30) == .memory)
        #expect(smoother.update(nil, now: start + 80) == .memory)
        #expect(smoother.update(nil, now: start + 90) == nil)
    }

    @Test("Pressure hovering at the line doesn't flicker the icon")
    func hovering() {
        var smoother = StrainSmoother()
        var changes = 0
        var last: StrainReason?
        // Warning and normal alternating every 10 s tick for ten minutes.
        for tick in 0 ..< 60 {
            let shown = smoother.update(tick.isMultiple(of: 2) ? .memory : nil, now: start + Double(tick) * 10)
            if shown != last {
                changes += 1
                last = shown
            }
        }
        #expect(changes <= 1)
    }

    @Test("CPU strain shows at once: it already took a minute over the line")
    func cpu() {
        var smoother = StrainSmoother()
        #expect(smoother.update(.cpu, now: start) == .cpu)
        #expect(smoother.update(nil, now: start + 30) == .cpu)
    }
}
