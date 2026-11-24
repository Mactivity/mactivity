import Core
import Foundation
import Testing

@Suite("Changes over time (D-160)")
struct TrendsTests {
    private func app(_ name: String) -> AppIdentity {
        AppIdentity(id: name, name: name, bundleID: nil, iconKey: "", kind: .app)
    }

    @Test("Memory up by half and by 500 MB is growth; small or new apps aren't")
    func growth() {
        let chrome = app("Chrome")
        let slack = app("Slack")
        let new = app("Figma")
        let found = Trends.growing(
            now: [
                AppTotal(app: chrome, value: 2_400_000_000), AppTotal(app: slack, value: 900_000_000),
                AppTotal(app: new, value: 3_000_000_000),
            ],
            before: [AppTotal(app: chrome, value: 1_200_000_000), AppTotal(app: slack, value: 700_000_000)],
            ratio: Trends.memoryRatio, increase: Trends.memoryIncrease
        )
        #expect(found.map(\.app.name) == ["Chrome"])
    }

    @Test("Drain rate needs three hours on battery; faster means a quarter and a point more")
    func drain() {
        #expect(Trends.drainRate(BatteryUse(apps: [], onBatterySeconds: 3600, drainedPercent: 10)) == nil)
        #expect(Trends.drainRate(BatteryUse(apps: [], onBatterySeconds: 4 * 3600, drainedPercent: 32)) == 8)
        #expect(Trends.drainsFaster(now: 8, before: 6))
        #expect(!Trends.drainsFaster(now: 6.5, before: 6))
        #expect(!Trends.drainsFaster(now: 1.4, before: 1))
    }

    @Test("Checkup names the growing app and the faster drain")
    func checkup() {
        var inputs = CheckupInputs()
        inputs.memoryGrowth = [Trends.Growth(app: app("Chrome"), before: 1_200_000_000, now: 2_400_000_000)]
        inputs.drain = (8, 6)
        let items = Checkup.items(inputs).filter { $0.id.hasPrefix("trend:") }
        #expect(items.map(\.id) == ["trend:memory:Chrome", "trend:drain"])
        #expect(items.first?.title.contains("Chrome") == true)
    }
}
