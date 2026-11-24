import Core
import Foundation
import IOKit

/// Loads the Energy Impact weights macOS ships for this Mac (public files in
/// `/usr/share/pmenergy`): `<board-id>.plist` on Intel, `default.plist` on Apple silicon.
public enum EnergyCoefficientsLoader {
    public static let current: EnergyCoefficients = load(directory: URL(fileURLWithPath: "/usr/share/pmenergy"), boardID: boardID())

    static func load(directory: URL, boardID: String?) -> EnergyCoefficients {
        let names = [boardID.map { "\($0).plist" }, "default.plist"].compactMap(\.self)
        for name in names {
            let url = directory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let coefficients = EnergyCoefficients(plist: plist) {
                return coefficients
            }
        }
        return .builtIn
    }

    private static func boardID() -> String? {
        let platform = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platform != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOObjectRelease(platform) }
        guard let data = IORegistryEntryCreateCFProperty(platform, "board-id" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
        else {
            return nil
        }
        return String(bytes: data.prefix { $0 != 0 }, encoding: .utf8)
    }
}
