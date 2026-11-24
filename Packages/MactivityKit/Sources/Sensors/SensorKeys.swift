import Core
import Foundation

/// Decoding SMC values and choosing which keys stand for CPU, GPU, battery, and SSD
/// (spec 6.10). Pure, so key tables are tested on fixtures of real key lists.
public enum SensorKeys {
    /// A group of SMC temperature keys that make one figure.
    public struct Group: Hashable, Sendable, Codable {
        public let id: String
        public let name: String
        public let keys: [String]
    }

    /// Key prefixes per Apple silicon family. The SMC's key names change between generations: M1
    /// and M2 use Tp0x/Te0x for P and E cores, M3 and M4 Tp/Te, and M5 Tp/Tm/Ts. Discovery reads
    /// the Mac's real key list, and this table picks from it.
    public struct Family: Sendable {
        public let name: String
        public let cpuPrefixes: [String]
        public let gpuPrefixes: [String]
    }

    public static let families: [Family] = [
        Family(name: "M1", cpuPrefixes: ["Tp0", "Te0"], gpuPrefixes: ["Tg0"]),
        Family(name: "M2", cpuPrefixes: ["Tp0", "Te0"], gpuPrefixes: ["Tg0"]),
        Family(name: "M3", cpuPrefixes: ["Tp", "Te"], gpuPrefixes: ["Tg"]),
        Family(name: "M4", cpuPrefixes: ["Tp", "Te"], gpuPrefixes: ["Tg"]),
        Family(name: "M5", cpuPrefixes: ["Tp", "Tm", "Ts"], gpuPrefixes: ["Tg"]),
    ]

    /// Newer chips than the table knows get the widest net.
    public static let fallbackFamily = Family(name: "Apple silicon", cpuPrefixes: ["Tp", "Te", "Tm", "Ts"], gpuPrefixes: ["Tg"])

    /// "Apple M5 Pro" → the M5 family.
    public static func family(forChip chip: String) -> Family {
        families.first { chip.range(of: "\\b\($0.name)\\b", options: .regularExpression) != nil } ?? fallbackFamily
    }

    /// At most this many keys per figure: each read is a kernel round trip (~0.2 ms).
    public static let maxKeysPerGroup = 8

    public static let batteryKeys = ["TB0T", "TB1T", "TB2T"]
    public static let ssdKeys = ["TH0x", "TH0a", "TH0b"]

    /// The groups for this Mac, from the temperature keys it actually has.
    public static func groups(availableKeys: [String], family: Family) -> [Group] {
        let keys = Set(availableKeys.filter { $0.hasPrefix("T") && $0.count == 4 })
        func matching(_ prefixes: [String]) -> [String] {
            keys.filter { key in prefixes.contains { key.hasPrefix($0) } }.sorted()
        }
        var groups: [Group] = []
        let cpu = sample(matching(family.cpuPrefixes))
        if !cpu.isEmpty {
            groups.append(Group(id: "cpu", name: "CPU", keys: cpu))
        }
        let gpu = sample(matching(family.gpuPrefixes))
        if !gpu.isEmpty {
            groups.append(Group(id: "gpu", name: "GPU", keys: gpu))
        }
        let battery = batteryKeys.filter(keys.contains)
        if !battery.isEmpty {
            groups.append(Group(id: "battery", name: "Battery", keys: battery))
        }
        if let ssd = ssdKeys.first(where: keys.contains) {
            groups.append(Group(id: "ssd", name: "SSD", keys: [ssd]))
        }
        return groups
    }

    /// Up to `maxKeysPerGroup` keys, round-robin across two-letter prefixes (one per core
    /// cluster), evenly spaced within each, so every cluster is represented.
    static func sample(_ keys: [String]) -> [String] {
        guard keys.count > maxKeysPerGroup else {
            return keys
        }
        let buckets = Dictionary(grouping: keys, by: { String($0.prefix(2)) }).values.map { $0.sorted() }
            .sorted { ($0.first ?? "") < ($1.first ?? "") }
        var picked: [String] = []
        var round = 0
        while picked.count < maxKeysPerGroup {
            var added = false
            for bucket in buckets where picked.count < maxKeysPerGroup {
                let share = max(1, (maxKeysPerGroup + buckets.count - 1) / buckets.count)
                guard round < min(share, bucket.count) else {
                    continue
                }
                picked.append(bucket[round * bucket.count / min(share, bucket.count)])
                added = true
            }
            guard added else {
                break
            }
            round += 1
        }
        return picked.sorted()
    }

    /// Plausible die and board temperatures; anything else is a sensor that isn't wired up.
    public static let plausibleCelsius: ClosedRange<Double> = 5 ... 125

    /// The average of the plausible readings, or nil.
    public static func combine(_ readings: [Double]) -> Double? {
        let valid = readings.filter { plausibleCelsius.contains($0) }
        return valid.isEmpty ? nil : valid.reduce(0, +) / Double(valid.count)
    }

    /// SMC value decoding for the types Mactivity reads. Big-endian except `flt`.
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        func be16() -> UInt16? {
            bytes.count >= 2 ? UInt16(bytes[0]) << 8 | UInt16(bytes[1]) : nil
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else {
                return nil
            }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ", "si8 ":
            guard let first = bytes.first else {
                return nil
            }
            return type == "si8 " ? Double(Int8(bitPattern: first)) : Double(first)
        case "ui16":
            return be16().map(Double.init)
        case "ui32":
            guard bytes.count >= 4 else {
                return nil
            }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "fpe2":
            return be16().map { Double($0) / 4 }
        case "sp78":
            return be16().map { Double(Int16(bitPattern: $0)) / 256 }
        default:
            return nil
        }
    }

    /// "Magic Mouse" → .mouse, "Magic Keyboard with Touch ID" → .keyboard, "AirPods Pro" → .airPods.
    public static func peripheralKind(forProduct product: String) -> PeripheralBattery.Kind {
        let name = product.lowercased()
        if name.contains("airpods") || name.contains("beats") {
            return .airPods
        }
        if name.contains("trackpad") {
            return .trackpad
        }
        if name.contains("mouse") {
            return .mouse
        }
        if name.contains("keyboard") {
            return .keyboard
        }
        return .other
    }
}
