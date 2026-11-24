import Core
import CoreAudio

/// What Core Audio says about one process object (`kAudioHardwarePropertyProcessObjectList`).
struct AudioProcessInfo: Equatable, Sendable, Decodable {
    let objectID: AudioObjectID
    let pid: Int32
    /// `kAudioProcessPropertyBundleID`; `nil` or empty for command-line tools.
    let bundleID: String?
    /// `proc_pidpath`, read only when there's no bundle ID.
    var executablePath: String?
    /// `kAudioProcessPropertyIsRunningOutput`.
    let isRunningOutput: Bool
}

/// Process properties → `AudioClient`. Pure, so it's tested with fixtures.
enum AudioClientMapping {
    /// The bundle ID when there is one, else `"other:<pid>"`. The app maps this to its own identities
    /// (a helper's bundle ID, e.g. `com.google.Chrome.helper`, resolves to its parent app there).
    static func appID(bundleID: String?, pid: Int32) -> AppIdentity.ID {
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        return "other:\(pid)"
    }

    /// What an app's settings are remembered under: the bundle ID, else the executable path, so they survive
    /// relaunches of either app. With neither, a `pid:` key that lasts only for the session.
    static func settingsKey(bundleID: String?, executablePath: String?, pid: Int32) -> String {
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        if let executablePath, !executablePath.isEmpty {
            return executablePath
        }
        return VolumeMemory.sessionKeyPrefix + String(pid)
    }

    static func settingsKey(_ process: AudioProcessInfo) -> String {
        settingsKey(bundleID: process.bundleID, executablePath: process.executablePath, pid: process.pid)
    }

    /// Valid processes other than `ownPID` (Mactivity's aggregate devices make it an output process), sorted by
    /// pid, one per pid.
    static func relevant(_ processes: [AudioProcessInfo], excluding ownPID: Int32) -> [AudioProcessInfo] {
        var seen = Set<Int32>()
        return processes.sorted { $0.pid < $1.pid }.filter { process in
            guard process.pid > 0, process.pid != ownPID, !seen.contains(process.pid) else {
                return false
            }
            seen.insert(process.pid)
            return true
        }
    }

    /// Processes playing audio right now, plus any Mactivity has a tap on (so a paused app's row doesn't vanish)
    /// or couldn't apply remembered settings to. Excludes `ownPID` and invalid pids. Sorted by pid.
    static func clients(
        from processes: [AudioProcessInfo],
        memory: VolumeMemory,
        tapped: Set<Int32>,
        blocked: Set<Int32>,
        excluding ownPID: Int32
    ) -> [AudioClient] {
        relevant(processes, excluding: ownPID).compactMap { process in
            guard process.isRunningOutput || tapped.contains(process.pid) || blocked.contains(process.pid) else {
                return nil
            }
            let key = settingsKey(process)
            let setting = memory.setting(for: key)
            return AudioClient(
                pid: process.pid,
                app: appID(bundleID: process.bundleID, pid: process.pid),
                volume: setting.volume,
                isMuted: setting.isMuted,
                outputDeviceUID: setting.outputDeviceUID,
                settingsKey: key,
                needsPermission: blocked.contains(process.pid)
            )
        }
    }
}
