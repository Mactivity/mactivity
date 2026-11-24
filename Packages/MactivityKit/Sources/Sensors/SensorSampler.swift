import Core
import Foundation
import IOKit
import os
import PrivateAPIs

/// Temperatures, fans, and peripheral batteries (spec 5.6, 6.10).
///
/// SMC first: public IOKit calls, clean CPU/GPU/battery/SSD keys, 0.2 ms per read. The HID
/// event system (private, in PrivateAPIs) is the fallback for CPU temperature when a Mac's SMC
/// exposes no CPU keys. Keys are discovered once, lazily, on the first sample.
public actor SensorSampler: SensorSource, PeripheralBatterySource {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    private static let log = Logger(subsystem: "app.mactivity.sensors", category: "sampler")

    private var smc: SMC?
    private var groups: [SensorKeys.Group] = []
    private var fanCount = 0
    private var fanLimits: [Int: (min: Double?, max: Double?)] = [:]
    private var discovered = false
    /// The groups came from `keyCache` and haven't been read yet: if any key fails on that first
    /// read, the cache is stale (a firmware update renamed keys) and keys are discovered again.
    private var groupsFromCache = false
    private let chip: String
    private let keyCache: SensorKeyCache?

    /// `keyCache` keeps discovered keys between launches (nil: discover every launch).
    public init(chip: String? = nil, keyCache: SensorKeyCache? = nil) {
        self.chip = chip ?? Self.brandString()
        self.keyCache = keyCache
    }

    public func sample() async throws -> SensorStats {
        discoverIfNeeded()
        var temperatures: [TemperatureReading] = []
        if let smc {
            var failed = false
            for group in groups {
                let values = group.keys.compactMap(smc.value)
                failed = failed || values.count < group.keys.count
                if let celsius = SensorKeys.combine(values) {
                    temperatures.append(TemperatureReading(id: group.id, name: group.name, celsius: celsius))
                }
            }
            if groupsFromCache {
                groupsFromCache = false
                if failed {
                    Self.log.notice("Cached SMC keys didn't all read; discovering again")
                    discover(smc, useCache: false)
                    return try await sample()
                }
            }
        }
        if !temperatures.contains(where: { $0.id == "cpu" }),
           let die = HIDTemperatures.read(prefix: "PMU tdie"),
           let celsius = SensorKeys.combine(Array(die.values)) {
            temperatures.insert(TemperatureReading(id: "cpu", name: "CPU", celsius: celsius), at: 0)
        }
        var fans: [FanReading] = []
        if let smc {
            for index in 0 ..< fanCount {
                let limits = fanLimits[index]
                fans.append(FanReading(
                    id: index, rpm: max(0, smc.value("F\(index)Ac") ?? 0), minRPM: limits?.min, maxRPM: limits?.max
                ))
            }
        }
        return await SensorStats(temperatures: temperatures, fans: fans, peripherals: peripherals())
    }

    /// Accessory batteries alone, for their history (D-094): no SMC, no temperatures.
    public func peripherals() async -> [PeripheralBattery] {
        await PeripheralMerge.merge(hid: PeripheralBatteries.read(), bluetooth: bluetooth())
    }

    /// Bluetooth accessories change slowly and each read asks bluetoothd, so at most once a minute.
    private var lastBluetooth: (at: ContinuousClock.Instant, peripherals: [PeripheralBattery])?

    private func bluetooth() async -> [PeripheralBattery] {
        let now = ContinuousClock.now
        if let last = lastBluetooth, now - last.at < .seconds(60) {
            return last.peripherals
        }
        let readings = await MainActor.run { BluetoothBatteries.read() }
        let peripherals = readings.map { reading -> PeripheralBattery in
            // AirPods: the lower bud is the one that runs out first.
            let buds = [reading.left, reading.right].compactMap(\.self)
            let percent = reading.single ?? buds.min() ?? reading.caseLevel ?? 0
            return PeripheralBattery(
                id: reading.address, name: reading.name, kind: SensorKeys.peripheralKind(forProduct: reading.name),
                percent: Double(percent)
            )
        }
        lastBluetooth = (now, peripherals)
        return peripherals
    }

    private func discoverIfNeeded() {
        guard !discovered else {
            return
        }
        discovered = true
        smc = SMC()
        guard let smc else {
            Self.log.notice("AppleSMC unavailable; temperatures from HID only, no fans")
            return
        }
        discover(smc, useCache: true)
    }

    /// Listing every SMC key takes ~120 ms at launch, so the groups it yields are kept per Mac
    /// model, macOS build and chip (`SensorKeyCache`), and listed again only when those change or
    /// a cached key stops reading (D-086).
    private func discover(_ smc: SMC, useCache: Bool) {
        let identity = SensorKeyCache.Identity.current(chip: chip)
        if useCache, let cached = keyCache?.groups(for: identity) {
            groups = cached
            groupsFromCache = true
            Self.log.info("SMC: cached groups \(cached.map(\.id))")
        } else {
            let keys = smc.allKeys()
            groups = SensorKeys.groups(availableKeys: keys, family: SensorKeys.family(forChip: chip))
            groupsFromCache = false
            keyCache?.store(groups, for: identity)
            Self.log.info("SMC: \(keys.count) keys, groups \(self.groups.map(\.id))")
        }
        fanCount = min(8, Int(smc.value("FNum") ?? 0))
        for index in 0 ..< fanCount {
            fanLimits[index] = (smc.value("F\(index)Mn"), smc.value("F\(index)Mx"))
        }
    }

    /// Every SMC key with its type and decoded value, for the "discover keys" debug command
    /// (spec 6.10). Slow (~1 s); never called by the sampling loop.
    public func discoverKeys() -> [(key: String, type: String, value: Double?)] {
        guard let smc = smc ?? SMC() else {
            return []
        }
        return smc.allKeys().compactMap { key in
            smc.read(key).map { (key, $0.type, SensorKeys.decode(type: $0.type, bytes: $0.bytes)) }
        }
    }

    private static func brandString() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return ""
        }
        return String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
    }
}

/// Magic Mouse, Keyboard, and Trackpad batteries from IORegistry `BatteryPercent` (public).
enum PeripheralBatteries {
    /// Each service with a battery, and its Bluetooth address when it has one (D-165).
    static func read() -> [PeripheralMerge.HIDReading] {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [PeripheralMerge.HIDReading] = []
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let percent = property(service, "BatteryPercent") as? NSNumber,
                  let product = property(service, "Product") as? String
            else {
                continue
            }
            let serial = property(service, "SerialNumber") as? String ?? product
            result.append(PeripheralMerge.HIDReading(
                battery: PeripheralBattery(
                    id: serial, name: product, kind: SensorKeys.peripheralKind(forProduct: product), percent: percent.doubleValue
                ),
                address: property(service, "DeviceAddress") as? String
            ))
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
