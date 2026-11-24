import Core
import Foundation

/// The fake Mac that every simulated source describes: which apps run, how many processes
/// each has, and roughly how heavy each one is.
public enum SimulatedCatalog {
    public struct AppProfile: Sendable {
        public let identity: AppIdentity
        public let processNames: [String]
        /// Share of total CPU this app tends to use, 0...1.
        public let cpuWeight: Double
        public let memoryBytes: UInt64
        public let diskWriteBPS: Double
        public let netInBPS: Double
    }

    public static let apps: [AppProfile] = [
        profile(
            "com.apple.Safari",
            "Safari",
            ["Safari", "Safari Networking", "Safari Web Content", "Safari Web Content"],
            cpu: 0.16,
            memoryGB: 2.1,
            diskWrite: 40000,
            netIn: 180_000
        ),
        profile(
            "com.apple.podcasts",
            "Podcasts",
            ["Podcasts", "PodcastsAuthAgent", "com.apple.WebKit.WebContent"],
            cpu: 0.05,
            memoryGB: 0.7,
            diskWrite: 12000,
            netIn: 24000,
            path: "/System/Applications/Podcasts.app"
        ),
        profile(
            "com.apple.dt.Xcode",
            "Xcode",
            ["Xcode", "SourceKitService", "swift-frontend", "XCBBuildService"],
            cpu: 0.22,
            memoryGB: 3.3,
            diskWrite: 900_000,
            netIn: 2000
        ),
        profile(
            "com.microsoft.VSCode",
            "Code",
            ["Code", "Code Helper", "Code Helper (Plugin)", "Code Helper (Renderer)"],
            cpu: 0.07,
            memoryGB: 1.1,
            diskWrite: 30000,
            netIn: 8000,
            path: "/Applications/Visual Studio Code.app"
        ),
        terminal(
            "com.apple.Terminal",
            "Terminal",
            ["Terminal", "zsh", "node", "node", "python3"],
            cpu: 0.12,
            memoryGB: 0.9
        ),
        profile(
            "com.apple.Music",
            "Music",
            ["Music", "AMPLibraryAgent", "AMPArtworkAgent"],
            cpu: 0.03,
            memoryGB: 0.5,
            diskWrite: 60000,
            netIn: 40000,
            path: "/System/Applications/Music.app"
        ),
        profile(
            "com.apple.finder", "Finder", ["Finder"], cpu: 0.01, memoryGB: 0.2, diskWrite: 1000, netIn: 0,
            path: "/System/Library/CoreServices/Finder.app"
        ),
        AppProfile(
            identity: .system, processNames: ["kernel_task", "WindowServer", "mds_stores", "launchd"],
            cpuWeight: 0.14, memoryBytes: gigabytes(2.6), diskWriteBPS: 150_000, netInBPS: 3000
        ),
    ]

    /// `path` is where the app lives, so its real icon shows: Apple's own apps, which every Mac has,
    /// live outside /Applications.
    private static func profile(
        _ bundleID: String, _ name: String, _ processes: [String],
        cpu: Double, memoryGB: Double, diskWrite: Double, netIn: Double, path: String? = nil
    ) -> AppProfile {
        AppProfile(
            identity: AppIdentity(
                id: bundleID, name: name, bundleID: bundleID, iconKey: path ?? "/Applications/\(name).app", kind: .app
            ),
            processNames: processes, cpuWeight: cpu, memoryBytes: gigabytes(memoryGB),
            diskWriteBPS: diskWrite, netInBPS: netIn
        )
    }

    private static func terminal(
        _ bundleID: String, _ name: String, _ processes: [String], cpu: Double, memoryGB: Double
    ) -> AppProfile {
        AppProfile(
            identity: AppIdentity(
                id: bundleID, name: name, bundleID: bundleID, iconKey: "/System/Applications/Utilities/\(name).app",
                kind: .terminal
            ),
            processNames: processes, cpuWeight: cpu, memoryBytes: gigabytes(memoryGB),
            diskWriteBPS: 20000, netInBPS: 6000
        )
    }

    static func gigabytes(_ value: Double) -> UInt64 {
        UInt64(value * 1_000_000_000)
    }

    /// Stable fake PIDs: app index × 100 + process index + 400.
    static func pid(app appIndex: Int, process processIndex: Int) -> Int32 {
        Int32(400 + appIndex * 100 + processIndex)
    }

    /// One app's PIDs, in `processNames` order; empty for an app that isn't in the catalog.
    public static func pids(of bundleID: String) -> [Int32] {
        guard let index = apps.firstIndex(where: { $0.identity.bundleID == bundleID }) else {
            return []
        }
        return apps[index].processNames.indices.map { pid(app: index, process: $0) }
    }

    /// The simulated Mac: 36 GB, 15 cores in two levels like an M5 Pro.
    public static let totalMemoryBytes: UInt64 = 36 * 1_073_741_824
    public static let topology = CPUTopology.fromPerfLevels([("Super", 5), ("Performance", 10)])
}
