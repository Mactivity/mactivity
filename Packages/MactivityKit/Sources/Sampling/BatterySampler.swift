import Core
import Foundation
import IOKit
import IOKit.ps

/// Charge, source, and time remaining from IOKit power sources (`IOPSCopyPowerSourcesInfo`), plus
/// cycle count, health, and power draw from the `AppleSmartBattery` IORegistry entry (spec 6.10).
/// Public API only.
public actor BatterySampler: BatterySource {
    /// Runs on the shared sampling thread (D-022).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        SamplingExecutor.shared.asUnownedSerialExecutor()
    }

    private let matching: CFDictionary?
    /// The smart battery entry, retained for the sampler's lifetime once found.
    private var smartBattery: io_service_t?
    /// Health keys, reused between reads (`BatteryData` is a nested dictionary copied per read).
    private var health: (properties: [String: Any], readAt: ContinuousClock.Instant)?
    static let healthLifetime: Duration = .seconds(300)
    private let clock = ContinuousClock()
    /// The battery pack entry, where the M5 Pro under macOS 27 keeps `Temperature` (D-275).
    private let packMatching: CFDictionary?
    private var pack: io_service_t?
    /// Read at most this often: 19 µs a read here, and History keeps minutes.
    static let temperatureLifetime: Duration = .seconds(60)
    private var temperature: (raw: Any?, readAt: ContinuousClock.Instant)?
    /// The IOPS description is an XPC round trip to powerd. powerd posts
    /// `kIOPSNotifyAnyPowerSource` whenever any power source's description changes (charge,
    /// source, time remaining), so it's read again only then, or after `powerSourceMaxAge` (D-086).
    private let powerSourceChange = NotifyWatch(kIOPSNotifyAnyPowerSource)
    private var powerSource: (description: [String: Any]?, readAt: ContinuousClock.Instant)?
    static let powerSourceMaxAge: Duration = .seconds(60)

    public init() {
        matching = IORegistry.matching("AppleSmartBattery")
        packMatching = IORegistry.matching("AppleSmartBatteryPack")
    }

    deinit {
        if let smartBattery {
            IOObjectRelease(smartBattery)
        }
        if let pack {
            IOObjectRelease(pack)
        }
    }

    public func sample() async throws -> BatteryStats? {
        guard let powerSource = cachedBatteryDescription() else {
            return nil
        }
        return BatteryMath.stats(powerSource: powerSource, smartBattery: smartBatteryProperties())
    }

    private func cachedBatteryDescription() -> [String: Any]? {
        let now = clock.now
        let posted = powerSourceChange.posted()
        if let powerSource, !NotifyWatch.needsRead(posted: posted, lastRead: powerSource.readAt, now: now, maxAge: Self.powerSourceMaxAge) {
            return powerSource.description
        }
        let description = internalBatteryDescription()
        powerSource = (description, now)
        return description
    }

    /// The IOPS description of the internal battery; nil on a Mac without one.
    private func internalBatteryDescription() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return nil
        }
        for source in list {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               BatteryMath.isInternalBattery(description) {
                return description
            }
        }
        return nil
    }

    /// Just the keys `BatteryMath` needs. The entry also holds large blobs (port controller logs,
    /// IOReport legends) that fetching every property would copy on each call.
    private func smartBatteryProperties() -> [String: Any]? {
        if smartBattery == nil, let matching {
            smartBattery = IORegistry.firstService(matching: matching)
        }
        guard let smartBattery else {
            return nil
        }
        let now = clock.now
        var properties: [String: Any] = [:]
        if let health, now - health.readAt < Self.healthLifetime {
            properties = health.properties
        } else {
            for key in BatteryMath.smartBatteryHealthKeys {
                properties[key] = IORegistry.property(smartBattery, key)
            }
            health = properties.isEmpty ? nil : (properties, now)
        }
        var answered = false
        for key in BatteryMath.smartBatteryPowerKeys {
            if let value = IORegistry.property(smartBattery, key) {
                properties[key] = value
                answered = true
            }
        }
        guard answered || health != nil, !properties.isEmpty else {
            // The entry stopped answering; find it again next time.
            IOObjectRelease(smartBattery)
            self.smartBattery = nil
            health = nil
            return nil
        }
        // Where a Mac publishes it beside the rest, that's the one; otherwise the pack's.
        if BatteryMath.temperatureCelsius(properties) == nil, let raw = packTemperature(now: now) {
            properties["Temperature"] = raw
        }
        return properties
    }

    /// `Temperature` from the battery pack's `BatteryData`, for a Mac without the top-level key,
    /// reread once a minute. Nil where there's no such entry or key.
    private func packTemperature(now: ContinuousClock.Instant) -> Any? {
        if let temperature, now - temperature.readAt < Self.temperatureLifetime {
            return temperature.raw
        }
        if pack == nil, let packMatching {
            pack = IORegistry.firstService(matching: packMatching)
        }
        var raw: Any?
        if let pack {
            raw = (IORegistry.property(pack, "BatteryData") as? [String: Any])?["Temperature"]
        }
        temperature = (raw, now)
        return raw
    }
}
