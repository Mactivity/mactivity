@testable import Audio
import Core
import CoreAudio
import Foundation
import Testing

/// Helpers for tests that touch the real Core Audio HAL.
enum LiveAudio {
    /// Tests that create a real tap run only with `MACTIVITY_AUDIO_LIVE=1`. They play a quiet tone
    /// through `afplay` for a few seconds.
    static let enabled = ProcessInfo.processInfo.environment["MACTIVITY_AUDIO_LIVE"] == "1"

    /// A quiet stereo tone (440 Hz left, 660 Hz right, −26 dBFS), 48 kHz 16-bit WAV.
    static func toneFile(seconds: Double) throws -> URL {
        let rate = 48000
        let frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * 4)
        for frame in 0 ..< frames {
            let time = Double(frame) / Double(rate)
            for hertz in [440.0, 660.0] {
                let sample = Int16(1600 * sin(2 * Double.pi * hertz * time))
                withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        var wav = Data()
        func append(_ string: String) {
            wav.append(contentsOf: Array(string.utf8))
        }
        func append(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        append("RIFF")
        append(UInt32(36 + pcm.count))
        append("WAVEfmt ")
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(2))
        append(UInt32(rate))
        append(UInt32(rate * 4))
        append(UInt16(4))
        append(UInt16(16))
        append("data")
        append(UInt32(pcm.count))
        wav.append(pcm)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mactivity-audio-live-\(UUID().uuidString).wav")
        try wav.write(to: url)
        return url
    }

    /// Plays `url` with `afplay`. The tone ends on its own; tests never kill it (CLAUDE.md rule 4).
    static func play(_ url: URL) throws -> Process {
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.3", url.path]
        try player.run()
        return player
    }

    static func waitUntil(timeout: Duration, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if try await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }

    /// This process's user + system CPU time, in seconds.
    static func ownCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    /// coreaudiod's CPU time from `ps` (it runs as another user, so `proc_pid_rusage` isn't readable).
    static func coreaudiodCPUSeconds() -> Double? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-x", "-o", "time=,comm=", "-U", "_coreaudiod"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else {
            return nil
        }
        ps.waitUntilExit()
        guard let output = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let line = output.split(separator: "\n").first(where: { $0.hasSuffix("coreaudiod") }),
              let time = line.split(separator: " ").first
        else {
            return nil
        }
        // "M:SS.cc" or "H:MM:SS.cc"
        return time.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    }

    /// Percent of one core used by this process and by coreaudiod while sleeping `seconds`. `ps` runs
    /// outside the window for this process's figure, so its fork and exec don't count.
    static func measureCPU(seconds: Double) async throws -> (own: Double, coreaudiod: Double?) {
        let clock = ContinuousClock()
        let audiodStart = coreaudiodCPUSeconds()
        let ownStart = ownCPUSeconds()
        let start = clock.now
        try await Task.sleep(for: .seconds(seconds))
        let ownEnd = ownCPUSeconds()
        let elapsed = (clock.now - start) / .seconds(1)
        let audiod = coreaudiodCPUSeconds().flatMap { end in audiodStart.map { (end - $0) / elapsed * 100 } }
        return ((ownEnd - ownStart) / elapsed * 100, audiod)
    }

    static func report(_ line: String) {
        FileHandle.standardError.write(Data("[audio-live] \(line)\n".utf8))
    }

    static func client(for pid: Int32, in source: CoreAudioSource) async throws -> AudioClient? {
        try await source.clients().first { $0.pid == pid }
    }
}

@Suite(
    "Core Audio source, live",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MACTIVITY_LIVE_TESTS"] != nil, "needs real Mac hardware: make test-live")
)
struct CoreAudioSourceLiveTests {
    @Test("clients() doesn't throw on this Mac and never lists Mactivity's own process")
    func clientsSmoke() async throws {
        let source = CoreAudioSource()
        let clients = try await source.clients()
        #expect(!clients.contains { $0.pid == getpid() })
        #expect(clients.allSatisfy { $0.volume == 1 })
        #expect(Set(clients.map(\.pid)).count == clients.count)
    }

    @Test("An unknown pid throws .processNotFound and leaves nothing behind; 1.0 on it is a no-op")
    func unknownProcess() async throws {
        let source = CoreAudioSource()
        await #expect(throws: AudioVolumeError.processNotFound) {
            try await source.setVolume(0.5, for: Int32.max)
        }
        try await source.setVolume(1, for: Int32.max)
        #expect(await source.activeTapCount == 0)
        await #expect(throws: AudioVolumeError.processNotFound) {
            try await source.setVolume(0.5, for: getpid())
        }
        #expect(try await source.clients().allSatisfy { $0.volume == 1 })
    }

    @Test(
        "setVolume on a playing process: applied with consent, .permissionDenied and no leftover tap without",
        .enabled(if: LiveAudio.enabled)
    )
    func consentOutcome() async throws {
        let tone = try LiveAudio.toneFile(seconds: 4)
        defer { try? FileManager.default.removeItem(at: tone) }
        let player = try LiveAudio.play(tone)
        let pid = player.processIdentifier
        let source = CoreAudioSource(probeWindow: .seconds(1))
        let playing = try await LiveAudio.waitUntil(timeout: .seconds(3)) {
            try await LiveAudio.client(for: pid, in: source) != nil
        }
        #expect(playing, "afplay never showed up as an output process")

        do {
            try await source.setVolume(0.5, for: pid)
            LiveAudio.report("consent granted: tap is applying gain 0.5")
            #expect(await source.status(for: pid)?.isMuting == true)
            #expect(try await LiveAudio.client(for: pid, in: source)?.volume == 0.5)
        } catch AudioVolumeError.permissionDenied {
            LiveAudio.report("no audio-capture consent: .permissionDenied, tap torn down")
            #expect(await source.activeTapCount == 0)
            #expect(try await LiveAudio.client(for: pid, in: source)?.volume ?? 1 == 1)
        }
        await source.reset()
        #expect(await source.activeTapCount == 0)
    }

    /// Exercises every Core Audio path whether or not this process has consent: an unmuted probing tap,
    /// promotion to `.mutedWhenTapped` on the live tap, gain updates, a rebuild as on an output-device
    /// change, teardown when the process exits, and the cost of one active tap.
    @Test("Tap mechanics and cost", .enabled(if: LiveAudio.enabled))
    func mechanics() async throws {
        let tone = try LiveAudio.toneFile(seconds: 9)
        defer { try? FileManager.default.removeItem(at: tone) }
        let player = try LiveAudio.play(tone)
        let pid = player.processIdentifier
        let source = CoreAudioSource(probeWindow: .seconds(5))
        let playing = try await LiveAudio.waitUntil(timeout: .seconds(3)) {
            try await LiveAudio.client(for: pid, in: source) != nil
        }
        try #require(playing, "afplay never showed up as an output process")

        // Baseline: coreaudiod with afplay playing and no tap.
        let baseline = try await LiveAudio.measureCPU(seconds: 1)

        // Probing: the tap exists, IO runs, the app is not muted.
        async let applied: Void = source.setVolume(0.5, for: pid)
        try await Task.sleep(for: .milliseconds(500))
        let probing = try #require(await source.status(for: pid))
        #expect(probing.isRunning)
        #expect(probing.cycles > 0)
        let heard = probing.heardSignal
        LiveAudio.report("probe: \(probing.cycles) IO cycles in 0.5 s, heard signal: \(heard)")
        if !heard {
            #expect(!probing.isMuting)
            #expect(probing.muteBehavior == .unmuted)
        }

        // Promotion switches the live tap to mute-when-tapped (with no consent, afplay goes silent here).
        try await source.promoteForTesting(pid)
        try await applied
        let active = try #require(await source.status(for: pid))
        #expect(active.isMuting)
        #expect(active.muteBehavior == .mutedWhenTapped)
        let latency = active.latency
        LiveAudio.report(
            "aggregate: \(latency.sampleRate) Hz, buffer \(latency.bufferFrames), in latency \(latency.inputLatencyFrames) + safety "
                + "\(latency.inputSafetyOffsetFrames), out latency \(latency.outputLatencyFrames) + safety "
                + "\(latency.outputSafetyOffsetFrames) frames; added ≈ \(latency.addedFrames) frames = "
                + String(format: "%.1f ms", latency.addedMilliseconds)
        )

        // Cost of one active tap: this process (the IOProc) and coreaudiod.
        let cost = try await LiveAudio.measureCPU(seconds: 2)
        LiveAudio.report(String(format: "one active tap: Mactivity %.3f%% of a core", cost.own))
        if let withTap = cost.coreaudiod, let before = baseline.coreaudiod {
            LiveAudio.report(String(
                format: "coreaudiod: %.2f%% of a core with the tap, %.2f%% before it (ps resolution 10 ms)", withTap, before
            ))
        }

        // Gain update in place; the same tap keeps running.
        try await source.setVolume(0.25, for: pid)
        #expect(await source.status(for: pid)?.targetGain == 0.25)
        #expect(await source.status(for: pid)?.token == active.token)
        #expect(try await LiveAudio.client(for: pid, in: source)?.volume == 0.25)

        // Rebuild, as on a default-output change, keeps gain and mute state on new objects.
        await source.moveTaps(force: true)
        let rebuilt = try #require(await source.status(for: pid))
        #expect(rebuilt.token != active.token)
        #expect(rebuilt.isMuting)
        #expect(rebuilt.isRunning)
        #expect(rebuilt.targetGain == 0.25)
        #expect(rebuilt.muteBehavior == .mutedWhenTapped)

        // afplay finishes on its own; the process-list listener tears the tap down without a clients() call.
        let gone = await LiveAudio.waitUntil(timeout: .seconds(12)) {
            await source.activeTapCount == 0
        }
        #expect(gone, "tap outlived its process")
        LiveAudio.report("afplay exited; tap torn down by the process-list listener: \(gone)")
        await source.reset()
        #expect(await source.activeTapCount == 0)
    }

    @Test("reset() destroys every tap and aggregate device", .enabled(if: LiveAudio.enabled))
    func resetTearsDown() async throws {
        let tone = try LiveAudio.toneFile(seconds: 3)
        defer { try? FileManager.default.removeItem(at: tone) }
        let player = try LiveAudio.play(tone)
        let pid = player.processIdentifier
        let source = CoreAudioSource(probeWindow: .seconds(5))
        _ = try await LiveAudio.waitUntil(timeout: .seconds(3)) {
            try await LiveAudio.client(for: pid, in: source) != nil
        }
        async let applied: Void = source.setVolume(0.5, for: pid)
        try await Task.sleep(for: .milliseconds(300))
        let rig = try #require(await source.status(for: pid))
        let tapsBefore = try HAL.objectList(HAL.system, kAudioHardwarePropertyTapList)
        #expect(tapsBefore.contains(rig.tapID))
        await source.reset()
        _ = try? await applied
        #expect(await source.activeTapCount == 0)
        // Core Audio finishes destroying taps and aggregate devices asynchronously; give it a moment.
        let clock = ContinuousClock()
        let start = clock.now
        let gone = try await LiveAudio.waitUntil(timeout: .seconds(3)) {
            let taps = try HAL.objectList(HAL.system, kAudioHardwarePropertyTapList)
            let devices = try HAL.objectList(HAL.system, kAudioHardwarePropertyDevices)
            return !taps.contains(rig.tapID) && !devices.contains(rig.aggregateID)
        }
        #expect(gone, "tap or aggregate device still listed 3 s after reset()")
        LiveAudio.report("tap and aggregate device gone from the HAL \(clock.now - start) after reset()")
        // Quitting keeps what the user chose; it's reapplied next launch.
        #expect(try await LiveAudio.client(for: pid, in: source)?.volume ?? 0.5 == 0.5)
    }
}
