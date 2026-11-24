@testable import Audio
import Core
import Testing

struct DeviceTimelineFixture: Decodable {
    struct Timeline: Decodable, CustomTestStringConvertible {
        let name: String
        let setting: AudioAppSetting
        let steps: [Step]

        var testDescription: String {
            name
        }
    }

    struct Step: Decodable {
        let event: String
        let defaultUID: String
        let available: [String]
        let action: String
        let deviceUID: String?
        let gain: Double?

        var devices: TapPlanner.Devices {
            TapPlanner.Devices(defaultUID: defaultUID, available: Set(available))
        }

        /// The tap left after this step.
        var rig: RigSpec? {
            deviceUID.map { RigSpec(gain: Float(gain ?? 1), deviceUID: $0) }
        }
    }

    let timelines: [Timeline]

    static func load() -> [Timeline] {
        (try? Fixtures.load("audio-device-timelines.json", as: DeviceTimelineFixture.self).timelines) ?? []
    }
}

@Suite("Tap planning and device fallback")
struct TapPlannerTests {
    private let speakers = TapPlanner.Devices(defaultUID: "speakers", available: ["speakers", "airpods"])

    @Test("Device timelines: plug, unplug, and default changes", arguments: DeviceTimelineFixture.load())
    func timeline(_ timeline: DeviceTimelineFixture.Timeline) {
        var current: RigSpec?
        for step in timeline.steps {
            let desired = TapPlanner.desired(timeline.setting, devices: step.devices)
            let action = TapPlanner.action(current: current, desired: desired)
            let name = switch action {
            case .none: "none"
            case .install: "install"
            case .update: "update"
            case .move: "move"
            case .remove: "remove"
            }
            #expect(name == step.action, "\(step.event)")
            if case let .update(gain) = action, let rig = current {
                current = RigSpec(gain: gain, deviceUID: rig.deviceUID)
            } else if case .none = action {
                // unchanged
            } else {
                current = desired
            }
            #expect(current == step.rig, "\(step.event)")
        }
    }

    @Test("The fixture has timelines")
    func fixtureLoads() {
        #expect(DeviceTimelineFixture.load().count >= 4)
    }

    @Test("Untouched needs no tap; below 100%, muted, or another device does")
    func whoNeedsATap() {
        #expect(TapPlanner.desired(.untouched, devices: speakers) == nil)
        #expect(TapPlanner.desired(AudioAppSetting(volume: 0.5), devices: speakers) == RigSpec(gain: 0.5, deviceUID: "speakers"))
        #expect(TapPlanner.desired(AudioAppSetting(isMuted: true), devices: speakers) == RigSpec(gain: 0, deviceUID: "speakers"))
        #expect(
            TapPlanner.desired(AudioAppSetting(outputDeviceUID: "airpods"), devices: speakers)
                == RigSpec(gain: 1, deviceUID: "airpods")
        )
        // Choosing the device that's already the default is the same as following it.
        #expect(TapPlanner.desired(AudioAppSetting(outputDeviceUID: "speakers"), devices: speakers) == nil)
    }

    @Test("Mute keeps the level; unmuting brings the gain back")
    func muteIsNotZero() {
        let muted = AudioAppSetting(volume: 0.6, isMuted: true)
        #expect(TapPlanner.desired(muted, devices: speakers)?.gain == 0)
        var unmuted = muted
        unmuted.isMuted = false
        #expect(TapPlanner.desired(unmuted, devices: speakers)?.gain == Float(0.6))
    }

    @Test("Actions between two taps")
    func actions() {
        let half = RigSpec(gain: 0.5, deviceUID: "speakers")
        #expect(TapPlanner.action(current: nil, desired: nil) == .none)
        #expect(TapPlanner.action(current: nil, desired: half) == .install(half))
        #expect(TapPlanner.action(current: half, desired: nil) == .remove)
        #expect(TapPlanner.action(current: half, desired: half) == .none)
        #expect(TapPlanner.action(current: half, desired: RigSpec(gain: 0.2, deviceUID: "speakers")) == .update(gain: 0.2))
        let moved = RigSpec(gain: 0.2, deviceUID: "airpods")
        #expect(TapPlanner.action(current: half, desired: moved) == .move(moved))
        #expect(TapPlanner.action(current: half, desired: half, force: true) == .move(half))
        // Forcing never builds a tap nobody needs.
        #expect(TapPlanner.action(current: nil, desired: nil, force: true) == .none)
    }

    @Test("A chosen device that isn't connected resolves to the default")
    func fallback() {
        #expect(TapPlanner.target(chosen: nil, devices: speakers) == "speakers")
        #expect(TapPlanner.target(chosen: "airpods", devices: speakers) == "airpods")
        #expect(TapPlanner.target(chosen: "usb-dac", devices: speakers) == "speakers")
    }
}

@Suite("What to reapply")
struct ReapplyPlannerTests {
    private let memory = VolumeMemory(settings: [
        "com.spotify.client": AudioAppSetting(volume: 0.5),
        "/usr/bin/afplay": AudioAppSetting(isMuted: true),
    ])
    /// Spotify has two processes (one playing), afplay one (quiet), Safari one (playing, never changed).
    private let keys: [Int32: String] = [
        10: "com.spotify.client", 11: "com.spotify.client", 20: "/usr/bin/afplay", 30: "com.apple.Safari",
    ]

    @Test("Off: only tapped processes are watched, and nothing is reapplied")
    func off() {
        #expect(ReapplyPlanner.watched(keys: keys, memory: memory, tapped: [30], enabled: false) == [30])
        #expect(ReapplyPlanner.watched(keys: keys, memory: memory, tapped: [], enabled: false).isEmpty)
        #expect(ReapplyPlanner.toApply(keys: keys, running: [10, 30], memory: memory, tapped: [], blocked: [], enabled: false).isEmpty)
    }

    @Test("On: every live process of a remembered app is watched; playing ones without a tap are reapplied")
    func on() {
        #expect(ReapplyPlanner.watched(keys: keys, memory: memory, tapped: [], enabled: true) == [10, 11, 20])
        #expect(ReapplyPlanner.toApply(keys: keys, running: [10, 30], memory: memory, tapped: [], blocked: [], enabled: true) == [10])
        // Already tapped, or blocked for lack of consent: left alone.
        #expect(ReapplyPlanner.toApply(keys: keys, running: [10, 11], memory: memory, tapped: [10], blocked: [11], enabled: true).isEmpty)
    }

    @Test("A tapped process that exited isn't watched")
    func exited() {
        #expect(ReapplyPlanner.watched(keys: keys, memory: memory, tapped: [99], enabled: true) == [10, 11, 20])
    }

    @Test("Relaunch: settings saved by one session reapply in the next, by app, whatever the new pids are")
    func relaunch() {
        let store = AudioSettingsStore.inMemory()
        var first = VolumeMemory()
        first.setVolume(0.3, for: "com.spotify.client")
        first.setOutputDevice("airpods", for: "com.spotify.client")
        first.setMuted(true, for: "/usr/bin/afplay")
        first.setVolume(0.2, for: "pid:4242")
        store.save(first.encoded())

        let second = VolumeMemory.decoded(from: store.load())
        #expect(second.setting(for: "com.spotify.client") == AudioAppSetting(volume: 0.3, outputDeviceUID: "airpods"))
        #expect(second.setting(for: "/usr/bin/afplay").isMuted)
        // Pid keys name a process from the old session; they're never saved.
        #expect(!second.remembers("pid:4242"))

        let relaunched: [Int32: String] = [700: "com.spotify.client", 800: "/usr/bin/afplay", 900: "pid:4242"]
        let apply = ReapplyPlanner.toApply(
            keys: relaunched, running: [700, 800, 900], memory: second, tapped: [], blocked: [], enabled: true
        )
        #expect(apply == [700, 800])
        let devices = TapPlanner.Devices(defaultUID: "speakers", available: ["speakers", "airpods"])
        #expect(TapPlanner.desired(second.setting(for: "com.spotify.client"), devices: devices) == RigSpec(gain: 0.3, deviceUID: "airpods"))
        #expect(TapPlanner.desired(second.setting(for: "/usr/bin/afplay"), devices: devices) == RigSpec(gain: 0, deviceUID: "speakers"))
    }
}
