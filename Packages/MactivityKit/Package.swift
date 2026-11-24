// swift-tools-version: 6.2
import PackageDescription

/// Swift 6 language mode from M4 on (D-003, D-023).
let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

/// A library target at `Sources/<name>`, with a test target at `Tests/<name>Tests` once it has code.
struct Module {
    let name: String
    let dependencies: [String]
    var products: [Target.Dependency] = []
    var hasTests = false
    /// Extra targets only the tests link, e.g. UI's end-to-end stop test uses the real terminator.
    var testDependencies: [String] = []
    /// Has user-facing text: a `Localizable.xcstrings` at `Sources/<name>`, looked up through
    /// `Bundle.strings` (docs/localization/README.md).
    var isLocalized = false
}

/// Dependency direction is one way: UI → (History, Alerts, …) → Grouping → Sampling → Core.
/// Simulated depends on Core only. PrivateAPIs depends on Core only and is imported by the targets that need it.
/// History and Alerts only need Core: they work on snapshots, not on the grouping machinery.
let modules: [Module] = [
    Module(name: "Core", dependencies: [], hasTests: true, isLocalized: true),
    Module(name: "PrivateAPIs", dependencies: ["Core"], hasTests: true),
    Module(name: "Simulated", dependencies: ["Core"], hasTests: true),
    Module(name: "Sampling", dependencies: ["Core", "PrivateAPIs"], hasTests: true),
    Module(name: "Grouping", dependencies: ["Core", "Sampling", "PrivateAPIs"], hasTests: true, testDependencies: ["Projects"]),
    Module(
        name: "History",
        dependencies: ["Core"],
        products: [.product(name: "GRDB", package: "GRDB.swift")],
        hasTests: true
    ),
    Module(name: "Alerts", dependencies: ["Core"], hasTests: true, isLocalized: true),
    // Simulated: its process details take their PIDs from the simulated catalog.
    Module(name: "Projects", dependencies: ["Core", "PrivateAPIs", "Simulated"], hasTests: true, isLocalized: true),
    Module(name: "Sensors", dependencies: ["Core", "PrivateAPIs", "CDriveHealth"], hasTests: true),
    Module(name: "Audio", dependencies: ["Core"], hasTests: true, isLocalized: true),
    Module(name: "Export", dependencies: ["Core"], hasTests: true, isLocalized: true),
    Module(name: "Storage", dependencies: ["Core"], hasTests: true, isLocalized: true),
    Module(name: "Startup", dependencies: ["Core"], hasTests: true, isLocalized: true),
    Module(name: "Docker", dependencies: ["Core"], hasTests: true),
    // Who can do what (1.9, D-261): security settings, permissions, system and browser extensions.
    // Named Protections: Apple's Security framework already has the name.
    Module(name: "Protections", dependencies: ["Core", "PrivateAPIs"], hasTests: true),
    // Compact, pure readings of a snapshot for the CLI, App Intents, and widgets (E6, E7).
    // Core only, so the sandboxed widget extension links nothing that samples.
    Module(name: "Readouts", dependencies: ["Core"], hasTests: true, isLocalized: true),
    Module(
        name: "UI",
        dependencies: ["Core", "Simulated", "Export", "Projects", "Storage", "Startup", "Docker"],
        hasTests: true,
        isLocalized: true
    ),
]

let package = Package(
    name: "MactivityKit",
    // English is the development language: every String Catalog's source strings are English.
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: modules.map { .library(name: $0.name, targets: [$0.name]) } + [
        // `mactivity top --memory --json` (expansion E6).
        .executable(name: "mactivity", targets: ["MactivityCLI"]),
    ],
    dependencies: [
        // Approved dependency (CLAUDE.md rule 6): SQLite for the history store.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MactivityCLI",
            dependencies: ["Core", "Sampling", "Grouping", "Projects", "Readouts", "History"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "MactivityCLITests",
            dependencies: ["MactivityCLI", "Core", "Readouts"],
            swiftSettings: settings
        ),
        // NVMe SMART through IOKit's public header, which Swift can't import (D-157).
        .target(
            name: "CDriveHealth",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
    ] + modules.flatMap { module -> [Target] in
        let library = Target.target(
            name: module.name,
            dependencies: module.dependencies.map { .target(name: $0) } + module.products,
            resources: module.isLocalized ? [.process("Localizable.xcstrings")] : nil,
            swiftSettings: settings
        )
        guard module.hasTests else {
            return [library]
        }
        return [
            library,
            .testTarget(
                name: "\(module.name)Tests",
                dependencies: ([module.name] + (module.name == "Simulated" ? [] : ["Simulated"]) + module.testDependencies)
                    .map { .target(name: $0) },
                swiftSettings: settings
            ),
        ]
    }
)
