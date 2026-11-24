import Core
import Foundation

/// The settings Mactivity remembers per app, keyed by `AudioClientMapping.settingsKey` (bundle ID, else
/// executable path). Pure bookkeeping: `CoreAudioSource` persists it through `AudioSettingsStore` and turns
/// it into taps with `TapPlanner`. Only apps that differ from `.untouched` have an entry.
struct VolumeMemory: Equatable, Sendable, Codable {
    /// Keys for processes with neither a bundle ID nor a readable executable path. They name a pid, so they
    /// last only as long as the session and are never saved.
    static let sessionKeyPrefix = "pid:"

    private(set) var settings: [String: AudioAppSetting] = [:]

    init(settings: [String: AudioAppSetting] = [:]) {
        for (key, setting) in settings {
            restore(setting, for: key)
        }
    }

    /// 0...1. NaN counts as 1 (untouched) so a bad value never mutes an app.
    static func clamp(_ volume: Double) -> Double {
        guard !volume.isNaN else {
            return 1
        }
        return min(1, max(0, volume))
    }

    func setting(for key: String) -> AudioAppSetting {
        settings[key] ?? .untouched
    }

    func remembers(_ key: String) -> Bool {
        settings[key] != nil
    }

    /// Moving the level unmutes, like the system volume. Returns whether anything changed.
    @discardableResult
    mutating func setVolume(_ volume: Double, for key: String) -> Bool {
        update(key) {
            $0.volume = volume
            $0.isMuted = false
        }
    }

    /// Mute keeps the level, so unmuting restores it.
    @discardableResult
    mutating func setMuted(_ muted: Bool, for key: String) -> Bool {
        update(key) { $0.isMuted = muted }
    }

    /// An empty UID means the system default, like nil.
    @discardableResult
    mutating func setOutputDevice(_ uid: String?, for key: String) -> Bool {
        update(key) { $0.outputDeviceUID = uid }
    }

    /// "Reset": back to untouched, and forgotten.
    @discardableResult
    mutating func forget(_ key: String) -> Bool {
        settings.removeValue(forKey: key) != nil
    }

    /// Puts back a setting read earlier, e.g. after a change failed.
    mutating func restore(_ setting: AudioAppSetting, for key: String) {
        update(key) { $0 = setting }
    }

    @discardableResult
    private mutating func update(_ key: String, _ change: (inout AudioAppSetting) -> Void) -> Bool {
        let old = setting(for: key)
        var new = old
        change(&new)
        new.volume = Self.clamp(new.volume)
        if new.outputDeviceUID?.isEmpty == true {
            new.outputDeviceUID = nil
        }
        guard new != old else {
            return false
        }
        if new.isUntouched {
            settings.removeValue(forKey: key)
        } else {
            settings[key] = new
        }
        return true
    }

    // MARK: - Persistence

    /// What's worth keeping across launches: every key that names an app rather than a pid.
    var persistable: VolumeMemory {
        VolumeMemory(settings: settings.filter { !$0.key.hasPrefix(Self.sessionKeyPrefix) })
    }

    /// A small JSON dictionary: `{"com.spotify.client": {"isMuted": false, "volume": 0.5}}`.
    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(persistable)
    }

    /// Anything unreadable decodes as empty, so a bad preference never mutes an app. Values are clamped.
    static func decoded(from data: Data?) -> VolumeMemory {
        guard let data, let memory = try? JSONDecoder().decode(VolumeMemory.self, from: data) else {
            return VolumeMemory()
        }
        return memory.persistable
    }

    init(from decoder: any Decoder) throws {
        let settings = try decoder.singleValueContainer().decode([String: AudioAppSetting].self)
        self.init(settings: settings)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(settings)
    }
}
