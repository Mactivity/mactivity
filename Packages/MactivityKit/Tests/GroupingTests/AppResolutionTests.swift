import Core
import Foundation
@testable import Grouping
import Testing

private struct ProcessTreeFixture: Decodable {
    struct Process: Decodable {
        let pid: Int32
        let parentPID: Int32
        let uid: UInt32
        let name: String
        let executablePath: String
    }

    struct App: Decodable {
        let pid: Int32
        let bundleID: String
        let name: String
        let bundlePath: String
        let isRegular: Bool
    }

    struct Bundle: Decodable {
        let path: String
        let bundleID: String
        let name: String
    }

    let processes: [Process]
    let responsible: [String: Int32]
    let runningApps: [App]
    let bundles: [Bundle]

    var readings: [ProcessReading] {
        processes.map {
            ProcessReading(
                pid: $0.pid, parentPID: $0.parentPID, uid: $0.uid, name: $0.name, executablePath: $0.executablePath,
                startTime: Date(timeIntervalSince1970: 0), cpuTime: .zero, footprintBytes: 0, diskReadBytes: 0,
                diskWriteBytes: 0, energyNJ: 0, isComplete: $0.uid != 0
            )
        }
    }
}

@Suite("App resolution")
struct AppResolutionTests {
    private let fixture: ProcessTreeFixture
    private let resolved: [Int32: AppIdentity]

    init() throws {
        fixture = try Fixtures.load("process-tree.json")
        resolved = Self.resolve(fixture, responsible: true)
    }

    private static func resolve(_ fixture: ProcessTreeFixture, responsible: Bool) -> [Int32: AppIdentity] {
        let readings = fixture.readings
        let responsibleMap = responsible
            ? Dictionary(uniqueKeysWithValues: fixture.responsible.compactMap { key, value in Int32(key).map { ($0, value) } })
            : [:]
        let running = Dictionary(uniqueKeysWithValues: fixture.runningApps.map {
            ($0.pid, RunningApp(pid: $0.pid, bundleID: $0.bundleID, name: $0.name, bundlePath: $0.bundlePath, isRegular: $0.isRegular))
        })
        let bundles = Dictionary(uniqueKeysWithValues: fixture.bundles.map {
            ($0.path, BundleInfo(path: $0.path, bundleID: $0.bundleID, name: $0.name))
        })
        return AppResolution.resolve(
            readings, all: Dictionary(uniqueKeysWithValues: readings.map { ($0.pid, $0) }),
            responsible: responsibleMap, runningApps: running, bundleAt: { bundles[$0] }, ownUID: 501
        )
    }

    @Test("Every process resolves")
    func complete() {
        #expect(resolved.count == fixture.processes.count)
    }

    @Test("Shell children group under the terminal, as a terminal")
    func terminal() {
        #expect(resolved[302]?.id == "com.apple.Terminal")
        #expect(resolved[302]?.kind == .terminal)
        #expect(resolved[301]?.kind == .terminal)
    }

    @Test("Nested helper apps group under the outermost app")
    func helper() {
        #expect(resolved[401]?.id == "com.tinyspeck.slackmacgap")
    }

    @Test("XPC services go to their responsible app")
    func xpc() {
        #expect(resolved[500]?.id == "com.apple.Safari")
    }

    @Test("Root daemons and system agents are macOS")
    func system() {
        #expect(resolved[600]?.kind == .system)
        #expect(resolved[700]?.kind == .system)
        #expect(resolved[901]?.kind == .system)
        #expect(resolved[900]?.kind == .system)
    }

    @Test("Regular system apps keep their identity")
    func finder() {
        #expect(resolved[1000]?.id == "com.apple.finder")
    }

    @Test("A running helper app nested in another bundle belongs to the outer app")
    func nestedRunningApp() {
        #expect(resolved[1100]?.id == "com.1password.1password")
    }

    @Test("Unresolvable user processes are Other, by executable name")
    func other() {
        #expect(resolved[800]?.id == "other:mytool")
        #expect(resolved[800]?.kind == .other)
    }

    @Test("Without the private API, the parent walk still groups helpers and shells")
    func fallback() {
        let walked = Self.resolve(fixture, responsible: false)
        #expect(walked[401]?.id == "com.tinyspeck.slackmacgap")
        #expect(walked[302]?.id == "com.apple.Terminal")
        // The XPC service has no parent link to Safari; it lands in macOS by its system path.
        #expect(walked[500]?.kind == .system)
    }

    @Test("Outermost .app bundle", arguments: [
        ("/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", "/Applications/Slack.app"),
        ("/Applications/Xcode.app", "/Applications/Xcode.app"),
        ("/usr/bin/zsh", nil),
    ] as [(String, String?)])
    func outermost(path: String, expected: String?) {
        #expect(AppResolution.outermostAppBundle(in: path) == expected)
    }
}

@Suite("Owned paths (D-106)")
struct OwnedPathTests {
    private func reading(_ pid: Int32, parent: Int32, name: String, path: String) -> ProcessReading {
        ProcessReading(
            pid: pid, parentPID: parent, uid: 501, name: name, executablePath: path,
            startTime: Date(timeIntervalSince1970: 0), cpuTime: .zero, footprintBytes: 0, diskReadBytes: 0,
            diskWriteBytes: 0, energyNJ: 0, isComplete: true
        )
    }

    @Test("The Simulator's services and a simulated device's processes are Simulator, not apps of their own")
    func simulator() {
        let framework = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices"
        let trampoline = reading(
            10, parent: 1, name: "SimulatorTrampoline", path: "\(framework)/SimulatorTrampoline.xpc/Contents/MacOS/SimulatorTrampoline"
        )
        let service = reading(
            11,
            parent: 1,
            name: "CoreSimulatorService",
            path: "\(framework)/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/"
                + "com.apple.CoreSimulator.CoreSimulatorService"
        )
        let device = reading(
            12,
            parent: 1,
            name: "SpringBoard",
            path: "/Library/Developer/CoreSimulator/Volumes/iOS_23A/Library/RuntimeRoot/"
                + "System/Library/CoreServices/SpringBoard.app/SpringBoard"
        )
        let readings = [trampoline, service, device]
        // As on a real Mac, the trampoline also shows up as a running (background) app.
        let running: [Int32: RunningApp] = [10: RunningApp(
            pid: 10, bundleID: "com.apple.CoreSimulator.SimulatorTrampoline", name: "SimulatorTrampoline",
            bundlePath: "\(framework)/SimulatorTrampoline.xpc", isRegular: false
        )]
        let resolved = AppResolution.resolve(
            readings, all: Dictionary(uniqueKeysWithValues: readings.map { ($0.pid, $0) }),
            responsible: [:], runningApps: running, bundleAt: { _ in nil }, ownUID: 501
        )
        #expect(Set(resolved.values.map(\.id)) == ["com.apple.iphonesimulator"])
        #expect(resolved[10]?.name == "Simulator")
    }

    @Test("Xcode's device services are Xcode; an app's widget extension is its app (D-111)")
    func xcodeAndExtensions() {
        let device = reading(
            20, parent: 1, name: "CoreDeviceService",
            path: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/XPCServices/"
                + "CoreDeviceService.xpc/Contents/MacOS/CoreDeviceService"
        )
        let widget = reading(
            21, parent: 1, name: "ExcelWidget_mac",
            path: "/Applications/Microsoft Excel.app/Contents/PlugIns/ExcelWidget_mac.appex/Contents/MacOS/ExcelWidget_mac"
        )
        let readings = [device, widget]
        let resolved = AppResolution.resolve(
            readings, all: Dictionary(uniqueKeysWithValues: readings.map { ($0.pid, $0) }),
            responsible: [:], runningApps: [:],
            bundleAt: { $0 == "/Applications/Microsoft Excel.app"
                ? BundleInfo(path: $0, bundleID: "com.microsoft.Excel", name: "Microsoft Excel") : nil
            },
            ownUID: 501
        )
        #expect(resolved[20]?.id == "com.apple.dt.Xcode")
        #expect(resolved[21]?.name == "Microsoft Excel")
    }

    @Test("A bundle named only by its bundle ID shows its file name (D-111)")
    func bundleNames() {
        let service = "/Library/X.framework/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc"
        #expect(AppResolution.bundleName(
            displayName: nil, name: "com.apple.CoreSimulator.CoreSimulatorService",
            bundleID: "com.apple.CoreSimulator.CoreSimulatorService", path: service
        ) == "CoreSimulatorService")
        #expect(AppResolution.bundleName(
            displayName: nil, name: "com.example.Helper", bundleID: "com.example.Helper", path: "/Applications/Helper Tool.app"
        ) == "Helper Tool")
        #expect(AppResolution.bundleName(
            displayName: "Excel", name: "Microsoft Excel", bundleID: "com.microsoft.Excel", path: "/Applications/Microsoft Excel.app"
        ) == "Excel")
        #expect(AppResolution.bundleName(displayName: "", name: nil, bundleID: nil, path: "/Applications/Thing.app") == "Thing")
    }

    @Test("Another signed-in person's Slack is Other users, not this user's Slack (D-221)")
    func otherUsers() {
        let mine = ProcessReading(
            pid: 40, parentPID: 1, uid: 501, name: "Slack", executablePath: "/Applications/Slack.app/Contents/MacOS/Slack",
            startTime: Date(timeIntervalSince1970: 0), cpuTime: .zero, footprintBytes: 0, diskReadBytes: 0,
            diskWriteBytes: 0, energyNJ: 0, isComplete: true
        )
        let theirs = ProcessReading(
            pid: 41, parentPID: 1, uid: 502, name: "Slack", executablePath: "/Applications/Slack.app/Contents/MacOS/Slack",
            startTime: Date(timeIntervalSince1970: 0), cpuTime: .zero, footprintBytes: 0, diskReadBytes: 0,
            diskWriteBytes: 0, energyNJ: 0, isComplete: true
        )
        let nobody = ProcessReading(
            pid: 42, parentPID: 1, uid: UInt32(bitPattern: -2), name: "helper", executablePath: "/usr/libexec/helper",
            startTime: Date(timeIntervalSince1970: 0), cpuTime: .zero, footprintBytes: 0, diskReadBytes: 0,
            diskWriteBytes: 0, energyNJ: 0, isComplete: true
        )
        let readings = [mine, theirs, nobody]
        let resolved = AppResolution.resolve(
            readings, all: Dictionary(uniqueKeysWithValues: readings.map { ($0.pid, $0) }),
            responsible: [:], runningApps: [:],
            bundleAt: { $0 == "/Applications/Slack.app" ? BundleInfo(path: $0, bundleID: "com.tinyspeck.slackmacgap", name: "Slack") : nil
            },
            ownUID: 501
        )
        #expect(resolved[40]?.id == "com.tinyspeck.slackmacgap")
        #expect(resolved[41] == .otherUsers)
        #expect(resolved[41]?.kind == .system)
        #expect(resolved[42] == .system)
    }
}
