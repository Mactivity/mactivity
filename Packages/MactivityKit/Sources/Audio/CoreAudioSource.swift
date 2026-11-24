import Core
import CoreAudio
import Foundation
import os

public enum AudioVolumeError: Error, Equatable {
    /// Core Audio has no process object for the pid: it never opened an audio connection, it exited,
    /// or it's Mactivity itself.
    case processNotFound
    /// The tap delivered only silence while the app was playing: audio-capture consent is denied or
    /// hasn't been answered yet ("Screen & System Audio Recording" → "System Audio Recording Only").
    case permissionDenied
    case coreAudio(OSStatus)
}

extension AudioVolumeError: AudioChangeFailure {
    public var needsPermission: Bool {
        self == .permissionDenied
    }

    public var message: String {
        switch self {
        case .processNotFound:
            String(localized: "That app isn't playing audio any more.", bundle: .strings, comment: "Per-app volume error.")
        case .permissionDenied:
            String(localized: "Mactivity needs permission to change this app's audio.", bundle: .strings, comment: "Per-app volume error.")
        case let .coreAudio(status):
            String(
                localized: "macOS didn't accept the change (Core Audio error \(status)).", bundle: .strings,
                comment: "Per-app volume error. The argument is a numeric Core Audio error code."
            )
        }
    }
}

/// Per-app volume, mute, and output device through public Core Audio process taps (spec 6.11, macOS 14.2+).
///
/// For each process that needs it: a private tap on that process, a private aggregate device with the target
/// output (the default, or the app's chosen device) as its main sub-device and the tap as its input, and an
/// IOProc that writes the tap's samples × gain to that output. The tap mutes the app while Mactivity reads it
/// (`.mutedWhenTapped`). `TapPlanner` decides which processes need a tap: muted, below 100%, or sent to a
/// device other than the current default.
///
/// Settings are per app (`AudioClientMapping.settingsKey`), remembered in `VolumeMemory` and saved through
/// `AudioSettingsStore`. While the feature is on (`setEnabled(true)`), listeners on the process list, the
/// default output, the device list, and each remembered process's running state reapply them whenever the
/// app plays. Off, nothing listens.
///
/// Consent: without audio-capture consent a tap still mutes the app but delivers exact zeros, which would
/// silence it. So until one tap has heard real audio this session, a new tap starts *unmuted*, with the
/// IOProc writing silence (the app plays as normal, on its own output), and is switched to `.mutedWhenTapped`
/// only once it hears a non-zero sample. If it hears nothing for `probeWindow` while the app is playing, the
/// tap is torn down: a user's change throws `.permissionDenied`, and remembered settings mark the process
/// `needsPermission` until the user acts or consent is confirmed.
public actor CoreAudioSource: AudioSource {
    static let log = Logger(subsystem: "app.mactivity.audio", category: "volume")

    enum Consent {
        case unknown
        /// A tap heard real audio this session, so new taps can mute right away.
        case granted
    }

    /// A live process Core Audio knows about, from the last process-list read.
    struct KnownProcess: Equatable {
        let object: AudioObjectID
        let key: String
    }

    var memory: VolumeMemory
    let store: AudioSettingsStore
    /// Owns every rig and listener; its deinit is the safety net if `reset()` is never called.
    let table = RigTable()
    var consent = Consent.unknown
    let ownPID = getpid()
    /// How long a new, unmuted tap listens for the app's audio before deciding consent is missing.
    let probeWindow: Duration
    /// The per-app volume flag. Off: no listeners, no taps, except ones a direct call makes (tests).
    var isEnabled = false
    var known: [Int32: KnownProcess] = [:]
    /// Processes whose remembered settings couldn't be applied for lack of consent. They play untouched until
    /// the user changes them or another tap confirms consent.
    var blocked: Set<Int32> = []
    /// Device-list notifications handled. Diagnostics: proves the listener fires without polling.
    var deviceListChanges = 0

    /// `store` defaults to memory only; the app passes `.standardDefaults()`.
    public init(store: AudioSettingsStore = .inMemory()) {
        self.init(probeWindow: .milliseconds(1500), store: store)
    }

    init(probeWindow: Duration, store: AudioSettingsStore = .inMemory()) {
        self.probeWindow = probeWindow
        self.store = store
        memory = VolumeMemory.decoded(from: store.load())
    }

    // MARK: - AudioSource

    /// Processes that produce output, plus any Mactivity has a tap on or couldn't apply settings to, with their
    /// app's settings. Also drops taps whose process has exited.
    public func clients() async throws -> [AudioClient] {
        let infos = try processInfos()
        await sync(infos, apply: false)
        return AudioClientMapping.clients(
            from: infos, memory: memory, tapped: Set(table.rigs.keys), blocked: blocked, excluding: ownPID
        )
    }

    /// Below 100% creates or updates the app's tap; 0 silences it. Moving the level unmutes.
    public func setVolume(_ volume: Double, for pid: Int32) async throws {
        try await change(pid) { $0.setVolume(volume, for: $1) }
    }

    public func setMuted(_ muted: Bool, for pid: Int32) async throws {
        try await change(pid) { $0.setMuted(muted, for: $1) }
    }

    public func setOutputDevice(uid: String?, for pid: Int32) async throws {
        try await change(pid) { $0.setOutputDevice(uid, for: $1) }
    }

    public func resetSettings(for pid: Int32) async throws {
        try await change(pid) { $0.forget($1) }
    }

    public func outputDevices() async throws -> [AudioOutputDevice] {
        try HAL.outputDevices()
    }

    public func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else {
            return
        }
        isEnabled = enabled
        if enabled {
            Self.log.info("Per-app volume on; \(self.memory.settings.count) remembered apps")
            updateSystemListeners()
            if let infos = try? processInfos() {
                await sync(infos, apply: true)
            }
        } else {
            Self.log.info("Per-app volume off; every app plays untouched, remembered settings are kept")
            tearDownAll()
        }
    }

    /// Tears down every tap and aggregate device and stops listening. Remembered settings stay. Call on quit.
    public func reset() async {
        isEnabled = false
        tearDownAll()
    }

    // MARK: - Diagnostics (tests and the spike)

    var activeTapCount: Int {
        table.rigs.count
    }

    var listenerCount: (system: Int, processes: Int) {
        (table.systemListeners.count, table.watches.count)
    }

    /// A snapshot of one process's tap, read from Core Audio and the render state.
    struct TapStatus: Sendable {
        let token: String
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let outputUID: String
        let isMuting: Bool
        let isRunning: Bool
        let cycles: UInt64
        let heardSignal: Bool
        let targetGain: Float
        /// `CATapMuteBehavior` as Core Audio reports it for the live tap.
        let muteBehavior: CATapMuteBehavior?
        let latency: AudioLatency
    }

    func status(for pid: Int32) -> TapStatus? {
        guard let rig = table.rigs[pid] else {
            return nil
        }
        return TapStatus(
            token: rig.token, tapID: rig.tapID, aggregateID: rig.aggregateID, outputUID: rig.outputUID,
            isMuting: rig.isMuting, isRunning: rig.isRunning, cycles: rig.cycles, heardSignal: rig.heardSignal,
            targetGain: rig.targetGain, muteBehavior: try? rig.muteBehavior(), latency: rig.latency()
        )
    }

    /// Forces a probing tap to mute, as if consent were confirmed. Live tests only.
    func promoteForTesting(_ pid: Int32) throws {
        try promote(pid)
    }

    /// Rebuilds every tap where its settings say it belongs now. `force` rebuilds taps already there (live tests
    /// exercise the rebuild without changing the user's output device).
    func moveTaps(force: Bool = false) async {
        await reconcileAll(force: force)
    }

    // MARK: - Changes

    /// Applies a user's change to the app `pid` belongs to. If it can't be applied, the setting goes back to
    /// what it was, so the UI shows what the app really does, and the error is rethrown.
    private func change(_ pid: Int32, _ mutate: (inout VolumeMemory, String) -> Bool) async throws {
        guard pid != ownPID, let object = try HAL.processObject(for: pid), let info = try? HAL.processInfo(object) else {
            // Nothing to do for an unknown process unless the change asked for something.
            var scratch = VolumeMemory()
            if mutate(&scratch, VolumeMemory.sessionKeyPrefix + String(pid)) {
                throw AudioVolumeError.processNotFound
            }
            return
        }
        let key = AudioClientMapping.settingsKey(info)
        known[pid] = KnownProcess(object: object, key: key)
        let before = memory.setting(for: key)
        guard mutate(&memory, key) else {
            return
        }
        save()
        blocked.remove(pid)
        do {
            try await reconcile(pid, devices: currentDevices(), explicit: true)
        } catch {
            memory.restore(before, for: key)
            save()
            if error as? AudioVolumeError == .permissionDenied {
                // The probe already removed the tap; the app plays untouched on its own output.
                if !before.isUntouched {
                    blocked.insert(pid)
                }
                removeRig(pid)
            } else {
                // E.g. a device that won't take an aggregate: go back to what the previous setting needs.
                await reconcileQuietly(pid, devices: try? currentDevices())
            }
            refreshWatches()
            throw error
        }
        // The app's other processes (helpers, a second instance) follow.
        let devices = try? currentDevices()
        for (other, process) in known where other != pid && process.key == key {
            await reconcileQuietly(other, devices: devices)
        }
        refreshWatches()
    }

    func save() {
        store.save(memory.encoded())
    }

    func currentDevices() throws -> TapPlanner.Devices {
        try TapPlanner.Devices(defaultUID: HAL.defaultOutputUID(), available: Set(HAL.outputDevices().map(\.uid)))
    }

    func processInfos() throws -> [AudioProcessInfo] {
        try HAL.objectList(HAL.system, kAudioHardwarePropertyProcessObjectList).compactMap { try? HAL.processInfo($0) }
    }

    private func tearDownAll() {
        for pid in Array(table.rigs.keys) {
            removeRig(pid)
        }
        known.removeAll()
        blocked.removeAll()
        refreshWatches()
        updateSystemListeners()
    }
}
