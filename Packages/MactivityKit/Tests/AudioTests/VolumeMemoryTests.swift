@testable import Audio
import Core
import Foundation
import Testing

@Suite("Remembered per-app settings")
struct VolumeMemoryTests {
    @Test("Setting, changing, and returning to 100% on the default")
    func lifecycle() {
        var memory = VolumeMemory()
        let changed1 = memory.setVolume(0.5, for: "app")
        #expect(changed1)
        #expect(memory.setting(for: "app").volume == 0.5)
        let changed2 = memory.setVolume(0.5, for: "app")
        #expect(!changed2)
        let changed3 = memory.setVolume(1, for: "app")
        #expect(changed3)
        #expect(!memory.remembers("app"))
        #expect(memory.setting(for: "app") == .untouched)
    }

    @Test("Mute keeps the level; unmuting restores it")
    func mute() {
        var memory = VolumeMemory()
        memory.setVolume(0.4, for: "app")
        let changed1 = memory.setMuted(true, for: "app")
        #expect(changed1)
        #expect(memory.setting(for: "app") == AudioAppSetting(volume: 0.4, isMuted: true))
        #expect(memory.setting(for: "app").effectiveVolume == 0)
        let changed2 = memory.setMuted(true, for: "app")
        #expect(!changed2)
        let changed3 = memory.setMuted(false, for: "app")
        #expect(changed3)
        #expect(memory.setting(for: "app") == AudioAppSetting(volume: 0.4))
    }

    @Test("Muting an untouched app remembers it; unmuting at 100% forgets it again")
    func muteAtFull() {
        var memory = VolumeMemory()
        memory.setMuted(true, for: "app")
        #expect(memory.remembers("app"))
        #expect(memory.setting(for: "app").volume == 1)
        memory.setMuted(false, for: "app")
        #expect(!memory.remembers("app"))
    }

    @Test("Moving the level unmutes, like the system volume")
    func levelUnmutes() {
        var memory = VolumeMemory()
        memory.setVolume(0.4, for: "app")
        memory.setMuted(true, for: "app")
        memory.setVolume(0.7, for: "app")
        #expect(memory.setting(for: "app") == AudioAppSetting(volume: 0.7))
    }

    @Test("An output device alone is remembered, even at 100%; an empty UID is the default")
    func device() {
        var memory = VolumeMemory()
        let changed1 = memory.setOutputDevice("airpods", for: "app")
        #expect(changed1)
        #expect(memory.setting(for: "app") == AudioAppSetting(outputDeviceUID: "airpods"))
        let changed2 = memory.setOutputDevice("", for: "app")
        #expect(changed2)
        #expect(!memory.remembers("app"))
        let changed3 = memory.setOutputDevice(nil, for: "app")
        #expect(!changed3)
    }

    @Test("Reset forgets everything about the app, and only that app")
    func reset() {
        var memory = VolumeMemory()
        memory.setVolume(0.2, for: "a")
        memory.setMuted(true, for: "a")
        memory.setOutputDevice("airpods", for: "a")
        memory.setVolume(0.3, for: "b")
        let changed1 = memory.forget("a")
        #expect(changed1)
        let changed2 = memory.forget("a")
        #expect(!changed2)
        #expect(memory.setting(for: "a") == .untouched)
        #expect(memory.setting(for: "b").volume == 0.3)
    }

    @Test(
        "Clamping",
        arguments: [(-1.0, 0.0), (0.0, 0.0), (0.5, 0.5), (1.0, 1.0), (1.5, 1.0), (Double.nan, 1.0), (-Double.infinity, 0.0)]
    )
    func clamp(volume: Double, expected: Double) {
        #expect(VolumeMemory.clamp(volume) == expected)
    }

    @Test("NaN never mutes; a negative level is 0")
    func edgeValues() {
        var memory = VolumeMemory()
        let changed1 = memory.setVolume(.nan, for: "a")
        #expect(!changed1)
        memory.setVolume(-3, for: "a")
        #expect(memory.setting(for: "a").volume == 0)
    }

    @Test("Round trip through the store; pid keys and untouched entries aren't saved")
    func persistence() throws {
        var memory = VolumeMemory()
        memory.setVolume(0.25, for: "com.apple.Music")
        memory.setOutputDevice("airpods", for: "/usr/bin/afplay")
        memory.setMuted(true, for: "pid:77")
        let data = try #require(memory.encoded())
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("pid:77"))
        let decoded = VolumeMemory.decoded(from: data)
        #expect(decoded.settings.count == 2)
        #expect(decoded.setting(for: "com.apple.Music").volume == 0.25)
        #expect(decoded.setting(for: "/usr/bin/afplay").outputDeviceUID == "airpods")
    }

    @Test("Bad or hand-edited data decodes safely: out-of-range levels clamp, untouched entries drop, junk is empty")
    func badData() {
        #expect(VolumeMemory.decoded(from: nil) == VolumeMemory())
        #expect(VolumeMemory.decoded(from: Data("not json".utf8)) == VolumeMemory())
        let edited = Data(#"""
        {"a": {"volume": 7, "isMuted": false}, "b": {"volume": -2, "isMuted": false}, "c": {"volume": 1, "isMuted": false}}
        """#.utf8)
        let memory = VolumeMemory.decoded(from: edited)
        #expect(!memory.remembers("a"))
        #expect(memory.setting(for: "b").volume == 0)
        #expect(!memory.remembers("c"))
    }

    @Test("The in-memory store keeps what it's given")
    func inMemoryStore() {
        let store = AudioSettingsStore.inMemory()
        #expect(store.load() == nil)
        store.save(Data("x".utf8))
        #expect(store.load() == Data("x".utf8))
        store.save(nil)
        #expect(store.load() == nil)
    }
}
