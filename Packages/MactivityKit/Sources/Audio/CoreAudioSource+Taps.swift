import Core
import CoreAudio
import Foundation

/// Building, moving, probing, and tearing down taps.
extension CoreAudioSource {
    /// Brings `pid`'s tap in line with its app's settings and the devices connected now (`TapPlanner`). Unless
    /// the user asked (`explicit`), a new tap is built only while the feature is on, for a process that's
    /// playing and not blocked.
    func reconcile(_ pid: Int32, devices: TapPlanner.Devices, explicit: Bool, force: Bool = false) async throws {
        guard let process = known[pid] else {
            return
        }
        let desired = TapPlanner.desired(memory.setting(for: process.key), devices: devices)
        switch TapPlanner.action(current: table.rigs[pid]?.spec, desired: desired, force: force) {
        case .none:
            return
        case .remove:
            removeRig(pid)
        case let .update(gain):
            table.rigs[pid]?.setGain(gain)
        case let .install(spec):
            guard explicit || (isEnabled && !blocked.contains(pid) && HAL.isRunningOutput(process.object)) else {
                return
            }
            try await install(pid, process: process, spec: spec)
        case let .move(spec):
            try await move(pid, to: spec)
        }
    }

    /// `reconcile` for work nobody is waiting on (listeners, other processes of the same app). A consent failure
    /// blocks the process so it isn't probed again on every resume.
    func reconcileQuietly(_ pid: Int32, devices: TapPlanner.Devices?, force: Bool = false) async {
        guard let devices else {
            return
        }
        do {
            try await reconcile(pid, devices: devices, explicit: false, force: force)
        } catch AudioVolumeError.permissionDenied {
            blocked.insert(pid)
            Self.log.error("Pid \(pid, privacy: .public) plays untouched: its tap heard only silence (no audio-capture consent)")
        } catch {
            Self.log.error("Couldn't apply settings to pid \(pid, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Every tapped process, and every playing process of a remembered app, against the devices now. Runs on
    /// default-output and device-list changes: taps that follow the default move with it, and a chosen device
    /// that went away falls back to the default until it's back.
    func reconcileAll(force: Bool = false) async {
        guard let devices = try? currentDevices() else {
            return
        }
        var pids = Set(table.rigs.keys)
        if isEnabled {
            pids.formUnion(known.filter { memory.remembers($0.value.key) }.keys)
        }
        for pid in pids.sorted() {
            await reconcileQuietly(pid, devices: devices, force: force && table.rigs[pid] != nil)
        }
    }

    /// Takes in a fresh process list: forgets exited processes and their taps, updates listeners, and with
    /// `apply`, reapplies remembered settings to processes playing without a tap.
    func sync(_ infos: [AudioProcessInfo], apply: Bool) async {
        let relevant = AudioClientMapping.relevant(infos, excluding: ownPID)
        var fresh: [Int32: KnownProcess] = [:]
        for process in relevant {
            fresh[process.pid] = KnownProcess(object: process.objectID, key: AudioClientMapping.settingsKey(process))
        }
        known = fresh
        for pid in Array(table.rigs.keys) where known[pid] == nil {
            Self.log.info("Pid \(pid, privacy: .public) exited")
            removeRig(pid)
        }
        blocked.formIntersection(known.keys)
        refreshWatches()
        guard apply else {
            return
        }
        let pids = ReapplyPlanner.toApply(
            keys: known.mapValues(\.key),
            running: Set(relevant.filter(\.isRunningOutput).map(\.pid)),
            memory: memory, tapped: Set(table.rigs.keys), blocked: blocked, enabled: isEnabled
        )
        Self.log.debug(
            "Process list: \(relevant.count) processes, watching \(self.table.watches.count), reapplying \(pids, privacy: .public)"
        )
        guard !pids.isEmpty else {
            return
        }
        let devices = try? currentDevices()
        for pid in pids {
            await reconcileQuietly(pid, devices: devices)
        }
    }

    // MARK: - Rigs

    private func install(_ pid: Int32, process: KnownProcess, spec: RigSpec) async throws {
        let rig = try TapRig.build(
            pid: pid, processObject: process.object, outputUID: spec.deviceUID, muting: consent == .granted, gain: spec.gain
        )
        table.rigs[pid] = rig
        refreshWatches()
        updateSystemListeners()
        let device = spec.deviceUID
        Self.log.info("Tap for pid \(pid, privacy: .public) on \(device, privacy: .public) at gain \(spec.gain, privacy: .public)")
        guard HAL.isRunningOutput(process.object) else {
            return
        }
        try await startAndProbe(pid, token: rig.token)
    }

    /// Rebuilds a tap on another device (or the same one, forced) at the spec's gain. The new tap starts before
    /// the old one is destroyed, so the app never plays unmuted in between.
    private func move(_ pid: Int32, to spec: RigSpec) async throws {
        guard var old = table.rigs[pid] else {
            return
        }
        var rig: TapRig
        do {
            rig = try TapRig.build(
                pid: pid, processObject: old.processObject, outputUID: spec.deviceUID,
                muting: old.isMuting || consent == .granted, gain: spec.gain
            )
            if old.isRunning {
                do {
                    try rig.start()
                } catch {
                    rig.destroy()
                    throw error
                }
            }
        } catch {
            // Keep the tap that works (at the new gain) while its device is still there; the next device change
            // tries again. With its device gone too, there's nothing worth keeping.
            if HAL.device(uid: old.outputUID) != nil {
                old.setGain(spec.gain)
            } else {
                removeRig(pid)
            }
            throw error
        }
        old.destroy()
        table.rigs[pid] = rig
        Self.log.info("Moved tap for pid \(pid, privacy: .public) to \(spec.deviceUID, privacy: .public)")
        if rig.isRunning, !rig.isMuting {
            try await startAndProbe(pid, token: rig.token)
        }
    }

    /// Starts IO and, for an unmuted tap, waits for it to hear the app. Removes the tap if either fails.
    func startAndProbe(_ pid: Int32, token: String) async throws {
        do {
            try table.rigs[pid]?.start()
            if let rig = table.rigs[pid], rig.token == token, !rig.isMuting {
                try await probe(pid, token: token)
            }
        } catch {
            if table.rigs[pid]?.token == token {
                removeRig(pid)
            }
            throw error
        }
    }

    /// Waits for an unmuted tap to hear the app. Hearing it confirms consent and mutes the tap.
    private func probe(_ pid: Int32, token: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + probeWindow
        while clock.now < deadline {
            // Throws when the caller gave up; `startAndProbe` then removes the unmuted tap.
            try await Task.sleep(for: .milliseconds(20))
            guard let rig = table.rigs[pid], rig.token == token, !rig.isMuting else {
                return
            }
            if rig.heardSignal {
                try promote(pid)
                consentConfirmed()
                Self.log.info("Tap for pid \(pid, privacy: .public) hears audio; muting the app and applying its settings")
                return
            }
        }
        guard let rig = table.rigs[pid], rig.token == token, !rig.isMuting else {
            return
        }
        if HAL.isRunningOutput(rig.processObject) {
            Self.log.error("Tap for pid \(pid, privacy: .public) heard only silence after \(rig.cycles) cycles: no audio-capture consent")
            removeRig(pid)
            throw AudioVolumeError.permissionDenied
        }
        // The app stopped playing mid-probe. Stop IO; the running-output listener probes again when it resumes.
        table.rigs[pid]?.stop()
    }

    /// Consent is confirmed: new taps mute from the start, and blocked processes get another try.
    private func consentConfirmed() {
        consent = .granted
        guard !blocked.isEmpty else {
            return
        }
        blocked.removeAll()
        Task { await reconcileAll() }
    }

    /// Consent is confirmed: replace the probing rig with a muting one. The new tap starts reading (and so
    /// muting the app) before the old one is destroyed, so there's no gap and no doubled audio.
    func promote(_ pid: Int32) throws {
        guard var old = table.rigs[pid], !old.isMuting else {
            return
        }
        var rig = try TapRig.build(
            pid: pid, processObject: old.processObject, outputUID: old.outputUID, muting: true, gain: old.targetGain
        )
        if old.isRunning {
            do {
                try rig.start()
            } catch {
                rig.destroy()
                throw error
            }
        }
        old.destroy()
        table.rigs[pid] = rig
    }

    /// Destroys `pid`'s tap, if any. Its settings stay remembered.
    func removeRig(_ pid: Int32) {
        guard var rig = table.rigs.removeValue(forKey: pid) else {
            return
        }
        rig.destroy()
        Self.log.info("Removed tap for pid \(pid, privacy: .public)")
        refreshWatches()
        updateSystemListeners()
    }
}
