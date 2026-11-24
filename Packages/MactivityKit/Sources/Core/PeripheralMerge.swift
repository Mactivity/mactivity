import Foundation

/// One entry per accessory (D-165). A Magic Keyboard, Trackpad or Mouse on Bluetooth is seen
/// twice: IORegistry's HID service (exact level, keyed by serial number) and the Bluetooth list
/// (keyed by address, with the name the person gave it). They're the same device when the HID
/// service's `DeviceAddress` is the Bluetooth address; without an address, when the kind matches,
/// the levels agree within 2 points and one name contains the other. Pure.
public enum PeripheralMerge {
    public struct HIDReading: Hashable, Sendable {
        public let battery: PeripheralBattery
        /// The Bluetooth address the HID service reports, when it's a Bluetooth device.
        public let address: String?

        public init(battery: PeripheralBattery, address: String?) {
            self.battery = battery
            self.address = address
        }
    }

    /// "AA:BB:CC:DD:EE:FF" and "aa-bb-cc-dd-ee-ff" are the same address.
    public static func normalized(_ address: String?) -> String? {
        guard let address, !address.isEmpty else {
            return nil
        }
        return address.lowercased().replacingOccurrences(of: ":", with: "-")
    }

    /// `bluetooth` entries carry their address as `id`.
    public static func merge(hid: [HIDReading], bluetooth: [PeripheralBattery]) -> [PeripheralBattery] {
        // A device can publish more than one HID service: keep the first of each.
        var seen = Set<String>()
        let devices = hid.filter { seen.insert(normalized($0.address) ?? $0.battery.id).inserted }
        var matched = Set<Int>()
        var result: [PeripheralBattery] = []
        for wireless in bluetooth {
            let address = normalized(wireless.id)
            let index = devices.indices.first { index in
                !matched.contains(index) && address != nil && normalized(devices[index].address) == address
            } ?? devices.indices.first { index in
                !matched.contains(index) && sameDevice(devices[index].battery, wireless)
            }
            guard let index else {
                result.append(wireless)
                continue
            }
            matched.insert(index)
            let wired = devices[index].battery
            // The serial number keeps its history; the name is the one the person chose.
            result.append(PeripheralBattery(id: wired.id, name: wireless.name, kind: wired.kind, percent: wired.percent))
        }
        result += devices.indices.filter { !matched.contains($0) }.map { devices[$0].battery }
        return result.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    static func sameDevice(_ hid: PeripheralBattery, _ wireless: PeripheralBattery) -> Bool {
        guard hid.kind == wireless.kind, hid.kind != .other, hid.kind != .airPods, abs(hid.percent - wireless.percent) <= 2 else {
            return false
        }
        let a = hid.name.lowercased()
        let b = wireless.name.lowercased()
        return a.contains(b) || b.contains(a) || a.split(separator: " ").contains { word in
            word.count > 3 && ["keyboard", "trackpad", "mouse"].contains(String(word)) && b.contains(word)
        }
    }
}
