import Core
import Darwin
import Foundation

/// Simulators and emulators (1.4, D-226): every iOS, watchOS, tvOS and visionOS Simulator device
/// and Android emulator on this Mac, read from their own files (no Xcode or Android Studio
/// needed), with what the running ones hold and the space each takes.
public struct DevDevice: Sendable, Hashable, Identifiable {
    public enum Platform: String, Sendable, Hashable {
        case iOS, watchOS, tvOS, visionOS, android
    }

    /// The Simulator UDID, or the Android AVD's name.
    public let id: String
    public let name: String
    public let platform: Platform
    /// "iOS 27.0", "Android 15".
    public let runtime: String?
    /// The device's folder: its apps and data, its disk images.
    public let folder: String
    public var sizeBytes: UInt64?
    public let lastUsed: Date?
    /// The device's processes: `launchd_sim` and everything under it, or the emulator's qemu.
    public let pids: [Int32]
    public let memoryBytes: UInt64
    public let cpuSeconds: Double
    public let startedAt: Date?

    public var isRunning: Bool {
        !pids.isEmpty
    }

    /// What shuts it down, for the user to run. An emulator quits like an app instead.
    public var shutdownCommand: String? {
        platform == .android ? nil : "xcrun simctl shutdown \(id)"
    }

    /// What removes a Simulator device and its apps' data for good.
    public var deleteCommand: String? {
        platform == .android ? nil : "xcrun simctl delete \(id)"
    }

    public init(
        id: String, name: String, platform: Platform, runtime: String?, folder: String, sizeBytes: UInt64? = nil, lastUsed: Date? = nil,
        pids: [Int32] = [], memoryBytes: UInt64 = 0, cpuSeconds: Double = 0, startedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.runtime = runtime
        self.folder = folder
        self.sizeBytes = sizeBytes
        self.lastUsed = lastUsed
        self.pids = pids
        self.memoryBytes = memoryBytes
        self.cpuSeconds = cpuSeconds
        self.startedAt = startedAt
    }
}

/// One reading: the devices, and whether the Simulator app is open (a booted device without it
/// is one left running), from the same walk of the process table.
public struct DevDeviceReading: Sendable, Hashable {
    public let devices: [DevDevice]
    public let simulatorAppOpen: Bool

    public init(devices: [DevDevice], simulatorAppOpen: Bool) {
        self.devices = devices
        self.simulatorAppOpen = simulatorAppOpen
    }
}

public protocol DevDeviceSource: Sendable {
    /// Every device; `sizes` also measures each one's folder, which takes a while with many.
    func read(sizes: Bool) async -> DevDeviceReading
}

/// Pure rules over plist dictionaries, ini text and the process table.
public enum DevDeviceRules {
    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → (.iOS, "iOS 27.0"); visionOS is "xrOS" there.
    public static func runtime(_ identifier: String) -> (platform: DevDevice.Platform, name: String)? {
        guard let last = identifier.split(separator: ".").last else {
            return nil
        }
        let parts = last.split(separator: "-")
        guard let first = parts.first else {
            return nil
        }
        let platform: DevDevice.Platform? = switch first {
        case "iOS": .iOS
        case "watchOS": .watchOS
        case "tvOS": .tvOS
        case "xrOS", "visionOS": .visionOS
        default: nil
        }
        guard let platform else {
            return nil
        }
        let version = parts.dropFirst().joined(separator: ".")
        return (platform, version.isEmpty ? platform.rawValue : "\(platform.rawValue) \(version)")
    }

    /// A Simulator device from its device.plist; nil for one Xcode marked deleted.
    public static func simulator(_ plist: [String: Any], folder: String) -> DevDevice? {
        guard let udid = plist["UDID"] as? String, let name = plist["name"] as? String, plist["isDeleted"] as? Bool != true else {
            return nil
        }
        let runtime = (plist["runtime"] as? String).flatMap(Self.runtime)
        return DevDevice(
            id: udid, name: name, platform: runtime?.platform ?? .iOS, runtime: runtime?.name, folder: folder,
            lastUsed: plist["lastUsedAt"] as? Date ?? plist["lastBootedAt"] as? Date
        )
    }

    /// `key=value` lines of an AVD's config.ini.
    public static func ini(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return values
    }

    /// Every AVD: each `<name>.ini` in the AVD folder, whose `path=` says where its folder is
    /// (anywhere, once moved), and any `<name>.avd` folder there without one.
    public static func avdFolders(
        in root: String, entries: (String) -> [String], read: (String) -> String?
    ) -> [(name: String, folder: String)] {
        let names = entries(root)
        var found: [String: String] = [:]
        for entry in names where entry.hasSuffix(".ini") {
            let name = String(entry.dropLast(".ini".count))
            if let path = read(root + "/" + entry).map(ini)?["path"], path.hasPrefix("/") {
                found[name] = path
            }
        }
        for entry in names where entry.hasSuffix(".avd") {
            let name = String(entry.dropLast(".avd".count))
            if found[name] == nil {
                found[name] = root + "/" + entry
            }
        }
        return found.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    /// Android API levels Google names; others show as "API 37".
    static let androidVersions = [29: "10", 30: "11", 31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16"]

    /// An emulator from its config.ini: its display name, and the Android version from the
    /// system image path ("system-images/android-35/google_apis/arm64-v8a/").
    public static func emulator(avdName: String, config: [String: String], folder: String) -> DevDevice {
        let image = config["image.sysdir.1"] ?? ""
        let level = image.split(separator: "/").first { $0.hasPrefix("android-") }.flatMap { Int($0.dropFirst("android-".count)) }
        let runtime = level.map { androidVersions[$0].map { "Android \($0)" } ?? "API \(level ?? 0)" }
        return DevDevice(
            id: avdName, name: config["avd.ini.displayname"] ?? avdName.replacingOccurrences(of: "_", with: " "),
            platform: .android, runtime: runtime, folder: folder
        )
    }

    /// A process for matching devices to what runs them.
    public struct Process: Sendable, Hashable {
        public let pid: Int32
        public let parentPID: Int32
        public let name: String
        public let arguments: [String]

        public init(pid: Int32, parentPID: Int32, name: String, arguments: [String]) {
            self.pid = pid
            self.parentPID = parentPID
            self.name = name
            self.arguments = arguments
        }
    }

    /// A booted Simulator device's processes: the `launchd_sim` whose bootstrap path names its
    /// UDID, and every process under it.
    public static func simulatorProcesses(udid: String, in table: [Process]) -> [Int32] {
        guard let root = table.first(where: { $0.name == "launchd_sim" && $0.arguments.contains { $0.contains("/" + udid + "/") } }) else {
            return []
        }
        return descendants(of: root.pid, in: table)
    }

    /// A running emulator's processes: the qemu started with `-avd <name>`, and its children.
    public static func emulatorProcesses(avdName: String, in table: [Process]) -> [Int32] {
        guard let qemu = table.first(where: { process in
            process.name.hasPrefix("qemu-system") && zip(process.arguments, process.arguments.dropFirst())
                .contains { $0 == "-avd" && $1 == avdName }
        }) else {
            return []
        }
        return descendants(of: qemu.pid, in: table)
    }

    /// Running first, then the most recently used.
    public static func order(_ lhs: DevDevice, _ rhs: DevDevice) -> Bool {
        if lhs.isRunning != rhs.isRunning {
            return lhs.isRunning
        }
        let left = lhs.lastUsed ?? .distantPast
        let right = rhs.lastUsed ?? .distantPast
        return left != right ? left > right : lhs.name < rhs.name
    }

    static func descendants(of root: Int32, in table: [Process]) -> [Int32] {
        descendants(of: [root], in: table.map { ($0.pid, $0.parentPID) })
    }

    /// The roots and every process under them, roots first.
    static func descendants(of roots: [Int32], in table: [(pid: Int32, parent: Int32)]) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for process in table {
            children[process.parent, default: []].append(process.pid)
        }
        var found = roots
        var index = 0
        while index < found.count {
            found += children[found[index]] ?? []
            index += 1
        }
        return found
    }

    /// Running with nothing to do: up an hour or more and, between two readings, under 1% of a
    /// core. Or a Simulator device booted with the Simulator app closed.
    public static func isLeftRunning(
        _ device: DevDevice, previousCPU: Double?, interval: TimeInterval, simulatorAppOpen: Bool, now: Date
    ) -> Bool {
        guard device.isRunning else {
            return false
        }
        // Booted without the Simulator app: left running, once it has been up 10 minutes. An
        // `xcodebuild test` boots devices headless for a run that soon ends.
        if device.platform != .android, !simulatorAppOpen {
            return device.startedAt.map { now.timeIntervalSince($0) >= 600 } ?? false
        }
        guard let startedAt = device.startedAt, now.timeIntervalSince(startedAt) >= 3600, let previousCPU, interval > 0 else {
            return false
        }
        // Less processor time than last read means its processes changed (a child quit): unknown.
        let used = device.cpuSeconds - previousCPU
        return used >= 0 && used / interval * 100 < 1
    }
}

public struct LiveDevDevices: DevDeviceSource {
    private let home: String
    private let measure: @Sendable (String) -> UInt64?

    /// `measure` sizes a folder (Storage's allocated-size scan).
    public init(home: String = NSHomeDirectory(), measure: @escaping @Sendable (String) -> UInt64?) {
        self.home = home
        self.measure = measure
    }

    public func read(sizes: Bool) async -> DevDeviceReading {
        let home = home
        let measure: (@Sendable (String) -> UInt64?)? = sizes ? measure : nil
        return await Task.detached(priority: .utility) { () -> DevDeviceReading in
            Self.read(home: home, measure: measure)
        }.value
    }

    static func read(home: String, measure: ((String) -> UInt64?)?) -> DevDeviceReading {
        let found = simulators(home: home) + emulators(home: home)
        // No devices, no process table to walk.
        guard !found.isEmpty else {
            return DevDeviceReading(devices: [], simulatorAppOpen: false)
        }
        let table = table()
        let devices = found.map { device in
            let pids = device.platform == .android
                ? DevDeviceRules.emulatorProcesses(avdName: device.id, in: table)
                : DevDeviceRules.simulatorProcesses(udid: device.id, in: table)
            var memory: UInt64 = 0
            var cpu = 0.0
            for pid in pids {
                if let usage = ProcessInspector.usage(pid) {
                    memory &+= usage.footprint
                    cpu += usage.cpu.seconds
                }
            }
            return DevDevice(
                id: device.id, name: device.name, platform: device.platform, runtime: device.runtime, folder: device.folder,
                sizeBytes: measure?(device.folder), lastUsed: device.lastUsed, pids: pids, memoryBytes: memory, cpuSeconds: cpu,
                startedAt: pids.first.flatMap { ProcessInspector.basics($0)?.startedAt }
            )
        }
        return DevDeviceReading(
            devices: devices.sorted(by: DevDeviceRules.order),
            simulatorAppOpen: table.contains { $0.name == "Simulator" }
        )
    }

    static func simulators(home: String) -> [DevDevice] {
        let root = home + "/Library/Developer/CoreSimulator/Devices"
        return ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).compactMap { name in
            let folder = root + "/" + name
            guard let plist = NSDictionary(contentsOfFile: folder + "/device.plist") as? [String: Any] else {
                return nil
            }
            return DevDeviceRules.simulator(plist, folder: folder)
        }
    }

    static func emulators(home: String) -> [DevDevice] {
        DevDeviceRules.avdFolders(
            in: home + "/.android/avd",
            entries: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
            read: {
                try? String(contentsOfFile: $0, encoding: .utf8)
            }
        )
        .map { name, folder in
            let config = (try? String(contentsOfFile: folder + "/config.ini", encoding: .utf8)).map(DevDeviceRules.ini) ?? [:]
            let device = DevDeviceRules.emulator(avdName: name, config: config, folder: folder)
            // The emulator touches its folder's files each time it runs.
            let date = (try? FileManager.default.attributesOfItem(atPath: folder))?[.modificationDate] as? Date
            return DevDevice(id: device.id, name: device.name, platform: .android, runtime: device.runtime, folder: folder, lastUsed: date)
        }
    }

    static func table() -> [DevDeviceRules.Process] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: max(capacity, 64))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else {
            return []
        }
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 1, let identity = ProcessInspector.identity(pid) else {
                return nil
            }
            // Arguments only where they name the device: one read each, not one per process.
            let wantsArguments = identity.name == "launchd_sim" || identity.name.hasPrefix("qemu-system")
            return DevDeviceRules.Process(
                pid: pid, parentPID: identity.parentPID, name: identity.name,
                arguments: wantsArguments ? ProcessInspector.arguments(pid) : []
            )
        }
    }
}

public struct SimulatedDevDevices: DevDeviceSource {
    private let now: Date

    public init(now: Date = Date()) {
        self.now = now
    }

    public func read(sizes: Bool) async -> DevDeviceReading {
        DevDeviceReading(devices: devices(sizes: sizes), simulatorAppOpen: false)
    }

    private func devices(sizes: Bool) -> [DevDevice] {
        let sims = "/Users/demo/Library/Developer/CoreSimulator/Devices/"
        return [
            DevDevice(
                id: "8F1C2D3E-0000-4000-8000-000000000001", name: "iPhone 17 Pro", platform: .iOS, runtime: "iOS 27.0",
                folder: sims + "8F1C2D3E-0000-4000-8000-000000000001", sizeBytes: sizes ? 3_100_000_000 : nil, lastUsed: now,
                pids: Array(900 ... 1020), memoryBytes: 1_900_000_000, cpuSeconds: 340, startedAt: now.addingTimeInterval(-5 * 3600)
            ),
            DevDevice(
                id: "Pixel_9_API_35", name: "Pixel 9 API 35", platform: .android, runtime: "Android 15",
                folder: "/Users/demo/.android/avd/Pixel_9_API_35.avd", sizeBytes: sizes ? 9_800_000_000 : nil,
                lastUsed: now.addingTimeInterval(-4 * 86400)
            ),
            DevDevice(
                id: "8F1C2D3E-0000-4000-8000-000000000002", name: "iPad Air 13-inch (M3)", platform: .iOS, runtime: "iOS 26.0",
                folder: sims + "8F1C2D3E-0000-4000-8000-000000000002", sizeBytes: sizes ? 2_400_000_000 : nil,
                lastUsed: now.addingTimeInterval(-120 * 86400)
            ),
            DevDevice(
                id: "8F1C2D3E-0000-4000-8000-000000000003", name: "Apple Watch Series 11 (46mm)", platform: .watchOS,
                runtime: "watchOS 26.0", folder: sims + "8F1C2D3E-0000-4000-8000-000000000003", sizeBytes: sizes ? 900_000_000 : nil
            ),
        ]
    }
}
