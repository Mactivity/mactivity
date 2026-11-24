import Foundation
import os

/// Apple silicon temperature sensors through the HID event system (spec 6.10).
public enum HIDTemperatures {
    private static let log = Logger(subsystem: "app.mactivity.privateapis", category: "hid")

    typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    struct Functions {
        let create: CreateClient
        let setMatching: SetMatching
        let copyServices: CopyServices
        let copyProperty: CopyProperty
        let copyEvent: CopyEvent
        let getFloat: GetFloat
    }

    /// Resolved once with `dlsym`.
    ///
    /// - Symbols: `IOHIDEventSystemClientCreate`, `IOHIDEventSystemClientSetMatching`,
    ///   `IOHIDEventSystemClientCopyServices`, `IOHIDServiceClientCopyProperty`,
    ///   `IOHIDServiceClientCopyEvent`, `IOHIDEventGetFloatValue`.
    /// - Framework: IOKit (exported, not in the public headers).
    /// - If Apple removes them: this returns nil and `read` returns nil. Mactivity's primary
    ///   source is the SMC (public IOKit calls), so only Macs whose SMC exposes no CPU keys
    ///   lose the CPU temperature.
    static let functions: Functions? = {
        guard let handle = dlopen(nil, RTLD_NOW) else {
            return nil
        }
        func resolve<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = resolve("IOHIDEventSystemClientCreate", as: CreateClient.self),
              let setMatching = resolve("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = resolve("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = resolve("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let copyEvent = resolve("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let getFloat = resolve("IOHIDEventGetFloatValue", as: GetFloat.self)
        else {
            log.notice("HID temperature symbols unavailable")
            return nil
        }
        return Functions(
            create: create,
            setMatching: setMatching,
            copyServices: copyServices,
            copyProperty: copyProperty,
            copyEvent: copyEvent,
            getFloat: getFloat
        )
    }()

    public static var isAvailable: Bool {
        functions != nil
    }

    /// Readings from sensors whose product name starts with `prefix` (e.g. "PMU tdie"), keyed by
    /// name. Each read is a round trip to the HID server (~1 ms per sensor), so callers ask for
    /// a narrow prefix. Nil when the private API is unavailable.
    public static func read(prefix: String, limit: Int = 8) -> [String: Double]? {
        read(prefix: prefix, limit: limit, using: functions)
    }

    /// Testable seam: pass nil to exercise the fallback.
    static func read(prefix: String, limit: Int, using functions: Functions?) -> [String: Double]? {
        guard let functions, let client = functions.create(kCFAllocatorDefault)?.takeRetainedValue() else {
            return nil
        }
        // Usage page 0xFF00, usage 5: Apple vendor temperature sensors.
        functions.setMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = functions.copyServices(client)?.takeRetainedValue() as? [AnyObject] else {
            return [:]
        }
        let temperatureEvent: Int64 = 15
        var readings: [String: Double] = [:]
        for service in services where readings.count < limit {
            guard let name = functions.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  name.hasPrefix(prefix), readings[name] == nil,
                  let event = functions.copyEvent(service, temperatureEvent, 0, 0)?.takeRetainedValue()
            else {
                continue
            }
            readings[name] = functions.getFloat(event, Int32(temperatureEvent << 16))
        }
        return readings
    }
}
