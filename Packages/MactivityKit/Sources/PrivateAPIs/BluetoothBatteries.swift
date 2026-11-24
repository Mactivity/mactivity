import CoreBluetooth
import Foundation
import IOBluetooth
import os

/// AirPods and other Bluetooth accessory batteries (spec 5.6).
public enum BluetoothBatteries {
    public struct Reading: Hashable, Sendable {
        public let address: String
        public let name: String
        /// Present for single-battery devices.
        public let single: Int?
        public let left: Int?
        public let right: Int?
        public let caseLevel: Int?
    }

    private static let log = Logger(subsystem: "app.mactivity.privateapis", category: "bluetooth")

    /// Private `IOBluetoothDevice` properties.
    ///
    /// - Symbols: `-[IOBluetoothDevice batteryPercentSingle]`, `batteryPercentLeft`,
    ///   `batteryPercentRight`, `batteryPercentCase` (IOBluetooth.framework; the class and
    ///   `pairedDevices` are public, these getters aren't in its headers).
    /// - If Apple removes them: `responds(to:)` is false, the device reads as no battery, and
    ///   AirPods drop out of the Battery tab. Magic devices still come from IORegistry.
    static let selectors = ["batteryPercentSingle", "batteryPercentLeft", "batteryPercentRight", "batteryPercentCase"]

    /// True once the user has allowed Bluetooth. Reading the status never prompts.
    public static var isAuthorized: Bool {
        CBManager.authorization == .allowedAlways
    }

    /// Connected devices that report at least one battery level.
    ///
    /// Touching IOBluetooth needs Bluetooth permission. Without `NSBluetoothAlwaysUsageDescription`
    /// in the bundle, macOS kills the process, so this returns [] there (tests, CLI tools). Before
    /// the user has answered the prompt, `pairedDevices` blocks the calling (main) thread until
    /// they do, so it returns [] until access is granted; the app asks explicitly instead.
    @MainActor
    public static func read(bundle: Bundle = .main, isAuthorized: @autoclosure () -> Bool = isAuthorized) -> [Reading] {
        guard mayRead(
            hasUsageString: bundle.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil,
            isAuthorized: isAuthorized
        ) else {
            return []
        }
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.compactMap { device in
            guard device.isConnected() else {
                return nil
            }
            let levels = selectors.map { level(of: device, $0) }
            return reading(
                address: device.addressString ?? device.nameOrAddress ?? "?", name: device.nameOrAddress ?? "Bluetooth device",
                levels: levels
            )
        }
    }

    /// Pure: both the usage string and granted access, checked in that order (reading the status
    /// without the usage string is itself unsafe).
    static func mayRead(hasUsageString: Bool, isAuthorized: () -> Bool) -> Bool {
        hasUsageString && isAuthorized()
    }

    /// Pure: a reading from the four raw levels (0 means "not reported").
    static func reading(address: String, name: String, levels: [Int?]) -> Reading? {
        let valid = levels.map { level -> Int? in
            guard let level, (1 ... 100).contains(level) else {
                return nil
            }
            return level
        }
        guard valid.contains(where: { $0 != nil }), valid.count == 4 else {
            return nil
        }
        return Reading(address: address, name: name, single: valid[0], left: valid[1], right: valid[2], caseLevel: valid[3])
    }

    private static func level(of device: IOBluetoothDevice, _ name: String) -> Int? {
        let selector = NSSelectorFromString(name)
        guard device.responds(to: selector) else {
            return nil
        }
        return (device.value(forKey: name) as? NSNumber)?.intValue
    }
}
