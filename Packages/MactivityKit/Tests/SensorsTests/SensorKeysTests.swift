import Core
import Foundation
@testable import PrivateAPIs
@testable import Sensors
import Testing

@Suite("Sensor keys")
struct SensorKeysTests {
    struct KeyFixture: Decodable {
        let chip: String
        let keys: [String]
    }

    @Test("M5 Pro keys give CPU, GPU, battery, and SSD groups, each capped")
    func m5Pro() throws {
        let fixture: KeyFixture = try Fixtures.load("smc-keys-m5pro.json")
        let groups = SensorKeys.groups(availableKeys: fixture.keys, family: SensorKeys.family(forChip: fixture.chip))
        #expect(groups.map(\.id) == ["cpu", "gpu", "battery", "ssd"])
        let cpu = try #require(groups.first)
        #expect(cpu.keys.count == SensorKeys.maxKeysPerGroup)
        // All three core-sensor prefixes are represented, and nothing else (TPD0 is a different sensor).
        #expect(cpu.keys.allSatisfy { ["Tp", "Tm", "Ts"].contains(String($0.prefix(2))) })
        #expect(Set(cpu.keys.map { $0.prefix(2) }).count == 3)
        #expect(groups[2].keys == ["TB0T", "TB1T", "TB2T"])
        #expect(groups[3].keys == ["TH0x"])
    }

    @Test("Families by chip name", arguments: [
        ("Apple M1 Pro", "M1"), ("Apple M2", "M2"), ("Apple M3 Max", "M3"), ("Apple M4", "M4"), ("Apple M5 Pro", "M5"),
        ("Apple M9 Ultra", "Apple silicon"), ("Apple M10", "Apple silicon"),
    ])
    func family(chip: String, expected: String) {
        #expect(SensorKeys.family(forChip: chip).name == expected)
    }

    @Test("M1 keys use Tp0/Te0")
    func m1() {
        let groups = SensorKeys.groups(
            availableKeys: ["Tp01", "Tp05", "Te05", "Tg05", "Tm02"],
            family: SensorKeys.family(forChip: "Apple M1")
        )
        #expect(groups.first { $0.id == "cpu" }?.keys == ["Te05", "Tp01", "Tp05"])
        #expect(groups.first { $0.id == "gpu" }?.keys == ["Tg05"])
    }

    @Test("No temperature keys, no groups")
    func none() {
        #expect(SensorKeys.groups(availableKeys: ["FNum", "#KEY"], family: SensorKeys.fallbackFamily).isEmpty)
    }

    @Test("Implausible readings are ignored")
    func combine() {
        #expect(SensorKeys.combine([40, 42, -9199, 0, 300]) == 41)
        #expect(SensorKeys.combine([-1]) == nil)
    }

    @Test("Value decoding", arguments: [
        ("flt ", [0x00, 0x00, 0x28, 0x42], 42.0),
        ("ui8 ", [2], 2),
        ("ui16", [0x0E, 0x1B], 3611),
        ("ui32", [0, 0, 0x0E, 0x1B], 3611),
        ("fpe2", [0x24, 0x40], 2320),
        ("sp78", [0x2A, 0x80], 42.5),
    ] as [(String, [UInt8], Double)])
    func decode(type: String, bytes: [UInt8], expected: Double) {
        #expect(SensorKeys.decode(type: type, bytes: bytes) == expected)
    }

    @Test("Unknown types and short buffers decode to nil")
    func decodeInvalid() {
        #expect(SensorKeys.decode(type: "ch8*", bytes: [1, 2]) == nil)
        #expect(SensorKeys.decode(type: "flt ", bytes: [1]) == nil)
    }

    @Test("Peripheral kinds from product names", arguments: [
        ("Magic Mouse", PeripheralBattery.Kind.mouse), ("Magic Keyboard with Touch ID", .keyboard),
        ("Magic Trackpad", .trackpad), ("AirPods Pro", .airPods), ("Game Controller", .other),
    ])
    func kinds(product: String, expected: PeripheralBattery.Kind) {
        #expect(SensorKeys.peripheralKind(forProduct: product) == expected)
    }

    @Test("HID fallback: without the private symbols there are no readings")
    func hidFallback() {
        #expect(HIDTemperatures.read(prefix: "PMU tdie", limit: 4, using: nil) == nil)
    }
}

@Suite(
    "Sensor sampler (live)",
    .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil, "needs real Mac hardware: make test-live")
)
struct SensorSamplerLiveTests {
    @Test("This Mac reports a plausible CPU temperature, and fans with limits if it has them")
    func live() async throws {
        let stats = try await SensorSampler().sample()
        let cpu = try #require(stats.temperatures.first { $0.id == "cpu" })
        #expect(SensorKeys.plausibleCelsius.contains(cpu.celsius))
        for fan in stats.fans {
            #expect(fan.rpm >= 0)
            #expect((fan.maxRPM ?? 1) >= (fan.minRPM ?? 0))
        }
    }

    @Test("A sample after discovery is cheap")
    func timing() async throws {
        let sampler = SensorSampler()
        _ = try await sampler.sample()
        let elapsed = try await ContinuousClock().measure {
            for _ in 0 ..< 10 {
                _ = try await sampler.sample()
            }
        }
        #expect(elapsed / 10 < .milliseconds(20))
    }
}

@Suite("Bluetooth batteries")
struct BluetoothBatteriesTests {
    @Test("AirPods-style readings keep valid levels and drop zeros")
    func reading() throws {
        let reading = try #require(BluetoothBatteries.reading(address: "aa", name: "AirPods Pro", levels: [nil, 80, 0, 100]))
        #expect(reading.left == 80)
        #expect(reading.right == nil)
        #expect(reading.caseLevel == 100)
    }

    @Test("No levels means no reading")
    func none() {
        #expect(BluetoothBatteries.reading(address: "aa", name: "Keyboard", levels: [nil, nil, 0, nil]) == nil)
    }

    @Test("Without a Bluetooth usage string nothing touches IOBluetooth (tests would be killed otherwise)")
    @MainActor
    func guardsPermission() {
        #expect(BluetoothBatteries.read(bundle: Bundle(for: BundleMarker.self)).isEmpty)
        // Not yet allowed: never touches IOBluetooth, which would block until the prompt is answered.
        #expect(!BluetoothBatteries.mayRead(hasUsageString: true, isAuthorized: { false }))
        #expect(BluetoothBatteries.mayRead(hasUsageString: true, isAuthorized: { true }))
        #expect(!BluetoothBatteries.mayRead(
            hasUsageString: false,
            isAuthorized: { Issue.record("status read without a usage string"); return true }
        ))
    }
}

private final class BundleMarker {}
