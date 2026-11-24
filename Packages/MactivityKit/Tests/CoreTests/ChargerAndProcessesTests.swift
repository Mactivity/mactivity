@testable import Core
import Testing

/// The charger check and macOS's own processes, named (D-214).
struct ChargerAndProcessesTests {
    @Test("Short now, held, or keeps up; nothing without a rating")
    func charger() {
        #expect(ChargerCheck.verdict(charger: 30, drawingNow: 38) == .short(drawing: 38, charger: 30))
        #expect(ChargerCheck.verdict(charger: 100, drawingNow: 5, heldAt: 52) == .holding(percent: 52, charger: 100))
        #expect(ChargerCheck.verdict(charger: 96, drawingNow: 12) == .keepsUp(charger: 96, drawing: 12))
        #expect(ChargerCheck.verdict(charger: nil, drawingNow: 12) == nil)
    }

    @Test("Busy system processes have a plain name; others don't")
    func processes() {
        #expect(SystemProcesses.describe("mds_stores") == "Spotlight indexing")
        #expect(SystemProcesses.describe("photoanalysisd") != nil)
        #expect(SystemProcesses.describe("Safari") == nil)
        #expect(SystemProcesses.describe("spotlightknowledged.updater") == SystemProcesses.describe("spotlightknowledged"))
        #expect(SystemProcesses.describe("com.apple.WebKit.WebContent.EnhancedSecurity") != nil)
        #expect(SystemProcesses.describe("mediaanalysisd-access") == SystemProcesses.describe("mediaanalysisd"))
    }
}
