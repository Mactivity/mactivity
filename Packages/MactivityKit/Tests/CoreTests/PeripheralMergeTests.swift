import Core
import Foundation
import Testing

@Suite("One entry per accessory (D-165)")
struct PeripheralMergeTests {
    private func hid(
        _ serial: String,
        _ product: String,
        _ kind: PeripheralBattery.Kind,
        _ percent: Double,
        address: String?
    ) -> PeripheralMerge.HIDReading {
        PeripheralMerge.HIDReading(battery: PeripheralBattery(id: serial, name: product, kind: kind, percent: percent), address: address)
    }

    private func wireless(_ address: String, _ name: String, _ kind: PeripheralBattery.Kind, _ percent: Double) -> PeripheralBattery {
        PeripheralBattery(id: address, name: name, kind: kind, percent: percent)
    }

    @Test("A Magic Keyboard and Trackpad seen by IORegistry and by Bluetooth are listed once each, by address")
    func byAddress() {
        let merged = PeripheralMerge.merge(
            hid: [
                hid("F0T1", "Magic Keyboard with Touch ID", .keyboard, 73, address: "AA:BB:CC:DD:EE:01"),
                hid("F0T2", "Magic Trackpad", .trackpad, 41, address: "aa-bb-cc-dd-ee-02"),
            ],
            bluetooth: [
                wireless("aa-bb-cc-dd-ee-01", "Kade’s Keyboard", .keyboard, 70),
                wireless("aa-bb-cc-dd-ee-02", "Kade’s Trackpad", .trackpad, 40),
                wireless("aa-bb-cc-dd-ee-03", "AirPods Pro", .airPods, 55),
            ]
        )
        #expect(merged.count == 3)
        let keyboard = merged.first { $0.kind == .keyboard }
        // The serial number keeps its history, the name is the person's, the level is IORegistry's.
        #expect(keyboard?.id == "F0T1")
        #expect(keyboard?.name == "Kade’s Keyboard")
        #expect(keyboard?.percent == 73)
    }

    @Test("Without an address: the same kind, a level within 2 points and a shared product word")
    func byName() {
        let merged = PeripheralMerge.merge(
            hid: [hid("S1", "Magic Keyboard", .keyboard, 80, address: nil)],
            bluetooth: [wireless("aa-01", "Office Magic Keyboard", .keyboard, 79)]
        )
        #expect(merged.count == 1)
        #expect(merged.first?.name == "Office Magic Keyboard")
        // Different levels: two devices.
        let two = PeripheralMerge.merge(
            hid: [hid("S1", "Magic Keyboard", .keyboard, 80, address: nil)],
            bluetooth: [wireless("aa-01", "Office Magic Keyboard", .keyboard, 40)]
        )
        #expect(two.count == 2)
    }

    @Test("A device publishing two HID services is listed once; a USB-connected one stays")
    func hidDuplicates() {
        let merged = PeripheralMerge.merge(
            hid: [
                hid("K1", "Magic Keyboard", .keyboard, 60, address: "aa-01"),
                hid("K1b", "Magic Keyboard", .keyboard, 60, address: "AA:01"),
                hid("M1", "Magic Mouse", .mouse, 90, address: nil),
            ],
            bluetooth: []
        )
        #expect(merged.map(\.id) == ["K1", "M1"])
    }
}
