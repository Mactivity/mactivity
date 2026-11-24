import Core
import CoreGraphics
import Foundation
import IOKit

/// The desk from the Mac itself (D-237), all public API: CoreGraphics for displays and their
/// native modes, IORegistry for the lid and each port's state, and `system_profiler` (only for
/// the Devices page, never in the background) for display names and wired devices.
public struct LiveDesk: DeskSource {
    public init() {}

    public func sample(at date: Date) async -> DeskSample {
        let externals = Self.onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 }.map(Self.nativeSize)
        let largest = externals.max { $0.width * $0.height < $1.width * $1.height }
        return DeskSample(
            at: date, externalDisplays: externals.count, largestWidth: largest?.width ?? 0, largestHeight: largest?.height ?? 0,
            lidClosed: Self.lidClosed()
        )
    }

    public func details() async -> DeskDetails {
        await Task.detached(priority: .utility) { () -> DeskDetails in
            let names = DeskParsing.displayNames(Self.profile("SPDisplaysDataType"))
            let ports = Self.ports()
            let ids = Self.onlineDisplays()
            let externals = ids.filter { CGDisplayIsBuiltin($0) == 0 }.count
            let displays = ids.map { id -> DeskDetails.Display in
                let native = Self.nativeSize(id)
                let mode = CGDisplayCopyDisplayMode(id)
                let size = CGDisplayScreenSize(id)
                let inches: Double? = size
                    .width > 0 ? Double((size.width * size.width + size.height * size.height).squareRoot() / 25.4) : nil
                let builtIn = CGDisplayIsBuiltin(id) != 0
                return DeskDetails.Display(
                    id: id, name: names[id] ?? (builtIn ? "Built-in display" : "Display"), isBuiltIn: builtIn,
                    isMain: CGDisplayIsMain(id) != 0,
                    nativeWidth: native.width, nativeHeight: native.height, looksLikeWidth: mode?.width ?? 0,
                    looksLikeHeight: mode?.height ?? 0,
                    refreshRate: mode?.refreshRate ?? 0, inches: inches,
                    connection: builtIn ? nil : DeskParsing.connection(externals: externals, ports: ports),
                    isMirrored: CGDisplayIsInMirrorSet(id) != 0
                )
            }
            let usb = DeskParsing.usbDevices(Self.profile("SPUSBHostDataType"))
            let thunderbolt = DeskParsing.thunderboltDevices(Self.profile("SPThunderboltDataType"))
            return DeskDetails(displays: displays, ports: ports, devices: thunderbolt + usb, lidClosed: Self.lidClosed())
        }.value
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// The panel's own resolution: the mode marked native, not the scaled framebuffer (a 4K
    /// panel set to look like 3360 × 1890 draws 6720 × 3780).
    static func nativeSize(_ id: CGDirectDisplayID) -> (width: Int, height: Int) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        let native = modes.filter { $0.ioFlags & UInt32(kDisplayModeNativeFlag) != 0 }.max { $0.pixelWidth < $1.pixelWidth }
        if let native {
            return (native.pixelWidth, native.pixelHeight)
        }
        let current = CGDisplayCopyDisplayMode(id)
        return (current?.pixelWidth ?? 0, current?.pixelHeight ?? 0)
    }

    /// `AppleClamshellState` on the power manager; nil on a Mac without a lid.
    static func lidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else {
            return nil
        }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return value as? Bool
    }

    /// Each USB-C, MagSafe and HDMI port: connected or not, and what it carries.
    static func ports() -> [DeskDetails.Port] {
        var found: [DeskDetails.Port] = []
        for className in ["AppleHPMInterfaceType10", "AppleHPMInterfaceType11", "AppleHPMInterfaceType12", "AppleHDMIPortController"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                func property(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                if let description = property("Description") as? String ?? property("PortDescription") as? String {
                    found.append(DeskDetails.Port(
                        name: DeskParsing.portName(description),
                        isConnected: property("ConnectionActive") as? Bool ?? false,
                        carries: DeskParsing.carries(property("TransportsActive") as? [String] ?? [])
                    ))
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
        }
        return found.sorted { DeskParsing.portOrder($0.name) < DeskParsing.portOrder($1.name) }
    }

    /// `system_profiler -json <type>`, about 0.2 s; nil if it fails.
    static func profile(_ type: String) -> Any? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "-detailLevel", "mini", type]
        process.environment = ["LANG": "C", "LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/// Pure readings of what the system reports (D-237), tested with fixtures from a real Mac.
public enum DeskParsing {
    /// `_spdisplays_displayID` → `_name`, from `SPDisplaysDataType`.
    public static func displayNames(_ json: Any?) -> [UInt32: String] {
        var names: [UInt32: String] = [:]
        let gpus = (json as? [String: Any])?["SPDisplaysDataType"] as? [[String: Any]] ?? []
        for gpu in gpus {
            for display in gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? [] {
                if let id = (display["_spdisplays_displayID"] as? String).flatMap(UInt32.init), let name = display["_name"] as? String {
                    names[id] = name == "Color LCD" ? "Built-in display" : name
                }
            }
        }
        return names
    }

    /// "Port-USB-C@2" → "USB-C 2", "Port-MagSafe 3@1" → "MagSafe", "Port-HDMI@1" → "HDMI".
    public static func portName(_ description: String) -> String {
        let trimmed = description.hasPrefix("Port-") ? String(description.dropFirst(5)) : description
        let parts = trimmed.split(separator: "@")
        let kind = parts.first.map(String.init) ?? trimmed
        if kind.hasPrefix("MagSafe") {
            return "MagSafe"
        }
        if kind == "HDMI" {
            return "HDMI"
        }
        return parts.count > 1 ? "\(kind) \(parts[1])" : kind
    }

    static func portOrder(_ name: String) -> String {
        name.hasPrefix("USB-C") ? "0" + name : name == "HDMI" ? "1" : "2" + name
    }

    /// From a port's active transports: "DisplayPort" a display, "CIO" Thunderbolt or USB4,
    /// "USB2"/"USB3" a USB device, "CC" alone power.
    public static func carries(_ transports: [String]) -> [DeskPortContent] {
        var carries: [DeskPortContent] = []
        if transports.contains("DisplayPort") {
            carries.append(.display)
        }
        if transports.contains("CIO") {
            carries.append(.thunderbolt)
        }
        if transports.contains(where: { $0.hasPrefix("USB") }) {
            carries.append(.usb)
        }
        if carries.isEmpty, transports.contains("CC") {
            carries.append(.power)
        }
        return carries
    }

    /// How an external display is connected, when it can be told: one display and one port
    /// carrying a display names that port; HDMI's carries only displays. Otherwise nil.
    public static func connection(externals: Int, ports: [DeskDetails.Port]) -> String? {
        let carrying = ports.filter { $0.carries.contains(.display) || $0.carries.contains(.thunderbolt) }
        guard externals == 1, carrying.count == 1, let port = carrying.first else {
            return nil
        }
        if port.name == "HDMI" {
            return "HDMI"
        }
        return port.carries.contains(.thunderbolt) ? "Thunderbolt (\(port.name))" : port.name
    }

    /// Devices on the USB buses (not the buses or hubs' own controllers), from `SPUSBHostDataType`.
    public static func usbDevices(_ json: Any?) -> [DeskDetails.WiredDevice] {
        var devices: [DeskDetails.WiredDevice] = []
        func walk(_ items: [[String: Any]], depth: Int) {
            for item in items {
                if depth > 0, let name = item["_name"] as? String {
                    devices.append(DeskDetails.WiredDevice(
                        name: name, maker: item["USBDeviceKeyVendorName"] as? String,
                        speed: item["USBDeviceKeyLinkSpeed"] as? String, isThunderbolt: false
                    ))
                }
                walk(item["_items"] as? [[String: Any]] ?? [], depth: depth + 1)
            }
        }
        walk((json as? [String: Any])?["SPUSBHostDataType"] as? [[String: Any]] ?? [], depth: 0)
        return devices
    }

    /// Docks and drives on Thunderbolt, from `SPThunderboltDataType`: each bus's devices.
    public static func thunderboltDevices(_ json: Any?) -> [DeskDetails.WiredDevice] {
        let buses = (json as? [String: Any])?["SPThunderboltDataType"] as? [[String: Any]] ?? []
        var devices: [DeskDetails.WiredDevice] = []
        func walk(_ items: [[String: Any]]) {
            for item in items {
                if let name = item["_name"] as? String {
                    devices.append(DeskDetails.WiredDevice(
                        name: name, maker: item["vendor_name_key"] as? String,
                        speed: item["current_speed_key"] as? String ?? item["mode_key"] as? String,
                        isThunderbolt: true
                    ))
                }
                walk(item["_items"] as? [[String: Any]] ?? [])
            }
        }
        for bus in buses {
            walk(bus["_items"] as? [[String: Any]] ?? [])
        }
        return devices
    }
}
