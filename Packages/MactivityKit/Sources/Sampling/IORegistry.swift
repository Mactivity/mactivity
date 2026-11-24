import Foundation
import IOKit

/// Thin wrappers over public IOKit registry calls. Every `io_object_t` these hand to a closure is
/// released when the closure returns; callers never release them, and one that keeps a handle
/// retains its own reference (`DiskSampler`'s drivers).
enum IORegistry {
    /// A matching dictionary for `IOServiceGetMatchingServices`, built once and reused.
    ///
    /// `IOServiceGetMatchingServices` consumes one reference to its dictionary (`CF_RELEASES_ARGUMENT`),
    /// and Swift balances that at the call site, so a cached dictionary survives repeated calls.
    static func matching(_ className: String) -> CFDictionary? {
        IOServiceMatching(className)
    }

    /// Calls `body` with each registered service matching `dictionary`.
    static func forEachService(matching dictionary: CFDictionary, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dictionary, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        forEach(in: iterator, body)
    }

    /// The first registered service matching `dictionary`, retained. The caller owns it and must
    /// `IOObjectRelease` it; this is the one call here that hands out a handle to keep.
    static func firstService(matching dictionary: CFDictionary) -> io_service_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, dictionary)
        return service == IO_OBJECT_NULL ? nil : service
    }

    /// Calls `body` with each direct child of `entry` in the IOService plane.
    static func forEachChild(of entry: io_registry_entry_t, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        forEach(in: iterator, body)
    }

    /// Calls `body` with `entry`'s parent in the IOService plane, if it has one.
    static func withParent<T>(of entry: io_registry_entry_t, _ body: (io_registry_entry_t) -> T?) -> T? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(parent) }
        return body(parent)
    }

    /// One property, bridged to Foundation types (`NSNumber`, `NSString`, `NSDictionary`, `NSArray`).
    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Every property of `entry` in one round trip. Cheaper than several `property` calls when an
    /// entry has only a few small properties, much dearer when it has large ones.
    static func properties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }

    /// The registry's stable 64-bit ID for `entry`, unique for the life of the boot.
    static func entryID(_ entry: io_registry_entry_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS ? id : nil
    }

    private static func forEach(in iterator: io_iterator_t, _ body: (io_object_t) -> Void) {
        var object = IOIteratorNext(iterator)
        while object != IO_OBJECT_NULL {
            body(object)
            IOObjectRelease(object)
            object = IOIteratorNext(iterator)
        }
    }
}

/// Lossless conversions from the loosely typed values IOKit and IOPS dictionaries hold.
enum PropertyValue {
    /// Signed 64-bit, including values IOKit stores as unsigned bit patterns (a negative
    /// `Amperage` can arrive as 18446744073709550116).
    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let int as Int:
            return Int64(int)
        default:
            return nil
        }
    }

    static func uint64(_ value: Any?) -> UInt64? {
        switch value {
        case let number as NSNumber:
            return number.uint64Value
        case let int as Int:
            return int >= 0 ? UInt64(int) : nil
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let int as Int:
            return Double(int)
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber:
            return number.boolValue
        case let bool as Bool:
            return bool
        default:
            return nil
        }
    }
}
