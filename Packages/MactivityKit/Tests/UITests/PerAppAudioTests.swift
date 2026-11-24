import Core
import Foundation
import Simulated
import Testing
@testable import UI

@MainActor
@Suite("Per-app audio rows")
struct PerAppAudioTests {
    @Test("Processes of one app share a row, in pid order; the first process speaks for the app")
    func grouping() {
        let clients = [
            AudioClient(pid: 30, app: "com.google.Chrome.helper", volume: 0.5, settingsKey: "com.google.Chrome.helper"),
            AudioClient(pid: 10, app: "com.google.Chrome.helper", volume: 0.5, settingsKey: "com.google.Chrome.helper"),
            AudioClient(pid: 20, app: "other:20", volume: 1, settingsKey: "/usr/bin/afplay"),
        ]
        let rows = PerAppAudioModel.rows(from: clients)
        #expect(rows.map(\.key) == ["com.google.Chrome.helper", "/usr/bin/afplay"])
        #expect(rows[0].pids == [10, 30])
        #expect(rows[0].client.pid == 10)
        #expect(rows[1].pids == [20])
    }

    @Test("Names: the snapshot's app for the pid, else the bundle ID's app, else the executable's name")
    func identity() async {
        let snapshot = await SimulatedSnapshotSource().next()
        let musicPID = SimulatedCatalog.apps.firstIndex { $0.identity.name == "Music" }.map { Int32(400 + $0 * 100) } ?? 0
        let music = AudioClient(pid: musicPID, app: "com.apple.Music", volume: 1)
        #expect(PerAppAudioModel.identity(for: music, in: snapshot).name == "Music")
        let tool = AudioClient(pid: 99999, app: "other:99999", volume: 1, settingsKey: "/usr/bin/afplay")
        #expect(PerAppAudioModel.identity(for: tool, in: snapshot).name == "afplay")
        let anonymous = AudioClient(pid: 99998, app: "other:99998", volume: 1, settingsKey: "pid:99998")
        #expect(PerAppAudioModel.identity(for: anonymous, in: nil).name == "PID 99998")
    }

    @Test("Mute, level, device, and reset go through the source and come back on refresh")
    func actions() async throws {
        let source = SimulatedAudioSource()
        let model = PerAppAudioModel()
        await model.refresh(source)
        #expect(model.rows.count == 3)
        #expect(model.devices.count == 2)
        let safari = try #require(model.rows.first { $0.key == "com.apple.Safari" })
        #expect(safari.client.setting == .untouched)

        model.setMuted(true, for: safari)
        #expect(model.rows.first { $0.key == safari.key }?.client.isMuted == true, "shown before the source answers")
        try await settle(model, source) { $0.isMuted }

        model.setOutputDevice(SimulatedAudioSource.headphonesUID, for: safari)
        try await settle(model, source) { $0.outputDeviceUID == SimulatedAudioSource.headphonesUID && $0.isMuted }

        model.setVolume(0.3, for: safari)
        try await settle(model, source) { $0.volume == 0.3 && !$0.isMuted }

        model.reset(safari)
        try await settle(model, source) { $0.setting == .untouched }
        #expect(!model.needsPermission)
    }

    @Test("A failure that isn't about permission says what happened instead of asking for permission")
    func failureMessages() async throws {
        let model = PerAppAudioModel()
        let failing = FailingAudioSource(error: TestAudioFailure(needsPermission: false, message: "That app isn't playing audio any more."))
        await model.refresh(failing)
        let row = try #require(model.rows.first)
        model.setMuted(true, for: row)
        for _ in 0 ..< 50 where model.failureMessage == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.failureMessage == "That app isn't playing audio any more.")
        #expect(!model.needsPermission)

        let denied = FailingAudioSource(error: TestAudioFailure(needsPermission: true, message: ""))
        await model.refresh(denied)
        try model.setVolume(0.5, for: #require(model.rows.first))
        for _ in 0 ..< 50 where !model.needsPermission {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.needsPermission)
        #expect(model.failureMessage == nil)
    }

    private func settle(_ model: PerAppAudioModel, _ source: SimulatedAudioSource, until: (AudioClient) -> Bool) async throws {
        for _ in 0 ..< 50 {
            try await Task.sleep(for: .milliseconds(10))
            await model.refresh(source)
            if let client = model.rows.first(where: { $0.key == "com.apple.Safari" })?.client, until(client) {
                return
            }
        }
        Issue.record("The source never reported the change")
    }
}

private struct TestAudioFailure: AudioChangeFailure {
    let needsPermission: Bool
    let message: String
}

/// One app playing; every change fails with `error`.
private struct FailingAudioSource: AudioSource {
    let error: TestAudioFailure

    func clients() async throws -> [AudioClient] {
        [AudioClient(pid: 42, app: "com.example.player", volume: 1)]
    }

    func setVolume(_: Double, for _: Int32) async throws {
        throw error
    }

    func setMuted(_: Bool, for _: Int32) async throws {
        throw error
    }

    func setOutputDevice(uid _: String?, for _: Int32) async throws {
        throw error
    }

    func resetSettings(for _: Int32) async throws {
        throw error
    }

    func outputDevices() async throws -> [AudioOutputDevice] {
        []
    }

    func setEnabled(_: Bool) async {}
}
