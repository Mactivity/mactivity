import Darwin
import Foundation

/// Discovered SMC sensor groups, kept in UserDefaults between launches (D-086). Valid for one Mac
/// model, macOS build, and chip: a macOS update can bring SMC firmware with different keys, and
/// `SensorSampler` also discovers again when a cached key doesn't read.
public struct SensorKeyCache: @unchecked Sendable {
    /// What the cached keys were discovered on.
    public struct Identity: Hashable, Sendable, Codable {
        public let model: String
        public let osBuild: String
        public let chip: String

        public init(model: String, osBuild: String, chip: String) {
            self.model = model
            self.osBuild = osBuild
            self.chip = chip
        }

        static func current(chip: String) -> Identity {
            Identity(model: sysctlString("hw.model"), osBuild: sysctlString("kern.osversion"), chip: chip)
        }

        private static func sysctlString(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
                return ""
            }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
                return ""
            }
            return String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
        }
    }

    private struct Entry: Codable {
        let identity: Identity
        let groups: [SensorKeys.Group]
    }

    static let defaultsKey = "sensorKeyCache"

    /// UserDefaults is thread-safe.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The cached groups if they were discovered on `identity`. An empty cached list counts too:
    /// a Mac whose SMC has no temperature keys needn't list them every launch.
    public func groups(for identity: Identity) -> [SensorKeys.Group]? {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.identity == identity
        else {
            return nil
        }
        return entry.groups
    }

    public func store(_ groups: [SensorKeys.Group], for identity: Identity) {
        guard let data = try? JSONEncoder().encode(Entry(identity: identity, groups: groups)) else {
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
