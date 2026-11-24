import Core

/// The tap one process needs: the gain the IOProc applies and the output device its aggregate plays on.
struct RigSpec: Equatable, Sendable {
    let gain: Float
    let deviceUID: String
}

/// Which taps to build, change, move, or remove. Pure, so the rules are tested with fixtures; `CoreAudioSource`
/// carries out the actions.
enum TapPlanner {
    /// The output devices right now, by UID.
    struct Devices: Equatable, Sendable {
        let defaultUID: String
        let available: Set<String>
    }

    /// The chosen device while it's connected, else the system default. Unplugged headphones fall back to the
    /// default, and the app goes back to them when they reappear, because the choice is kept by UID.
    static func target(chosen: String?, devices: Devices) -> String {
        guard let chosen, devices.available.contains(chosen) else {
            return devices.defaultUID
        }
        return chosen
    }

    /// The tap a setting calls for, or nil when the app should play untouched. A tap is needed while the app is
    /// muted, below 100%, or sent somewhere other than the current default. At 100% and unmuted on the default
    /// (chosen, or fallen back to), there's no tap at all.
    static func desired(_ setting: AudioAppSetting, devices: Devices) -> RigSpec? {
        let device = target(chosen: setting.outputDeviceUID, devices: devices)
        let gain = GainKernel.gain(for: setting.effectiveVolume)
        guard gain < 1 || device != devices.defaultUID else {
            return nil
        }
        return RigSpec(gain: gain, deviceUID: device)
    }

    enum Action: Equatable {
        case none
        /// No tap yet: build one.
        case install(RigSpec)
        /// Same device: change the gain in place.
        case update(gain: Float)
        /// Another device: rebuild on it at the new gain.
        case move(RigSpec)
        /// Back to untouched: tear the tap down.
        case remove
    }

    /// What to do about a process's tap. `force` rebuilds a tap even when it's already on the right device.
    static func action(current: RigSpec?, desired: RigSpec?, force: Bool = false) -> Action {
        switch (current, desired) {
        case (nil, nil):
            .none
        case let (nil, desired?):
            .install(desired)
        case (_?, nil):
            .remove
        case let (current?, desired?):
            if force || current.deviceUID != desired.deviceUID {
                .move(desired)
            } else if current.gain == desired.gain {
                .none
            } else {
                .update(gain: desired.gain)
            }
        }
    }
}

/// Which processes to listen to, and which to reapply remembered settings to. Pure.
enum ReapplyPlanner {
    /// Processes Mactivity listens to for starting and stopping output: every tapped one (IO stops while it's quiet), and,
    /// while the feature is on, every live process of a remembered app (its settings reapply when it plays).
    static func watched(
        keys: [Int32: String],
        memory: VolumeMemory,
        tapped: Set<Int32>,
        enabled: Bool
    ) -> Set<Int32> {
        var pids = tapped.filter { keys[$0] != nil }
        if enabled {
            for (pid, key) in keys where memory.remembers(key) {
                pids.insert(pid)
            }
        }
        return pids
    }

    /// Processes of remembered apps that are playing without a tap: reconcile them now. Blocked ones (a tap heard
    /// only silence, so consent is missing) wait until the user changes them or consent is confirmed.
    static func toApply(
        keys: [Int32: String],
        running: Set<Int32>,
        memory: VolumeMemory,
        tapped: Set<Int32>,
        blocked: Set<Int32>,
        enabled: Bool
    ) -> [Int32] {
        guard enabled else {
            return []
        }
        return keys.compactMap { pid, key in
            memory.remembers(key) && running.contains(pid) && !tapped.contains(pid) && !blocked.contains(pid) ? pid : nil
        }
        .sorted()
    }
}
