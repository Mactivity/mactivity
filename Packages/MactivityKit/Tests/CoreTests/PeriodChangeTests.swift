@testable import Core
import Testing

struct PeriodChangeTests {
    private func total(_ id: String, _ value: Double) -> AppTotal {
        AppTotal(app: AppIdentity(id: id, name: id, bundleID: nil, iconKey: id, kind: .app), value: value)
    }

    @Test("Labels round to whole percents and call ±1% the same")
    func labels() {
        #expect(PeriodChange.new.label == "New")
        #expect(PeriodChange.relative(0.254).label == "+25%")
        #expect(PeriodChange.relative(-0.1).label == "−10%")
        #expect(PeriodChange.relative(0.004).label == "Same")
        #expect(PeriodChange.new.isIncrease)
        #expect(!PeriodChange.relative(-0.5).isIncrease)
    }

    @Test("No previous data means no comparison, not everything new")
    func emptyPrevious() {
        #expect(PeriodChange.changes(current: [total("a", 1)], previous: []).isEmpty)
    }

    @Test("A zero previous value counts as new instead of dividing by zero")
    func zeroPrevious() {
        let changes = PeriodChange.changes(current: [total("a", 2), total("b", 3)], previous: [total("a", 0), total("b", 4)])
        #expect(changes["a"] == .new)
        #expect(changes["b"] == .relative(-0.25))
    }
}
