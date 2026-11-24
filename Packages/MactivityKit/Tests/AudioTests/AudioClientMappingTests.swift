@testable import Audio
import Core
import Foundation
import Testing

struct AudioProcessFixture: Decodable {
    let ownPID: Int32
    let settings: [String: AudioAppSetting]
    let tapped: [Int32]
    let blocked: [Int32]
    let processes: [AudioProcessInfo]
    let expected: [AudioClient]

    var memory: VolumeMemory {
        VolumeMemory(settings: settings)
    }
}

@Suite("Process properties → AudioClient")
struct AudioClientMappingTests {
    let fixture: AudioProcessFixture

    init() throws {
        fixture = try Fixtures.load("audio-processes.json")
    }

    private func clients(memory: VolumeMemory? = nil, tapped: Set<Int32>? = nil, blocked: Set<Int32>? = nil) -> [AudioClient] {
        AudioClientMapping.clients(
            from: fixture.processes,
            memory: memory ?? fixture.memory,
            tapped: tapped ?? Set(fixture.tapped),
            blocked: blocked ?? Set(fixture.blocked),
            excluding: fixture.ownPID
        )
    }

    @Test("The fixture's process list maps to exactly the expected clients")
    func fixtureMapping() {
        #expect(clients() == fixture.expected)
    }

    @Test("Mactivity never lists itself, even when tapped")
    func excludesSelf() {
        #expect(!clients(tapped: [fixture.ownPID]).contains { $0.pid == fixture.ownPID })
    }

    @Test("A process that's neither playing, tapped, nor blocked is left out, even when its app is remembered")
    func leavesOutQuiet() {
        let clients = clients(memory: VolumeMemory(), tapped: [], blocked: [])
        #expect(!clients.contains { $0.pid == 28454 })
        #expect(!clients.contains { $0.pid == 11676 })
        #expect(!clients.contains { $0.pid == 30100 })
        #expect(clients.allSatisfy { $0.volume == 1 && !$0.isMuted && $0.outputDeviceUID == nil })
        // A second Safari process that isn't playing stays out while the playing one carries Safari's settings.
        #expect(!self.clients().contains { $0.pid == 39800 })
    }

    @Test(
        "App ID: bundle ID when there is one, else other:<pid>",
        arguments: [
            ("com.apple.Safari", Int32(10), "com.apple.Safari"),
            (nil, Int32(11), "other:11"),
            ("", Int32(12), "other:12"),
        ] as [(String?, Int32, String)]
    )
    func appID(bundleID: String?, pid: Int32, expected: AppIdentity.ID) {
        #expect(AudioClientMapping.appID(bundleID: bundleID, pid: pid) == expected)
    }

    @Test(
        "Settings key: bundle ID, else executable path, else a session-only pid key",
        arguments: [
            ("com.spotify.client", "/Applications/Spotify.app/Contents/MacOS/Spotify", "com.spotify.client"),
            (nil, "/usr/bin/afplay", "/usr/bin/afplay"),
            ("", "/opt/homebrew/bin/mpv", "/opt/homebrew/bin/mpv"),
            (nil, nil, "pid:13"),
            (nil, "", "pid:13"),
        ] as [(String?, String?, String)]
    )
    func settingsKey(bundleID: String?, path: String?, expected: String) {
        #expect(AudioClientMapping.settingsKey(bundleID: bundleID, executablePath: path, pid: 13) == expected)
    }

    @Test("An empty process list maps to no clients")
    func empty() {
        let clients = AudioClientMapping.clients(from: [], memory: fixture.memory, tapped: [1], blocked: [2], excluding: 1)
        #expect(clients.isEmpty)
    }

    @Test("Older client JSON without the new fields still decodes, as untouched")
    func decodesOldClients() throws {
        let data = Data(#"{"pid": 7, "app": "com.apple.Music", "volume": 0.4}"#.utf8)
        let client = try JSONDecoder().decode(AudioClient.self, from: data)
        #expect(client == AudioClient(pid: 7, app: "com.apple.Music", volume: 0.4))
        #expect(client.settingsKey == "com.apple.Music")
        #expect(!client.isMuted)
        #expect(client.outputDeviceUID == nil)
    }
}
