import Testing
@testable import UI

/// The Battery card's symbol follows the battery (D-176).
struct BatterySymbolTests {
    @Test func levels() {
        #expect(HeadlineCard.batterySymbol(percent: 3, charging: false) == "battery.0percent")
        #expect(HeadlineCard.batterySymbol(percent: 30, charging: false) == "battery.25percent")
        #expect(HeadlineCard.batterySymbol(percent: 50, charging: false) == "battery.50percent")
        #expect(HeadlineCard.batterySymbol(percent: 84, charging: false) == "battery.75percent")
        #expect(HeadlineCard.batterySymbol(percent: 100, charging: false) == "battery.100percent")
        #expect(HeadlineCard.batterySymbol(percent: 3, charging: true) == "battery.100percent.bolt")
    }
}
