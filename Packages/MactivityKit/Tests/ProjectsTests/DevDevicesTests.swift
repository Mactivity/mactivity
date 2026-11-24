import Foundation
@testable import Projects
import Testing

/// Simulators and emulators (D-226).
struct DevDevicesTests {
    @Test("Runtimes from CoreSimulator identifiers")
    func runtimes() {
        #expect(DevDeviceRules.runtime("com.apple.CoreSimulator.SimRuntime.iOS-27-0")?.name == "iOS 27.0")
        #expect(DevDeviceRules.runtime("com.apple.CoreSimulator.SimRuntime.xrOS-26-1")?.platform == .visionOS)
        #expect(DevDeviceRules.runtime("com.apple.CoreSimulator.SimRuntime.watchOS-26-0")?.name == "watchOS 26.0")
        #expect(DevDeviceRules.runtime("something.else") == nil)
    }

    @Test("A device.plist as on this Mac; deleted ones are left out")
    func simulator() {
        let used = Date(timeIntervalSince1970: 1_790_000_000)
        let plist: [String: Any] = [
            "UDID": "00000000-0000-4000-8000-0000000000A1", "name": "iPhone Air", "state": 1, "isDeleted": false,
            "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "lastUsedAt": used,
        ]
        let device = DevDeviceRules.simulator(plist, folder: "/d")
        #expect(device?.name == "iPhone Air" && device?.runtime == "iOS 27.0" && device?.lastUsed == used)
        #expect(device?.shutdownCommand == "xcrun simctl shutdown 00000000-0000-4000-8000-0000000000A1")
        var deleted = plist
        deleted["isDeleted"] = true
        #expect(DevDeviceRules.simulator(deleted, folder: "/d") == nil)
    }

    @Test("An AVD's name and Android version from its config.ini")
    func emulator() {
        let config = DevDeviceRules.ini("""
        avd.ini.displayname=Pixel 9 API 35
        image.sysdir.1 = system-images/android-35/google_apis/arm64-v8a/
        hw.ramSize=2048
        """)
        let device = DevDeviceRules.emulator(avdName: "Pixel_9_API_35", config: config, folder: "/a")
        #expect(device.name == "Pixel 9 API 35")
        #expect(device.runtime == "Android 15")
        #expect(device.shutdownCommand == nil)
        #expect(DevDeviceRules.emulator(avdName: "Odd_One", config: [:], folder: "/a").name == "Odd One")
    }

    @Test("AVDs from their .ini files, wherever path= puts them")
    func avdFolders() {
        let files = [
            "/h/.android/avd/Pixel_9.ini": "avd.ini.encoding=UTF-8\npath=/Volumes/Fast/avd/Pixel_9.avd\ntarget=android-35",
            "/h/.android/avd/Tablet.ini": "path.rel=avd/Tablet.avd",
        ]
        let found = DevDeviceRules.avdFolders(
            in: "/h/.android/avd", entries: { _ in ["Pixel_9.ini", "Tablet.ini", "Tablet.avd", "Old.avd"] }, read: { files[$0] }
        )
        #expect(found.map(\.name) == ["Old", "Pixel_9", "Tablet"])
        #expect(found.first { $0.name == "Pixel_9" }?.folder == "/Volumes/Fast/avd/Pixel_9.avd")
        #expect(found.first { $0.name == "Tablet" }?.folder == "/h/.android/avd/Tablet.avd")
    }

    @Test("Less processor time than the last read isn't idle")
    func childQuit() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let device = DevDevice(
            id: "x",
            name: "Pixel",
            platform: .android,
            runtime: nil,
            folder: "/",
            pids: [1],
            cpuSeconds: 10,
            startedAt: now - 7200
        )
        #expect(!DevDeviceRules.isLeftRunning(device, previousCPU: 40, interval: 10, simulatorAppOpen: true, now: now))
    }

    @Test("A booted device's processes: its launchd_sim and everything under it")
    func processes() {
        let udid = "00000000-0000-4000-8000-0000000000A1"
        let table: [DevDeviceRules.Process] = [
            .init(pid: 100, parentPID: 1, name: "launchd_sim", arguments: [
                "launchd_sim", "/Users/a/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist",
            ]),
            .init(pid: 101, parentPID: 100, name: "SpringBoard", arguments: []),
            .init(pid: 102, parentPID: 101, name: "MyApp", arguments: []),
            .init(pid: 200, parentPID: 1, name: "launchd_sim", arguments: ["launchd_sim", "/Users/a/.../Devices/OTHER/data/x"]),
            .init(pid: 300, parentPID: 299, name: "qemu-system-aarch64", arguments: ["qemu-system-aarch64", "-avd", "Pixel_9_API_35"]),
        ]
        #expect(DevDeviceRules.simulatorProcesses(udid: udid, in: table) == [100, 101, 102])
        #expect(DevDeviceRules.emulatorProcesses(avdName: "Pixel_9_API_35", in: table) == [300])
        #expect(DevDeviceRules.emulatorProcesses(avdName: "Pixel", in: table).isEmpty)
    }

    @Test("Left running: booted with the Simulator app closed, or up an hour doing nothing")
    func leftRunning() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let sim = DevDevice(
            id: "x",
            name: "iPhone",
            platform: .iOS,
            runtime: nil,
            folder: "/",
            pids: [1],
            cpuSeconds: 100,
            startedAt: now - 7200
        )
        #expect(DevDeviceRules.isLeftRunning(sim, previousCPU: nil, interval: 0, simulatorAppOpen: false, now: now))
        // An `xcodebuild test` boots one headless for a few minutes: not yet.
        let testRun = DevDevice(
            id: "t",
            name: "iPhone",
            platform: .iOS,
            runtime: nil,
            folder: "/",
            pids: [3],
            cpuSeconds: 5,
            startedAt: now - 300
        )
        #expect(!DevDeviceRules.isLeftRunning(testRun, previousCPU: nil, interval: 0, simulatorAppOpen: false, now: now))
        #expect(!DevDeviceRules.isLeftRunning(sim, previousCPU: 50, interval: 30, simulatorAppOpen: true, now: now))
        #expect(DevDeviceRules.isLeftRunning(sim, previousCPU: 99.9, interval: 30, simulatorAppOpen: true, now: now))
        let fresh = DevDevice(
            id: "y",
            name: "Pixel",
            platform: .android,
            runtime: nil,
            folder: "/",
            pids: [2],
            cpuSeconds: 10,
            startedAt: now - 600
        )
        #expect(!DevDeviceRules.isLeftRunning(fresh, previousCPU: 10, interval: 30, simulatorAppOpen: false, now: now))
    }
}
