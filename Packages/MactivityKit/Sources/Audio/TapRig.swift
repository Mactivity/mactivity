import CoreAudio
import Foundation
import os

/// Every Core Audio object behind one process's volume: a private process tap, a private aggregate
/// device (the target output as its clock, the tap as its input), an IOProc, and the IOProc's `RenderState`.
///
/// Owned by `CoreAudioSource`, which calls `destroy()` exactly once. Private taps and private aggregate
/// devices also die with the process that made them, so a crash doesn't leave a muted app behind.
struct TapRig {
    private static let log = Logger(subsystem: "app.mactivity.audio", category: "tap")

    let pid: Int32
    let processObject: AudioObjectID
    /// The tap's UUID string, unique per build; the probe uses it to tell a rebuilt rig from the one it
    /// started on. A `String`, not a `UUID`: a stored `UUID` made setting `Optional<TapRig>` to `nil` trap
    /// in the value witness under Swift 6.4.
    let token: String
    let tapID: AudioObjectID
    let aggregateID: AudioObjectID
    /// The device the aggregate plays on: the default output, or the app's chosen one.
    let outputDevice: AudioObjectID
    /// `outputDevice`'s UID, which is what settings and `TapPlanner` compare.
    let outputUID: String
    let ioProcID: AudioDeviceIOProcID
    /// The IOProc's `RenderState`, stored untyped to keep `TapRig`'s layout trivial. Swift 6.4 miscompiled
    /// `Optional<TapRig>`'s value witness with a resilient field here (docs/spikes/M10-per-app-volume.md).
    private let rawState: UnsafeMutableRawPointer

    var state: UnsafeMutablePointer<RenderState> {
        rawState.assumingMemoryBound(to: RenderState.self)
    }

    /// Whether the tap mutes the app (`.mutedWhenTapped`) and the IOProc plays it back at the gain.
    /// `false` while probing for consent: the app plays as normal and the IOProc writes silence. Fixed for
    /// the rig's life: Core Audio refuses to change a live tap's description (`'!hog'` on macOS 27, running
    /// or stopped), so promotion builds a new rig.
    let isMuting: Bool
    private(set) var isRunning = false

    var heardSignal: Bool {
        state.pointee.heardSignal.load(ordering: .relaxed)
    }

    var targetGain: Float {
        Float(bitPattern: state.pointee.targetGain.load(ordering: .relaxed))
    }

    var cycles: UInt64 {
        state.pointee.cycles.load(ordering: .relaxed)
    }

    /// Where this rig plays and at what gain, for `TapPlanner`.
    var spec: RigSpec {
        RigSpec(gain: targetGain, deviceUID: outputUID)
    }

    /// Builds the tap and an aggregate device on the output with `outputUID`, stopped. Cleans up everything it
    /// made if a step fails. Throws `kAudioHardwareBadDeviceError` when that device isn't connected.
    static func build(
        pid: Int32,
        processObject: AudioObjectID,
        outputUID: String,
        muting: Bool,
        gain: Float
    ) throws(AudioVolumeError) -> TapRig {
        let uuid = UUID()
        let token = uuid.uuidString
        guard let outputDevice = HAL.device(uid: outputUID) else {
            throw .coreAudio(kAudioHardwareBadDeviceError)
        }

        var tapID = kAudioObjectUnknown
        let description = tapDescription(pid: pid, processObject: processObject, uuid: uuid, muting: muting)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            throw tapStatus == kAudioHardwareBadObjectError ? .processNotFound : .coreAudio(tapStatus)
        }

        var aggregateID = kAudioObjectUnknown
        let aggregate = aggregateDescription(pid: pid, token: token, outputUID: outputUID)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr, aggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            throw .coreAudio(aggregateStatus)
        }

        let outputStreams = try? HAL.objectList(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard outputStreams?.isEmpty == false, (try? HAL.outputIsFloat32(aggregateID)) == true else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw .coreAudio(kAudioDeviceUnsupportedFormatError)
        }

        let state = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
        state.initialize(to: RenderState())
        state.pointee.targetGain.store(gain.bitPattern, ordering: .relaxed)
        state.pointee.isActive.store(muting, ordering: .relaxed)

        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcID(aggregateID, GainKernel.ioProc, UnsafeMutableRawPointer(state), &procID)
        guard procStatus == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            state.deinitialize(count: 1)
            state.deallocate()
            throw .coreAudio(procStatus)
        }

        return TapRig(
            pid: pid, processObject: processObject, token: token, tapID: tapID, aggregateID: aggregateID,
            outputDevice: outputDevice, outputUID: outputUID, ioProcID: procID, rawState: UnsafeMutableRawPointer(state),
            isMuting: muting
        )
    }

    func setGain(_ gain: Float) {
        state.pointee.targetGain.store(gain.bitPattern, ordering: .relaxed)
    }

    mutating func start() throws(AudioVolumeError) {
        guard !isRunning else {
            return
        }
        try HAL.check(AudioDeviceStart(aggregateID, ioProcID))
        isRunning = true
    }

    /// Blocks until the current IO cycle finishes, so `state` is safe to free afterwards.
    mutating func stop() {
        guard isRunning else {
            return
        }
        AudioDeviceStop(aggregateID, ioProcID)
        isRunning = false
    }

    /// The tap's current mute behavior, read back from Core Audio.
    func muteBehavior() throws(AudioVolumeError) -> CATapMuteBehavior {
        var address = HAL.address(kAudioTapPropertyDescription)
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        var value: Unmanaged<CATapDescription>?
        try HAL.check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &value))
        guard let value else {
            throw .coreAudio(kAudioHardwareUnspecifiedError)
        }
        return value.takeRetainedValue().muteBehavior
    }

    func latency() -> AudioLatency {
        HAL.outputLatency(aggregateID)
    }

    /// Stops IO and destroys the IOProc, aggregate device, and tap, then frees the render state.
    /// Call once.
    mutating func destroy() {
        stop()
        let statuses = (
            ioProc: AudioDeviceDestroyIOProcID(aggregateID, ioProcID),
            aggregate: AudioHardwareDestroyAggregateDevice(aggregateID),
            tap: AudioHardwareDestroyProcessTap(tapID)
        )
        if statuses != (noErr, noErr, noErr) {
            let pid = pid
            Self.log.error(
                "Teardown for pid \(pid, privacy: .public): IOProc \(statuses.ioProc), aggregate \(statuses.aggregate), tap \(statuses.tap)"
            )
        }
        state.deinitialize(count: 1)
        state.deallocate()
    }

    private static func tapDescription(pid: Int32, processObject: AudioObjectID, uuid: UUID, muting: Bool) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.name = "Mactivity volume \(pid)"
        description.uuid = uuid
        description.isPrivate = true
        description.muteBehavior = muting ? .mutedWhenTapped : .unmuted
        return description
    }

    private static func aggregateDescription(pid: Int32, token: String, outputUID: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Mactivity volume \(pid)",
            kAudioAggregateDeviceUIDKey: "app.mactivity.audio.\(token)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: token,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
    }
}
