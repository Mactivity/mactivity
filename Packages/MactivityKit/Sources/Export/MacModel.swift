import Darwin
import Foundation
import IOKit

/// The Mac's marketing name and chip, for the share card's caption. Public IOKit and sysctl only.
public enum MacModel {
    /// Marketing name, e.g. "MacBook Pro", from IORegistry (`IODeviceTree:/product` "product-name",
    /// or IOPlatformExpertDevice "model") or `sysctl hw.model`. Falls back to "Mac".
    public static func name() -> String {
        if let productName = registryString(path: "IODeviceTree:/product", key: "product-name"),
           let name = marketingName(fromProductName: productName) {
            return name
        }
        for identifier in [platformModel(), sysctlString("hw.model")].compactMap(\.self) {
            if let family = family(fromModelIdentifier: identifier) {
                return family
            }
        }
        Log.export.notice("No marketing name for this Mac; using the fallback")
        return fallbackName
    }

    /// `machdep.cpu.brand_string`, e.g. "Apple M5 Pro". Falls back to the device tree's
    /// "product-soc-name", then to "Apple silicon".
    public static func chip() -> String {
        if let brand = sysctlString("machdep.cpu.brand_string") {
            return brand
        }
        if let soc = registryString(path: "IODeviceTree:/product", key: "product-soc-name") {
            return soc
        }
        Log.export.notice("No chip name for this Mac; using the fallback")
        return fallbackChip
    }

    static let fallbackName = "Mac"
    static let fallbackChip = "Apple silicon"

    /// "MacBook Pro (14-inch, M5 Pro)" → "MacBook Pro". The chip has its own caption, and the
    /// size and year would make the card read like a spec sheet.
    static func marketingName(fromProductName productName: String) -> String? {
        let base = productName.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return nonEmpty(base.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "MacBookPro18,3" → "MacBook Pro". Newer identifiers such as "Mac17,9" name no family, so
    /// they return nil and the caller falls back.
    static func family(fromModelIdentifier identifier: String) -> String? {
        families[String(identifier.prefix { !$0.isNumber && $0 != "," })]
    }

    private static let families: [String: String] = [
        "MacBookPro": "MacBook Pro",
        "MacBookAir": "MacBook Air",
        "MacBook": "MacBook",
        "Macmini": "Mac mini",
        "MacPro": "Mac Pro",
        "iMac": "iMac",
        "iMacPro": "iMac Pro",
    ]

    // MARK: Readers

    private static func nonEmpty(_ string: String) -> String? {
        string.isEmpty ? nil : string
    }

    /// IOPlatformExpertDevice "model", e.g. "Mac17,9".
    private static func platformModel() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOObjectRelease(service) }
        return string(from: service, key: "model")
    }

    private static func registryString(path: String, key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOObjectRelease(entry) }
        return string(from: entry, key: key)
    }

    /// Device-tree properties are NUL-terminated bytes in a `CFData`; service properties are
    /// usually a `CFString`. Accepts either.
    private static func string(from entry: io_registry_entry_t, key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        else {
            return nil
        }
        if let data = value as? Data {
            return String(bytes: data.prefix { $0 != 0 }, encoding: .utf8).flatMap(nonEmpty)
        }
        return (value as? String).flatMap(nonEmpty)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8).flatMap(nonEmpty)
    }
}
