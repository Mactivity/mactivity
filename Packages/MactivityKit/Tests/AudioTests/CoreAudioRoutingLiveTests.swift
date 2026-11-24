@testable import Audio
import Core
import CoreAudio
import Foundation
import Testing

/// A second output device for routing tests on a Mac that has only one: a private aggregate over the default
/// output. Private, so only this test process sees it, and Core Audio destroys it if the test crashes.
struct TestOutputDevice {
    let uid: String
    let id: AudioObjectID

    init(uid: String = "test.mactivity.output.\(UUID().uuidString)") throws {
        self.uid = uid
        id = try Self.create(uid: uid)
    }

    static func create(uid: String) throws -> AudioObjectID {
        let main = try HAL.defaultOutputUID()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mactivity test output",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: main,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: main]],
        ]
        var id = kAudioObjectUnknown
        try HAL.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id))
        return id
    }

    /// Unplugs it, as far as Mactivity can tell.
    func remove() {
        AudioHardwareDestroyAggregateDevice(id)
    }
}

@Suite(
    "Per-app routing and remembering",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil, "needs real Mac hardware: make test-live")
)
struct CoreAudioRoutingLiveTests {
    @Test("Off, nothing listens; on with nothing remembered, only the three system listeners; off again, none")
    func listenersFollowTheFlag() async throws {
        let source = CoreAudioSource()
        #expect(await source.listenerCount == (0, 0))
        _ = try await source.clients()
        #expect(await source.listenerCount == (0, 0))
        await source.setEnabled(true)
        #expect(await source.listenerCount == (3, 0))
        #expect(await source.activeTapCount == 0)
        _ = try await source.clients()
        #expect(await source.listenerCount == (3, 0))
        await source.setEnabled(false)
        #expect(await source.listenerCount == (0, 0))
    }

    @Test("The device list has the default output and no aggregates, Mactivity's own or others")
    func deviceList() async throws {
        let source = CoreAudioSource()
        let devices = try await source.outputDevices()
        #expect(devices.count(where: \.isDefault) == 1)
        #expect(devices.contains { $0.uid == (try? HAL.defaultOutputUID()) })
        #expect(!devices.contains { $0.uid.hasPrefix(HAL.ownDevicePrefix) })
        // Aggregates can't be routed to, so they aren't offered.
        let aggregate = try TestOutputDevice()
        defer { aggregate.remove() }
        #expect(try await !source.outputDevices().contains { $0.uid == aggregate.uid })
        LiveAudio.report("output devices: \(devices.map(\.name).joined(separator: ", "))")
    }

    @Test("A remembered app is watched while it lives, whether or not it plays", .enabled(if: LiveAudio.enabled))
    func watchesRememberedApps() async throws {
        let tone = try LiveAudio.toneFile(seconds: 3)
        defer { try? FileManager.default.removeItem(at: tone) }
        var memory = VolumeMemory()
        memory.setMuted(true, for: "/usr/bin/afplay")
        let source = CoreAudioSource(probeWindow: .seconds(1), store: .inMemory(memory.encoded()))
        await source.setEnabled(true)
        let player = try LiveAudio.play(tone)
        let pid = player.processIdentifier
        // The process-list listener picks afplay up, and the reapply builds its tap without any call from us.
        let tapped = await LiveAudio.waitUntil(timeout: .seconds(3)) {
            await source.status(for: pid) != nil
        }
        LiveAudio.report("remembered afplay (muted) got a tap on its own: \(tapped)")
        if !tapped {
            let seen = try await source.clients().map { "\($0.pid) \($0.settingsKey)" }
            LiveAudio.report("afplay is \(pid); clients: \(seen)")
        }
        #expect(tapped)
        #expect(await source.listenerCount.processes >= 1)
        // Without consent the probe hears silence: the app plays untouched and its row says so.
        let settled = try await LiveAudio.waitUntil(timeout: .seconds(3)) {
            let client = try await LiveAudio.client(for: pid, in: source)
            let muting = await source.status(for: pid)?.isMuting ?? false
            return client?.needsPermission == true || muting
        }
        let client = try await LiveAudio.client(for: pid, in: source)
        await LiveAudio.report("after the probe: needsPermission \(client?.needsPermission ?? false), taps \(source.activeTapCount)")
        #expect(settled)
        #expect(client?.isMuted == true)
        await source.reset()
        #expect(await source.listenerCount == (0, 0))
    }

    @Test("On with nothing tapped costs nothing measurable: listeners only, no polling", .enabled(if: LiveAudio.enabled))
    func idleCost() async throws {
        var memory = VolumeMemory()
        memory.setVolume(0.5, for: "com.example.not-running")
        let source = CoreAudioSource(store: .inMemory(memory.encoded()))
        await source.setEnabled(true)
        let cost = try await LiveAudio.measureCPU(seconds: 3)
        LiveAudio.report(String(format: "feature on, nothing tapped: Mactivity %.3f%% of a core", cost.own))
        #expect(await source.activeTapCount == 0)
        await source.setEnabled(false)
    }

    /// This Mac has one output, and Core Audio won't use an aggregate as another aggregate's main device
    /// (`'!dev'`), so the only second device a test can make is one routing can't use. What this does exercise:
    /// the fallback when the chosen device is missing, the device-list listener, a refused move keeping the
    /// working tap, reset, and the cost of a tap built by the routing path.
    @Test(
        "Chosen device missing: the remembered level applies on the default; a device change keeps the working tap",
        .enabled(if: LiveAudio.enabled)
    )
    func routingFallback() async throws {
        let missing = "test.mactivity.output.\(UUID().uuidString)"
        var memory = VolumeMemory()
        memory.setVolume(0.5, for: "/usr/bin/afplay")
        memory.setOutputDevice(missing, for: "/usr/bin/afplay")
        let source = CoreAudioSource(probeWindow: .seconds(8), store: .inMemory(memory.encoded()))
        await source.setEnabled(true)
        let tone = try LiveAudio.toneFile(seconds: 12)
        defer { try? FileManager.default.removeItem(at: tone) }
        let player = try LiveAudio.play(tone)
        let pid = player.processIdentifier

        // Reapplied on its own, on the default, because the chosen device isn't there.
        let tapped = await LiveAudio.waitUntil(timeout: .seconds(3)) {
            await source.status(for: pid) != nil
        }
        try #require(tapped, "the remembered setting never reapplied")
        let fallback = try #require(await source.status(for: pid))
        #expect(try fallback.outputUID == HAL.defaultOutputUID())
        #expect(fallback.targetGain == 0.5)
        #expect(try await LiveAudio.client(for: pid, in: source)?.outputDeviceUID == missing, "the choice is kept")

        // Cost of one tap built by the routing path, muting as it would with consent.
        try await source.promoteForTesting(pid)
        let cost = try await LiveAudio.measureCPU(seconds: 3)
        LiveAudio.report(String(format: "one tap via the routing path (fallback, muting): Mactivity %.3f%% of a core", cost.own))
        if let audiod = cost.coreaudiod {
            LiveAudio.report(String(format: "coreaudiod meanwhile: %.2f%% of a core", audiod))
        }

        // The chosen device appears: the device-list listener fires and tries to move the tap there.
        let changesBefore = await source.deviceListChanges
        let device = try TestOutputDevice(uid: missing)
        defer { device.remove() }
        let noticed = await LiveAudio.waitUntil(timeout: .seconds(3)) {
            await source.deviceListChanges > changesBefore
        }
        #expect(noticed, "no device-list notification")
        try await Task.sleep(for: .milliseconds(300))
        let after = try #require(await source.status(for: pid), "a refused move must keep the working tap")
        let moved = after.outputUID == missing
        LiveAudio.report(moved ? "tap moved to the test device" : "move refused (nested aggregate); tap kept on the default")
        #expect(after.targetGain == 0.5)
        #expect(after.isRunning)

        // It goes away again: on the default at 50%.
        device.remove()
        let back = await LiveAudio.waitUntil(timeout: .seconds(3)) {
            await source.status(for: pid)?.outputUID == (try? HAL.defaultOutputUID())
        }
        #expect(back)

        // Reset: forgotten, untouched, no tap.
        try await source.resetSettings(for: pid)
        #expect(await source.activeTapCount == 0)
        #expect(try await LiveAudio.client(for: pid, in: source)?.setting ?? .untouched == .untouched)
        await source.reset()
    }
}
