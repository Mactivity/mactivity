import Core
import CoreAudio
import Darwin
import Foundation

/// Thin, throwing wrappers over `AudioObjectGetPropertyData` and friends. Public API only.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus) throws(AudioVolumeError) {
        guard status == noErr else {
            throw .coreAudio(status)
        }
    }

    /// A fixed-size scalar property (`UInt32`, `pid_t`, `AudioObjectID`, `Float64`, an ASBD…).
    static func scalar<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) throws(AudioVolumeError) -> T {
        var address = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value))
        return value
    }

    /// An `AudioObjectID` array property (process list, tap list, stream list).
    static func objectList(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws(AudioVolumeError) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size))
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids))
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// A `CFString` property. `nil` when the object has none or it's empty.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws(AudioVolumeError) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value))
        guard let value else {
            return nil
        }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    static func defaultOutputDevice() throws(AudioVolumeError) -> AudioObjectID {
        let device = try scalar(system, kAudioHardwarePropertyDefaultOutputDevice, initial: kAudioObjectUnknown)
        guard device != kAudioObjectUnknown else {
            throw .coreAudio(kAudioHardwareBadDeviceError)
        }
        return device
    }

    /// The process object for a pid, or `nil` when Core Audio doesn't know the process
    /// (it never opened an audio connection, or it exited).
    static func processObject(for pid: Int32) throws(AudioVolumeError) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(
            system, &address, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object
        ))
        return object == kAudioObjectUnknown ? nil : object
    }

    /// Everything `AudioClientMapping` needs about one process object. The executable path is read only for
    /// processes without a bundle ID; it's their settings key.
    static func processInfo(_ object: AudioObjectID) throws(AudioVolumeError) -> AudioProcessInfo {
        let pid = try scalar(object, kAudioProcessPropertyPID, initial: pid_t(-1))
        let running = try scalar(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))
        let bundleID = try? string(object, kAudioProcessPropertyBundleID)
        let path = bundleID == nil && pid > 0 ? executablePath(pid) : nil
        return AudioProcessInfo(objectID: object, pid: pid, bundleID: bundleID, executablePath: path, isRunningOutput: running != 0)
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        return String(bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    // MARK: - Output devices

    /// Aggregate devices Mactivity builds have UIDs with this prefix. They're private, but this process sees them.
    static let ownDevicePrefix = "app.mactivity.audio."

    /// Devices an app can be sent to: visible devices with output streams, except Mactivity's own aggregates.
    /// Order is Core Audio's.
    static func outputDevices() throws(AudioVolumeError) -> [AudioOutputDevice] {
        let defaultUID = try? defaultOutputUID()
        var devices: [AudioOutputDevice] = []
        for device in try objectList(system, kAudioHardwarePropertyDevices) {
            guard let uid = try? string(device, kAudioDevicePropertyDeviceUID), !uid.hasPrefix(ownDevicePrefix) else {
                continue
            }
            let hidden = (try? scalar(device, kAudioDevicePropertyIsHidden, initial: UInt32(0))) ?? 0
            let outputs = (try? objectList(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)) ?? []
            // Core Audio won't use an aggregate (a Multi-Output Device, say) as the main device of Mactivity's
            // aggregate: building one fails with '!dev'. So they can't be offered.
            let transport = (try? scalar(device, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
            guard hidden == 0, !outputs.isEmpty, transport != kAudioDeviceTransportTypeAggregate else {
                continue
            }
            let name = (try? string(device, kAudioObjectPropertyName)) ?? uid
            devices.append(AudioOutputDevice(uid: uid, name: name, isDefault: uid == defaultUID))
        }
        return devices
    }

    static func defaultOutputUID() throws(AudioVolumeError) -> String {
        guard let uid = try string(defaultOutputDevice(), kAudioDevicePropertyDeviceUID) else {
            throw .coreAudio(kAudioHardwareBadDeviceError)
        }
        return uid
    }

    /// The device with this UID right now, or `nil` when it isn't connected.
    static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        if status == noErr, device != kAudioObjectUnknown {
            return device
        }
        // The translation doesn't cover every device (private aggregates, for one); the list does.
        let devices = (try? objectList(system, kAudioHardwarePropertyDevices)) ?? []
        return devices.first { (try? string($0, kAudioDevicePropertyDeviceUID)) == uid }
    }

    static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        ((try? scalar(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
    }

    /// Output-side latency figures of a device, in frames.
    static func outputLatency(_ device: AudioObjectID) -> AudioLatency {
        func frames(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            (try? scalar(device, selector, scope: scope, initial: UInt32(0))) ?? 0
        }
        let rate = (try? scalar(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0
        return AudioLatency(
            sampleRate: rate,
            bufferFrames: frames(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal),
            inputLatencyFrames: frames(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput),
            inputSafetyOffsetFrames: frames(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput),
            outputLatencyFrames: frames(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
            outputSafetyOffsetFrames: frames(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
        )
    }

    /// Whether every output stream of `device` is 32-bit float linear PCM, the only format the kernel writes.
    static func outputIsFloat32(_ device: AudioObjectID) throws(AudioVolumeError) -> Bool {
        let streams = try objectList(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        for stream in streams {
            let format = try scalar(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
            let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            guard format.mFormatID == kAudioFormatLinearPCM, isFloat, format.mBitsPerChannel == 32 else {
                return false
            }
        }
        return true
    }
}

/// Latency figures of the aggregate device, for the spike report and diagnostics.
struct AudioLatency: Equatable, Sendable {
    let sampleRate: Double
    let bufferFrames: UInt32
    let inputLatencyFrames: UInt32
    let inputSafetyOffsetFrames: UInt32
    let outputLatencyFrames: UInt32
    let outputSafetyOffsetFrames: UInt32

    /// What the tap path adds on top of the app playing straight to the device: the tap is read on the
    /// aggregate's input side (input latency + safety offset) and written one IO buffer later. The output
    /// device's own latency and safety offset apply either way, so they don't count.
    var addedFrames: UInt32 {
        inputLatencyFrames + inputSafetyOffsetFrames + bufferFrames
    }

    var addedMilliseconds: Double {
        sampleRate > 0 ? Double(addedFrames) / sampleRate * 1000 : 0
    }
}
